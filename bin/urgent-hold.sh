#!/bin/bash
# Would merging a PR make a 🚨 card's open PR conflict? The merger asks this before it
# merges a card (.claude/board/rules.md, "Merging", the urgent-hold rule): merging now
# would turn a 🚨 PR that merges cleanly into a conflicting one, so the card waits.
#
# A real test merge in local git, never a guess from file names: the base tip with the
# PR's head merged in (git merge-tree, nothing is checked out or written to a branch),
# then that result against the 🚨 PR's head. A 🚨 PR that already conflicts with the base
# is not held for: the merge cannot make it worse.
#
# Usage:
#   urgent-hold.sh -C <worktree> <base ref> <pr head> <urgent head> [<urgent head> ...]
# <base ref> is the base branch as the worktree knows it (origin/main, origin/development);
# every sha must already be fetched (the PRs' heads via refs/pull/<n>/head).
#
# Prints one line per 🚨 head: "<sha> HOLD" (merging the PR would make it conflict),
# "<sha> CLEAR" (still merges cleanly), "<sha> ALREADY CONFLICTING" (conflicts with the
# base as it is: no hold), or "<sha> ERROR" (a sha is missing; the reason follows on stderr).
# Exit status: 1 if any head is HOLD, else 3 if any is ERROR, else 0. 2 for bad arguments.
# Local git only, no network, no writes except loose objects in the object store.
set -u

[ "$#" -ge 5 ] && [ "$1" = "-C" ] || { echo "usage: urgent-hold.sh -C <worktree> <base ref> <pr head> <urgent head> [<urgent head> ...]" >&2; exit 2; }
wt=$2; base=$3; head=$4; shift 4

g() { git -C "$wt" "$@"; }
base_sha=$(g rev-parse --verify -q "$base^{commit}") || { echo "urgent-hold.sh: unknown base '$base'" >&2; exit 2; }
head_sha=$(g rev-parse --verify -q "$head^{commit}") || { echo "urgent-hold.sh: unknown PR head '$head'" >&2; exit 2; }

# The base after the merge. A PR that itself conflicts with the base holds nothing here
# (the merger's own conflict check handles it before it gets here).
tree=$(g merge-tree --write-tree --no-messages "$base_sha" "$head_sha" 2>/dev/null) || { echo "urgent-hold.sh: the PR conflicts with $base" >&2; exit 2; }
tree=$(printf '%s\n' "$tree" | head -n 1)
after=$(g commit-tree "$tree" -p "$base_sha" -p "$head_sha" -m "urgent-hold test merge") || { echo "urgent-hold.sh: commit-tree failed" >&2; exit 2; }

rc=0
for u in "$@"; do
  usha=$(g rev-parse --verify -q "$u^{commit}") || { echo "$u ERROR"; echo "urgent-hold.sh: unknown commit $u" >&2; [ "$rc" -eq 1 ] || rc=3; continue; }
  if ! g merge-tree --write-tree --no-messages "$base_sha" "$usha" >/dev/null 2>&1; then
    echo "$u ALREADY CONFLICTING"
  elif g merge-tree --write-tree --no-messages "$after" "$usha" >/dev/null 2>&1; then
    echo "$u CLEAR"
  else
    echo "$u HOLD"; rc=1
  fi
done
exit "$rc"
