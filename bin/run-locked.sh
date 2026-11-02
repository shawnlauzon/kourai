#!/bin/bash
# Runs a command while holding a named lock on the Mac, so two agents never use
# the same local resource at once. Today's use: the server's local test database
# (a fixed name in the server's database config) is shared
# by every server branch, and up to three cards are built at once, so every
# server-builder runs `rails test` (and `db:test:prepare`) through the lock
# `server-test-db`.
#
# Usage: run-locked.sh <lock name> <command...>
#
# A lock is a directory <lock dir>/<name>.lock holding the owner's PID (mkdir is
# atomic); a lock whose owner is gone is cleared. Waits up to $RUN_LOCKED_TIMEOUT
# seconds (default 14400), then exit 6. While it waits and runs it keeps
# $CARD_HEARTBEAT fresh every minute.
#
# A paused card (its pause file, pause-lib.sh; the card is the
# worktree's <agent>-<shortLink>, or $RC_CARD) stops it at once, waiting or
# running: it prints PAUSED and exits 5, stopping the command.
# Override (tests): RC_LOCK_DIR (default paths.locks_dir),
# RC_PAUSE_DIR, RC_PAUSE_POLL (seconds between pause checks while the command
# runs, default 10).
set -u
. "$(dirname "${BASH_SOURCE[0]}")/kourai-env.sh"

# shellcheck source=pause-lib.sh source-path=SCRIPTDIR
. "$(cd "$(dirname "$0")" && pwd)/pause-lib.sh"
card=$(rc_current_card)

name=${1:-}
[[ "$name" =~ ^[a-z0-9-]+$ ]] && [ $# -ge 2 ] || { echo "usage: run-locked.sh <lock name> <command...>" >&2; exit 2; }
shift
dir="${RC_LOCK_DIR:-$(kc paths.locks_dir)}/$name.lock"
mkdir -p "$(dirname "$dir")"

if [ -n "${CARD_HEARTBEAT:-}" ]; then
  me=$$
  ( while kill -0 "$me" 2>/dev/null; do touch "$CARD_HEARTBEAT"; sleep "${HEARTBEAT_INTERVAL:-60}"; done ) >/dev/null 2>&1 &
fi

if rc_paused "$card"; then echo PAUSED; exit 5; fi
waited=0 announced=0 grace=0
until mkdir "$dir" 2>/dev/null; do
  if rc_paused "$card"; then echo PAUSED; exit 5; fi
  pid=$(cat "$dir/pid" 2>/dev/null || true)
  if [ -z "$pid" ]; then
    grace=$((grace + 1))
    if [ "$grace" -gt 5 ]; then rm -rf "$dir"; grace=0; continue; fi
  elif ! kill -0 "$pid" 2>/dev/null; then
    echo "Clearing the stale lock $name (owner $pid is gone)" >&2
    rm -rf "$dir"
    continue
  fi
  if [ "$announced" -eq 0 ]; then
    echo "Waiting for the lock $name (held by process ${pid:-?})" >&2
    announced=1
  fi
  if [ "$waited" -ge "${RUN_LOCKED_TIMEOUT:-14400}" ]; then
    echo "Gave up waiting for the lock $name after ${waited}s" >&2
    exit 6
  fi
  sleep 1
  waited=$((waited + 1))
done
echo $$ >"$dir/pid"
trap 'rm -rf "$dir"' EXIT
trap 'exit 130' INT TERM
rc_run_pausable "$card" "$@"
exit $?
