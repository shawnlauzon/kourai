#!/bin/bash
# Does each PR still merge cleanly into its base (mobile main, server
# development)? Used by the board-watcher on every pass for the PRs of the cards
# in REVIEW and APPROVED, and by a card manager running a conflict fix
# (.claude/board/rules.md, "Merge conflicts in REVIEW"; WORKFLOW.md).
#
# GitHub computes a PR's `mergeable` lazily: right after the base moves, or the
# first time anyone asks, it answers UNKNOWN and starts computing. So an UNKNOWN
# answer is asked again (PR_CONFLICTS_TRIES times, PR_CONFLICTS_WAIT seconds
# apart). One that is still UNKNOWN is printed as UNKNOWN: the caller must treat
# it as "not known yet" and ask again on its next pass, never as "no conflict".
#
# Usage:
#   pr-conflicts.sh <owner/repo>#<n> [<owner/repo>#<n> ...]
#
# Prints one line per PR: "<owner/repo>#<n> <state>", where <state> is
#   CONFLICTING   the PR conflicts with its base
#   MERGEABLE     the PR merges cleanly into its base
#   UNKNOWN       GitHub had not computed it yet after every try
#   MERGED / CLOSED   the PR is not open (nothing to check)
#   ERROR         the read failed (the message follows on stderr)
# Exit status: 1 if any PR is CONFLICTING, else 3 if any is UNKNOWN or ERROR,
# else 0. 2 for bad arguments.
#
# Reads only (plain `gh`, the user's login). Overrides (tests): PR_CONFLICTS_GH
# (the gh command, default gh), PR_CONFLICTS_TRIES (default 5),
# PR_CONFLICTS_WAIT (seconds, default 6).
set -u

gh_cmd=${PR_CONFLICTS_GH:-gh}
tries=${PR_CONFLICTS_TRIES:-5}
wait_s=${PR_CONFLICTS_WAIT:-6}

usage() { echo "usage: pr-conflicts.sh <owner/repo>#<n> [<owner/repo>#<n> ...]" >&2; exit 2; }
[ "$#" -ge 1 ] || usage
for ref in "$@"; do
  [[ "$ref" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+$ ]] || { echo "pr-conflicts.sh: bad PR '$ref' (want owner/repo#n)" >&2; exit 2; }
done

# One PR: prints its state. Asks again while GitHub says UNKNOWN.
check_one() {
  local repo=$1 n=$2 i out state mergeable
  for ((i = 1; i <= tries; i++)); do
    if ! out=$("$gh_cmd" pr view "$n" --repo "$repo" --json state,mergeable --jq '.state + " " + .mergeable' 2>&1); then
      echo "pr-conflicts.sh: $repo#$n: $out" >&2
      echo ERROR
      return
    fi
    state=${out%% *}
    mergeable=${out#* }
    if [ "$state" != "OPEN" ]; then
      echo "$state"
      return
    fi
    case "$mergeable" in
      CONFLICTING|MERGEABLE) echo "$mergeable"; return ;;
    esac
    # UNKNOWN (or anything new GitHub may answer): GitHub is still computing.
    [ "$i" -lt "$tries" ] && sleep "$wait_s"
  done
  echo UNKNOWN
}

status=0
for ref in "$@"; do
  repo=${ref%%#*}
  n=${ref##*#}
  result=$(check_one "$repo" "$n")
  echo "$ref $result"
  case "$result" in
    CONFLICTING) status=1 ;;
    UNKNOWN|ERROR) [ "$status" -eq 0 ] && status=3 ;;
  esac
done
exit "$status"
