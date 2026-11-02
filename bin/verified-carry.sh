#!/bin/bash
# Does a workflow verifier's VERIFIED: at an earlier commit carry to a PR's new head?
# A conflict-only fix keeps the PR's VERIFIED: (the user's decision, 2026-10-18,
# "[AGENTS] A conflict-only fix keeps the PR's VERIFIED: (no new verifier round), as it
# keeps its code review" https://trello.com/c/mWg2nZnw): "conflict-only fix. No need for
# another verified round, just like there's no need for another code review round."
#
# Usage: verified-carry.sh <owner/repo>#<n> <verified sha> <head sha>
#   <verified sha>: the commit a VERIFIED: names (7 to 40 hex; resolved with rev-parse,
#   an ambiguous or unknown one is an ERROR); <head sha>: the PR's head, 40 hex.
# Prints one line and exits:
#   0  CARRIED: <repo>#<n> @ <head7> keeps the VERIFIED: at <verified7>: <why>
#   1  NOT CARRIED: <repo>#<n> @ <head7>: <why>
#   2  ERROR: <what>   (fail closed: callers treat it as not carried)
#
# CARRIED when the verified commit is an ancestor of the head and every first-parent
# commit after it, up to the head, is either a merge whose second parent is on the base
# (origin/main for the mobile repo, origin/development for the server; whatever its
# resolution changed) or an empty commit (it changes no file, such as the follow-up commit
# that carries Remerge-allow: lines). Any other commit, or a merge that brings in commits
# that are not on the base, needs a fresh VERIFIED:. The comment tests (the newest verdict
# for the PR is a VERIFIED:, every CONFLICT RESOLVED:/REFRESHED: since says "no behavior
# change") are the callers' (merge-gate.sh, board-wait.py), which read the card.
#
# Read-only git on the local clone. It fetches (the base and the PR's head) only when a
# commit it needs is missing locally, bounded to 20 seconds (perl's alarm: macOS has no
# timeout(1)), with the fetch's output sent to /dev/null so no lingering helper process
# holds a caller's pipe open; the merge gate runs under a 60-second hook timeout.
set -u -o pipefail
. "$(dirname "${BASH_SOURCE[0]}")/kourai-env.sh"

APP=$(kc repos.app.slug)
SERVER=$(kc repos.server.slug)
APP_CLONE=$(kc repos.app.path)
SERVER_CLONE=$(kc repos.server.path)
FETCH_SECONDS=20

err() { echo "ERROR: $*"; exit 2; }

[[ "${1:-}" =~ ^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+)$ ]] \
  || err "usage: verified-carry.sh <owner/repo>#<n> <verified sha> <head sha>"
repo=${BASH_REMATCH[1]} num=${BASH_REMATCH[2]}
# The app repo's older names (repos.app.legacy_slugs; cards still carry them).
for old in $(kc_or repos.app.legacy_slugs ""); do [ "$repo" = "$old" ] && repo=$APP; done
want=${2:-} head=${3:-}
[[ "$want" =~ ^[0-9a-f]{7,40}$ ]] || err "<verified sha> must be 7 to 40 hex characters"
[[ "$head" =~ ^[0-9a-f]{40}$ ]] || err "<head sha> must be 40 hex characters"
ref="$repo#$num"
no() { echo "NOT CARRIED: $ref @ ${head:0:7}: $*"; exit 1; }

case "$repo" in
  "$APP") clone=$APP_CLONE base=main ;;
  "$SERVER") clone=$SERVER_CLONE base=development ;;
  *) err "unknown repo $repo" ;;
esac

fetched=""
fetch() { # once per run: the base and the PR's head, bounded
  [ -z "$fetched" ] || return 0
  fetched=1
  perl -e 'alarm shift; exec @ARGV' "$FETCH_SECONDS" \
    git -C "$clone" fetch -q --no-write-fetch-head origin "+refs/heads/$base:refs/remotes/origin/$base" "refs/pull/$num/head" \
    >/dev/null 2>&1 </dev/null || err "can't fetch $ref and its base $base (within ${FETCH_SECONDS}s)"
}
have() { git -C "$clone" cat-file -e "$1^{commit}" 2>/dev/null; }

have "$head" || fetch
have "$head" || err "can't find $ref's head ${head:0:7}"
verified=$(git -C "$clone" rev-parse -q --verify "$want^{commit}" 2>/dev/null)
if [ -z "$verified" ]; then
  fetch
  verified=$(git -C "$clone" rev-parse -q --verify "$want^{commit}" 2>/dev/null) \
    || err "can't resolve the verified commit $want (unknown or ambiguous)"
fi
git -C "$clone" rev-parse -q --verify "origin/$base^{commit}" >/dev/null 2>&1 || fetch

git -C "$clone" merge-base --is-ancestor "$verified" "$head" 2>/dev/null \
  || no "the verified commit ${verified:0:7} is not in its history"
[ "$verified" != "$head" ] || { echo "CARRIED: $ref @ ${head:0:7} keeps the VERIFIED: at ${verified:0:7}: it is the same commit"; exit 0; }

commits=$(git -C "$clone" rev-list --first-parent "$verified..$head") || err "can't list $ref's commits after ${verified:0:7}"
for c in $commits; do
  parents=$(git -C "$clone" rev-list --parents -n 1 "$c") || err "can't read commit ${c:0:7}"
  set -- $parents
  if [ $# -eq 2 ]; then
    git -C "$clone" diff --quiet "$c^" "$c" 2>/dev/null \
      || no "commit ${c:0:7} since the VERIFIED: at ${verified:0:7} is not a merge of $base and changes files"
    continue
  fi
  [ $# -eq 3 ] || no "commit ${c:0:7} since the VERIFIED: at ${verified:0:7} is not a merge of $base"
  if ! git -C "$clone" merge-base --is-ancestor "$3" "origin/$base" 2>/dev/null; then
    # The local base may lag the merge the builder made: fetch once and look again.
    fetch
    git -C "$clone" merge-base --is-ancestor "$3" "origin/$base" 2>/dev/null \
      || no "merge ${c:0:7} since the VERIFIED: at ${verified:0:7} brings in commits that are not on $base"
  fi
done
echo "CARRIED: $ref @ ${head:0:7} keeps the VERIFIED: at ${verified:0:7}: since then only merges of $base and empty commits"
exit 0
