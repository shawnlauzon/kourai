#!/bin/bash
# What kind of change is a card: does it change the app or the server, or only
# tests and tooling, or only the agents' own files? Decided from its PRs' changed
# files, never from an agent's say-so (the user's decisions, 2026-10-12, card
# "[AGENTS] [AGENTS] PRs merge as soon as they're approved, with no integration;
# agent-only commits never block or void a run" https://trello.com/c/gIwiLKVk:
# "I only need integration tests on things that affect the application (the app
# or the server). Things to agents can never affect that", and its added scope:
# "Wait until there's actual real functionality that's being merged").
#
# Every card merges as soon as it is approved, whatever its kind (card "[AGENTS]
# Merge each card as soon as it's approved; the 5-card wait is for staging only;
# check every open PR for conflicts after each merge" https://trello.com/c/mrxjFnln).
# The promoter uses the kind for MERGED (whether a release is due), the merger
# and the board watcher for a user hold and for where a merged card goes
# (.claude/board/rules.md, "Merging" and "Releasing"):
#   AGENTS  goes to DONE once merged, is never released and never a culprit
#           candidate;
#   TESTS   rides along: released with the next release, but never counted
#           toward the Release due setting;
#   APP     counts toward the Release due setting.
# (A 🚨 card makes a release due whatever its kind.)
#
# Usage:
#   card-kind.sh <owner/repo>#<n> [<owner/repo>#<n> ...]   (every PR of one card)
#   card-kind.sh --paths <owner/repo> <path> [<path> ...]  (the same test on paths you name,
#       with no gh call: prints "<KIND> <path>" per path, then "PATHS: <the highest kind>".
#       code-review-check.sh uses it for the files of one commit.)
#
# Prints one line per PR, "<owner/repo>#<n> <KIND> (<why>)", then the card's
# kind, the highest of its PRs' (APP > TESTS > AGENTS): "CARD: <KIND>".
# A PR's kind is the highest of its files' (a rename counts its old path too):
#   A repo listed in the config: AGENTS when the path matches one of its kind.agents_paths globs, TESTS when it
#   matches one of its kind.tests_paths globs, APP otherwise (a rename counts its old path too).
#   any other repo: APP.
# A PR with no changed files at all (a history-only merge, server #157; GitHub's
# changed_files is 0) is TESTS: no app or server code, so it rides along with the
# next release, never counts toward Release due (a 🚨 one still makes a release due).
# Exit status: 0; 2 for bad arguments or when a read fails ("ERROR: <what>" on
# stdout, and no CARD: line): the caller treats the card as APP (it counts toward
# the Release due setting, the normal path).
#
# Reads only (plain `gh`, the user's login). Override (tests): CARD_KIND_GH (the
# gh command, default gh).
set -u -o pipefail
. "$(dirname "${BASH_SOURCE[0]}")/kourai-env.sh"

gh_cmd=${CARD_KIND_GH:-gh}

usage() { echo "usage: card-kind.sh <owner/repo>#<n> [<owner/repo>#<n> ...] | --paths <owner/repo> <path> [<path> ...]" >&2; exit 2; }
[ "$#" -ge 1 ] || usage
if [ "$1" != "--paths" ]; then
  for ref in "$@"; do
    [[ "$ref" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+$ ]] || { echo "card-kind.sh: bad PR '$ref' (want owner/repo#n)" >&2; exit 2; }
  done
fi

rank() { case "$1" in AGENTS) echo 0 ;; TESTS) echo 1 ;; *) echo 2 ;; esac; }

repos_json=$(kourai-config json repos) || { echo "ERROR: kourai-config json repos failed"; exit 2; }

# The kind a path has in a repo, from that repo's kind.agents_paths and kind.tests_paths (globs, config);
# anything else is APP. A repo the config does not list: APP.
file_kind() { # file_kind <repo> <path>
  local repo=$1 f=$2 pat
  while IFS= read -r pat; do [[ $f == $pat ]] && { echo AGENTS; return; }; done < <(jq -r --arg r "$repo" '[.[] | select(.slug == $r or ((.legacy_slugs // []) | index($r) != null))] | first | (.kind.agents_paths // [])[]' <<<"$repos_json")
  while IFS= read -r pat; do [[ $f == $pat ]] && { echo TESTS; return; }; done < <(jq -r --arg r "$repo" '[.[] | select(.slug == $r or ((.legacy_slugs // []) | index($r) != null))] | first | (.kind.tests_paths // [])[]' <<<"$repos_json")
  echo APP
}

if [ "$1" = "--paths" ]; then
  [ "$#" -ge 3 ] && [[ "$2" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage
  prepo=$2; shift 2
  highest=AGENTS
  for f in "$@"; do
    k=$(file_kind "$prepo" "$f")
    echo "$k $f"
    [ "$(rank "$k")" -gt "$(rank "$highest")" ] && highest=$k
  done
  echo "PATHS: $highest"
  exit 0
fi

card=AGENTS
for ref in "$@"; do
  repo=${ref%#*}; n=${ref##*#}
  files=$("$gh_cmd" api --paginate "repos/$repo/pulls/$n/files" --jq '.[] | .filename, (.previous_filename // empty)' 2>/dev/null) \
    || { echo "ERROR: can't read the files of $ref"; exit 2; }
  if [ -z "$files" ]; then
    # A history-only merge changes no files: GitHub's own count must agree (else the read is not trusted).
    n_files=$("$gh_cmd" api "repos/$repo/pulls/$n" --jq '.changed_files' 2>/dev/null) || n_files=""
    [ "$n_files" = 0 ] || { echo "ERROR: $ref lists no changed files"; exit 2; }
    echo "$ref TESTS (files: 0, a history-only merge: no app or server code)"
    [ "$(rank TESTS)" -gt "$(rank "$card")" ] && card=TESTS
    continue
  fi
  kind=AGENTS why="" count=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    count=$((count + 1))
    k=$(file_kind "$repo" "$f")
    if [ "$(rank "$k")" -gt "$(rank "$kind")" ]; then kind=$k; why=$f; fi
  done <<<"$files"
  case "$kind" in
    AGENTS) echo "$ref AGENTS (files: $count, all agent files)" ;;
    TESTS) echo "$ref TESTS (files: $count, no app or server code; first test or tooling file: $why)" ;;
    APP) echo "$ref APP (files: $count; first app or server file: $why)" ;;
  esac
  [ "$(rank "$kind")" -gt "$(rank "$card")" ] && card=$kind
done
echo "CARD: $card"
