#!/bin/bash
# Does a PR have a valid code review? Read-only, decided from the PR's files, its
# comments and its commits, never from an agent's say-so. Used by the card manager
# (step "Code review") and the merger; a merge gate can call it later. Card
# "[AGENTS] An agent code-reviews every production code change; builders load the
# project skills" https://trello.com/c/nA1Tn2R1; the rules are in rules.md, "Code review".
#
# Usage: code-review-check.sh <owner/repo>#<n>
# Prints one line:
#   CODE REVIEW NOT NEEDED: <ref>: <kind> (no app or server code)      exit 0
#       (card-kind.sh says the PR is not APP: only tests, tooling, docs or agent files)
#   CODE REVIEW OK: <ref>: reviewed its head <sha7>                    exit 0
#   CODE REVIEW OK: <ref>: reviewed <sha7>; since then only merges of <base> and commits without app or server code
#   CODE REVIEW NEEDED: <ref> @ <head>: <why>                          exit 1
#   ERROR: <what>                                                      exit 2 (not known: check again later)
#
# The review is the newest PR comment by the App's bot (github.bot_name) whose first line is
#   CODE REVIEW: <owner/repo>#<n> @ <40-character sha>: <k> must-fix, <m> notes
# (the mobile repo's old name repos.app.legacy_slugs are accepted). It is valid when k is 0 and
# the PR's head is that sha, or every commit since it (first-parent path) is either a merge of
# the base (its second parent is on origin/<base>) or a commit none of whose files card-kind.sh
# classes APP (tests, docs, agent files). Anything else needs a new review.
#
# Overrides (tests): CODE_REVIEW_GH (the gh command, default gh), CARD_KIND_GH (for card-kind.sh),
# CODE_REVIEW_APP_CLONE, CODE_REVIEW_SERVER_CLONE (the clones it fetches into), CODE_REVIEW_BOT.
set -u -o pipefail
. "$(dirname "${BASH_SOURCE[0]}")/kourai-env.sh"

APP=$(kc repos.app.slug) OLD_APP=$(kc_or repos.app.legacy_slugs "" | head -1) SERVER=$(kc repos.server.slug)
APP_CLONE=${CODE_REVIEW_APP_CLONE:-$(kc repos.app.path)}
SERVER_CLONE=${CODE_REVIEW_SERVER_CLONE:-$(kc repos.server.path)}
BOT=${CODE_REVIEW_BOT:-$(kc github.bot_name)[bot]}
gh_cmd=${CODE_REVIEW_GH:-gh}
here=$(cd "$(dirname "$0")" && pwd)
export CARD_KIND_GH=${CARD_KIND_GH:-$gh_cmd}

err() { echo "ERROR: $*"; exit 2; }
ref=${1:-}
[ "$#" -eq 1 ] && [[ "$ref" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+$ ]] || { echo "usage: code-review-check.sh <owner/repo>#<n>" >&2; exit 2; }
repo=${ref%#*} num=${ref##*#}

# 1. Is it app or server code at all?
kind_out=$("$here/card-kind.sh" "$ref") || err "can't tell the kind of $ref: $(tail -1 <<<"$kind_out")"
kind=$(sed -n 's/^CARD: //p' <<<"$kind_out")
[ -n "$kind" ] || err "card-kind.sh printed no kind for $ref"
if [ "$kind" != APP ]; then
  echo "CODE REVIEW NOT NEEDED: $ref: $kind (no app or server code)"
  exit 0
fi

# 2. The PR's head and base, and its newest code review.
pr=$("$gh_cmd" api "repos/$repo/pulls/$num" 2>/dev/null) || err "can't read $ref"
head=$(jq -r '.head.sha' <<<"$pr") base=$(jq -r '.base.ref' <<<"$pr")
[[ "$head" =~ ^[0-9a-f]{40}$ ]] && [ -n "$base" ] || err "$ref has no readable head or base"
needs() { echo "CODE REVIEW NEEDED: $ref @ $head: $*"; exit 1; }

comments=$("$gh_cmd" api --paginate "repos/$repo/issues/$num/comments" 2>/dev/null | jq -rs --arg bot "$BOT" \
  '[.[][] | select(.user.login == $bot and (.body | startswith("CODE REVIEW: ")))] | sort_by(.created_at) | .[] | .body | split("\n")[0]') \
  || err "can't read the comments of $ref"
review_sha="" review_k=""
re="^CODE REVIEW: ($repo|$OLD_APP)#$num @ ([0-9a-f]{40}): ([0-9]+) must-fix"
while IFS= read -r line; do
  if [[ "$line" =~ $re ]]; then review_sha=${BASH_REMATCH[2]} review_k=${BASH_REMATCH[3]}; fi
done <<<"$comments"
[ -n "$review_sha" ] || needs "no code review yet"
[ "$review_k" -eq 0 ] || needs "the review of ${review_sha:0:7} has $review_k must-fix"
if [ "$review_sha" = "$head" ]; then
  echo "CODE REVIEW OK: $ref: reviewed its head ${head:0:7}"
  exit 0
fi

# 3. Reviewed on an older commit: only merges of the base and commits without app or server code since?
case "$repo" in
  "$APP"|"$OLD_APP") clone=$APP_CLONE ;;
  "$SERVER") clone=$SERVER_CLONE ;;
  *) needs "reviewed ${review_sha:0:7}, not its head ${head:0:7}" ;;
esac
git -C "$clone" fetch -q --no-write-fetch-head origin "+refs/heads/$base:refs/remotes/origin/$base" "refs/pull/$num/head" 2>/dev/null \
  || err "can't fetch $ref and its base $base"
git -C "$clone" cat-file -e "$head^{commit}" 2>/dev/null || err "can't find $ref's head ${head:0:7} after fetching"
stale="reviewed ${review_sha:0:7}, not its head ${head:0:7}"
git -C "$clone" merge-base --is-ancestor "$review_sha" "$head" 2>/dev/null || needs "$stale, and the reviewed commit is no longer in its history"
for c in $(git -C "$clone" rev-list --first-parent "$review_sha..$head"); do
  set -- $(git -C "$clone" rev-list --parents -n 1 "$c")
  if [ $# -eq 2 ]; then
    # --no-renames lists a moved file's old path too, so a move out of lib/ counts.
    files=()
    while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done < <(git -C "$clone" diff --no-renames --name-only "$c^" "$c")
    [ "${#files[@]}" -gt 0 ] || continue
    out=$("$here/card-kind.sh" --paths "$repo" "${files[@]}") || err "card-kind.sh --paths failed for commit ${c:0:7}"
    if [ "$(sed -n 's/^PATHS: //p' <<<"$out")" = APP ]; then
      f=$(sed -n 's/^APP //p' <<<"$out" | head -1)
      needs "$stale; commit ${c:0:7} since then changes app or server code ($f)"
    fi
    continue
  fi
  [ $# -eq 3 ] || needs "$stale; commit ${c:0:7} since then is not a merge of $base"
  git -C "$clone" merge-base --is-ancestor "$3" "origin/$base" \
    || needs "$stale; merge ${c:0:7} since then brings in commits that are not on $base"
done
echo "CODE REVIEW OK: $ref: reviewed ${review_sha:0:7}; since then only merges of $base and commits without app or server code"
exit 0
