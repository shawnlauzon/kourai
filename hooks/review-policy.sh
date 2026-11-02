#!/bin/bash
# The review policy: does a PR need the user's approval before it merges, and if
# so, does it have one? merge-gate.sh and merged-comment-gate.sh decide with it;
# agents run it read-only to decide where a card goes (REVIEW or MERGING). One
# source of truth, kept with the hooks because it keeps the agents in check.
#
# Usage: review-policy.sh check <owner/repo>#<n> [<head sha>]
#   With <head sha>, the PR's head must be exactly that commit.
# Prints one line and exits:
#   0  NO REVIEW NEEDED: <repo>#<n>: <why>
#   0  APPROVED: <repo>#<n>: <how>
#   1  REVIEW NEEDED: <repo>#<n>: <why>
#   2  ERROR: <what>   (fail closed: callers treat it as not approved)
#
# The paths and the repos come from the installation's config (docs/CONFIG.md), read through
# $KOURAI_BIN/kourai-config (the installer's hook registration sets KOURAI_BIN and KOURAI_CONFIG).
# A PR NEEDS REVIEW when any of these holds (the file paths decide, plus the
# PR body's flag; an agent's word alone never skips a review):
#   - it changes a file that keeps the agents in check: a path of guarded.paths (every repo) or of the
#     repo's review.always_paths;
#   - it changes a file that is in no list of the repo's review table and the repo's review.default is
#     "review" (an unlisted repo is all "review");
#   - it changes a file of review.flag_paths (or, for a repo whose review.default is "flag", any file that
#     is not free) without a line `App-visible: no` in its body;
#   - its body has a line `App-visible: yes` (any repo);
#   - it changes no files at all (a history-only merge: GitHub's changed_files is 0): what the merge
#     resolves away leaves the next release, so it goes to the approval check below, never to NO REVIEW NEEDED;
#   - it is in a repo the config does not list.
# review.free_paths never need review. Otherwise it needs NO REVIEW.
#
# A PR that needs review is APPROVED when the user's (github.user_login) newest
# review that approves, requests changes or was dismissed is APPROVED, and was
# made on the PR's head commit, or on a commit A after which the PR only took
# merges of its base (a remerge keeps the approval, conflict resolution and all):
# every first-parent commit from A to the head is a merge whose second parent is
# on the base. What the merge commit itself changes is not checked, and neither is a
# "Merge conflict resolution" note's `Behavior change:` line: a remerge NEVER needs
# another approval. The approval also survives a commit since then whose changed
# files are all under the repo's review.keep_approval_paths. Any other commit that
# is not a merge of the base voids it.
#
# Reads GitHub with `gh api` and the local clones (fetching the base and the
# PR's head into them).
set -u -o pipefail

err() { echo "ERROR: $*"; exit 2; }

. "${KOURAI_BIN:?review-policy.sh needs KOURAI_BIN (the installer hook registration sets it)}/kourai-env.sh"
USER_GH=$(kc github.user_login) || err "can't read the config (github.user_login)"
repos_json=$(kourai-config json repos) || err "can't read the config (repos)"
guarded=$(kourai-config get guarded.paths) || err "can't read the config (guarded.paths)"

[ "${1:-}" = check ] || err "usage: review-policy.sh check <owner/repo>#<n> [<head sha>]"
[[ "${2:-}" =~ ^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+)$ ]] || err "usage: review-policy.sh check <owner/repo>#<n> [<head sha>]"
repo=${BASH_REMATCH[1]} num=${BASH_REMATCH[2]}
# A repo that was renamed or moved: cards and comments written before still name it by an old slug
# (repos.*.legacy_slugs), and GitHub redirects that name.
repo=$(jq -r --arg r "$repo" '([.[] | select(.slug == $r or ((.legacy_slugs // []) | index($r) != null)) | .slug] | first) // $r' <<<"$repos_json")
# The repo's config table: its id, its default for unlisted files, its path lists and its clone.
rid=$(jq -r --arg r "$repo" '[.[] | select(.slug == $r)] | first | .id // ""' <<<"$repos_json")
rpath() { jq -r --arg r "$repo" --arg k "$1" '[.[] | select(.slug == $r)] | first | .review[$k] // [] | .[]' <<<"$repos_json"; }
rdefault=$(jq -r --arg r "$repo" '[.[] | select(.slug == $r)] | first | .review.default // "review"' <<<"$repos_json")
clone=$(jq -r --arg r "$repo" '[.[] | select(.slug == $r)] | first | .path // ""' <<<"$repos_json")
always_paths=$(rpath always_paths) free_paths=$(rpath free_paths) flag_paths=$(rpath flag_paths) keep_paths=$(rpath keep_approval_paths)
# A path matches a list when it matches one of its globs; a glob that ends in / is a folder prefix.
in_list() { # in_list <path> <newline-separated globs>
  local f=$1 pat
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    case "$pat" in */) [[ $f == "$pat"* ]] && return 0 ;; *) [[ $f == $pat ]] && return 0 ;; esac
  done <<<"$2"
  return 1
}
want=${3:-}
[ -z "$want" ] || [[ "$want" =~ ^[0-9a-f]{40}$ ]] || err "<head sha> must be 40 hex characters"
ref="$repo#$num"
needs() { echo "REVIEW NEEDED: $ref: $*"; exit 1; }

pr=$(gh api "repos/$repo/pulls/$num" 2>/dev/null) || err "can't read $ref"
head=$(jq -r '.head.sha // ""' <<<"$pr")
base=$(jq -r '.base.ref // ""' <<<"$pr")
body=$(jq -r '.body // ""' <<<"$pr")
[[ "$head" =~ ^[0-9a-f]{40}$ ]] || err "can't read $ref's head commit"
[ -z "$want" ] || [ "$want" = "$head" ] || err "$ref's head is ${head:0:7}, not ${want:0:7}"

files=$(gh api --paginate "repos/$repo/pulls/$num/files" --jq '.[] | .filename, (.previous_filename // empty)' 2>/dev/null) \
  || err "can't read $ref's changed files"
# A PR with no changed files (a history-only merge) lists none; GitHub's own count
# must agree (changed_files 0), else the read is not trusted (fail closed).
zero=0
if [ -z "$files" ]; then
  [ "$(jq -r '.changed_files // "unknown"' <<<"$pr")" = 0 ] || err "$ref changes no files"
  zero=1
fi

flag=$(grep -Eio '^[[:space:]]*App-visible:[[:space:]]*(yes|no)([^A-Za-z]|$)' <<<"$body" | head -1 | tr 'A-Z' 'a-z')
case "$flag" in *yes*) flag=yes ;; *no*) flag=no ;; *) flag="" ;; esac

privileged() { # a file that keeps the agents in check
  in_list "$1" "$guarded" || in_list "$1" "$always_paths"
}

why_review="" why_flag="" n_review=0 n_flag=0
add() { # add review|flag <file>
  if [ "$1" = review ]; then n_review=$((n_review + 1)); [ "$n_review" -le 3 ] && why_review+="${why_review:+, }$2"
  else n_flag=$((n_flag + 1)); [ "$n_flag" -le 3 ] && why_flag+="${why_flag:+, }$2"; fi
}
while IFS= read -r f; do
  [ -z "$f" ] && continue
  if privileged "$f"; then add review "$f"; continue; fi
  if [ -z "$rid" ]; then add review "$f"
  elif in_list "$f" "$free_paths"; then :
  elif in_list "$f" "$flag_paths"; then add flag "$f"
  elif [ "$rdefault" = flag ]; then add flag "$f"
  else add review "$f"; fi
done <<<"$files"

kind=${rid:-other}
more() { [ "$1" -gt 3 ] && echo " and $(($1 - 3)) more"; }
reason=""
if [ "$zero" = 1 ]; then
  reason="changes no files (a history-only merge: what it resolves away leaves the next release)"
elif [ "$n_review" -gt 0 ]; then
  reason="changes ${why_review}$(more "$n_review")"
elif [ "$flag" = yes ]; then
  reason="its body says App-visible: yes"
elif [ "$n_flag" -gt 0 ] && [ "$flag" != no ]; then
  reason="changes $kind code (${why_flag}$(more "$n_flag")) and its body has no App-visible line"
else
  if [ "$n_flag" -gt 0 ]; then
    echo "NO REVIEW NEEDED: $ref: $kind code only, flagged App-visible: no"
  else
    echo "NO REVIEW NEEDED: $ref: only tests, docs or workflow files"
  fi
  exit 0
fi

# It needs review. Is it approved?
review=$(gh api --paginate "repos/$repo/pulls/$num/reviews" 2>/dev/null \
  | jq -rs --arg u "$USER_GH" '[.[][] | select(.user.login == $u and (.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED"))] | last // empty | "\(.state) \(.commit_id) \(.submitted_at)"') \
  || err "can't read $ref's reviews"
[ -n "$review" ] || needs "$reason; the user has not approved it"
read -r rstate approved _ <<<"$review"
[ "$rstate" = APPROVED ] || needs "$reason; the user's newest review is $rstate"
if [ "$approved" = "$head" ]; then
  echo "APPROVED: $ref: the user approved its head ${head:0:7}"
  exit 0
fi
[[ "$approved" =~ ^[0-9a-f]{40}$ ]] || needs "$reason; the approval names no commit"

# Approved on an older commit: only merges of the base since (a remerge)?
[ -n "$clone" ] || needs "$reason; approved on ${approved:0:7}, not its head ${head:0:7}"
git -C "$clone" fetch -q --no-write-fetch-head origin "+refs/heads/$base:refs/remotes/origin/$base" "refs/pull/$num/head" 2>/dev/null \
  || err "can't fetch $ref and its base $base"
git -C "$clone" cat-file -e "$head^{commit}" 2>/dev/null || err "can't find $ref's head ${head:0:7} after fetching"
stale="$reason; approved on ${approved:0:7}, not its head ${head:0:7}"
git -C "$clone" merge-base --is-ancestor "$approved" "$head" 2>/dev/null || needs "$stale, and the approved commit is no longer in its history"
for c in $(git -C "$clone" rev-list --first-parent "$approved..$head"); do
  parents=$(git -C "$clone" rev-list --parents -n 1 "$c")
  set -- $parents
  if [ $# -eq 2 ]; then
    # A single-parent commit is fine when it changes only tests or docs.
    while IFS= read -r f; do
      # The same test and docs prefixes the repo's no-review rules use above.
      # --no-renames lists a moved file's old path too, so a move out of lib/ counts.
      in_list "$f" "$keep_paths" || needs "$stale; commit ${c:0:7} since then is not a merge of $base and changes $f"
    done < <(git -C "$clone" diff --no-renames --name-only "$c^" "$c")
    continue
  fi
  [ $# -eq 3 ] || needs "$stale; commit ${c:0:7} since then is not a merge of $base"
  git -C "$clone" merge-base --is-ancestor "$3" "origin/$base" || needs "$stale; merge ${c:0:7} since then brings in commits that are not on $base"
done
echo "APPROVED: $ref: the user approved ${approved:0:7}; since then only merges of $base and test or docs commits"
exit 0
