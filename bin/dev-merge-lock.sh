#!/bin/bash
# The release server lock (.claude/board/rules.md, Test servers; promoter.md):
# the promoter is the only user of the release server (`integration` in
# commands) and its emulator, 5556, for its full test, culprit search and SMOKE.
# It holds this lock from before its PROMOTING: comment until the result is
# written (after a red full test, until the culprit search ends) and the server
# is down.
#
# The lock is held across many commands, each in a new shell, so it records its
# owning role, not a process id. Liveness comes from transcripts, never from
# heartbeats (rules.md, Liveness): `status` says whether agent-state.sh shows a
# promoter that may be alive. Only one promoter runs at a time (it ends at once
# when it finds another live copy), so a lock held by "promoter" is either its
# own or a dead promoter's, which the next promoter's resume step releases.
#
# Usage:
#   dev-merge-lock.sh integration-server take promoter
#       Takes the lock at once (mkdir is atomic) or reports who holds it: exit 3.
#       Already held by the promoter: success. Never waits.
#   dev-merge-lock.sh integration-server release promoter
#       Releases it if the promoter holds it.
#   dev-merge-lock.sh integration-server status
#       Prints "free" or "held by promoter since <time> (a promoter is alive |
#       no promoter alive)".
# Exit 2: usage.
#
# Overrides (tests): RC_LOCK_DIR (default paths.locks_dir),
# DEV_MERGE_LOCK_AGENT_STATE (the agent-state.sh to ask).
set -u
. "$(dirname "${BASH_SOURCE[0]}")/kourai-env.sh"

here=$(cd "$(dirname "$0")" && pwd)
lock_root=${RC_LOCK_DIR:-$(kc paths.locks_dir)}
lock=$lock_root/integration-test-server
agent_state=${DEV_MERGE_LOCK_AGENT_STATE:-$here/agent-state.sh}

usage() { echo "usage: dev-merge-lock.sh integration-server take|release|status [promoter]" >&2; exit 2; }
[ "${1:-}" = integration-server ] || usage
shift
cmd=${1:-} role=${2:-}
case "$cmd" in
  take|release) [ "$role" = promoter ] && [ $# -eq 2 ] || usage ;;
  status) [ $# -eq 1 ] || usage ;;
  *) usage ;;
esac

owner() { cat "$lock/owner" 2>/dev/null || true; }

promoter_alive() {
  # Any promoter line that is not reported or dead (with no live children) may be alive.
  "$agent_state" promoter 2>/dev/null | awk '
    $2 == "promoter" && $1 != "reported" && !($1 == "dead" && $0 ~ / children=0 /) { alive = 1 }
    END { exit alive ? 0 : 1 }'
}

describe() {
  if [ ! -d "$lock" ]; then echo free; return; fi
  local o since alive
  o=$(owner)
  since=$(cat "$lock/since" 2>/dev/null || echo "?")
  [ -n "$o" ] || { echo "held by nobody yet since $since (being taken)"; return; }
  if promoter_alive; then alive="a promoter is alive"; else alive="no promoter alive"; fi
  echo "held by $o since $since ($alive)"
}

case "$cmd" in
  status) describe ;;
  take)
    mkdir -p "$lock_root"
    # A lock made but never written (its taker died between mkdir and the write)
    # is stale after 30 seconds.
    if [ -d "$lock" ] && [ -z "$(owner)" ] && [ $(( $(date +%s) - $(stat -f %m "$lock") )) -gt 30 ]; then
      rm -rf "$lock"
    fi
    if mkdir "$lock" 2>/dev/null; then
      echo "$role" >"$lock/owner"
      date -u +%Y-%m-%dT%H:%M:%SZ >"$lock/since"
      echo "release server lock taken by $role"
      exit 0
    fi
    if [ "$(owner)" = "$role" ]; then echo "release server lock already held by $role"; exit 0; fi
    echo "release server lock is $(describe)" >&2
    exit 3
    ;;
  release)
    [ -d "$lock" ] || { echo "release server lock is free"; exit 0; }
    o=$(owner)
    [ "$o" = "$role" ] || { echo "release server lock is held by ${o:-nobody}, not $role" >&2; exit 3; }
    rm -rf "$lock"
    echo "release server lock released by $role"
    ;;
esac
