# shellcheck shell=bash
# Sourced by the wait scripts, run-locked.sh and tool/ui_test_lib.sh: the board
# watcher's pause file for a card (rules.md, Pauses). The watcher writes
# paths.pause_dir/<shortLink> (a line in it) after its PAUSE: comment and
# removes it when the card resumes or leaves BUILDING; anything running for that
# card stops at once with PAUSED (exit 5).
#
# The card comes from $RC_CARD when set, otherwise from the worktree the command
# runs in: agents' worktrees are named <agent>-<shortLink>.
# Override (tests): RC_PAUSE_DIR.

rc_pause_dir() { echo "${RC_PAUSE_DIR:-$(kourai-config get paths.pause_dir)}"; }

# rc_card_of_dir <dir>: prints the card shortLink of the worktree <dir> is in, or nothing.
rc_card_of_dir() {
  local top base
  # Not inside a git checkout (a test folder): use the folder itself.
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || top=$1
  base=$(basename "$top")
  if [[ "$base" =~ -([A-Za-z0-9]{8})$ ]]; then echo "${BASH_REMATCH[1]}"; fi
}

# rc_current_card: $RC_CARD, or the card of the current directory's worktree.
rc_current_card() {
  if [ -n "${RC_CARD:-}" ]; then echo "$RC_CARD"; else rc_card_of_dir "$PWD"; fi
}

# rc_paused <card>: true when that card's pause file exists and is not empty. The watcher writes
# a line into it (`PAUSE for <🚨 card>`) after posting the PAUSE: comment; an empty file (a
# `touch`, a stray test file) is no pause and is ignored (https://trello.com/c/wO5ZnwH4: pause
# files appeared for two cards with no PAUSE: comment, and nothing could say who wrote them).
rc_paused() { [ -n "${1:-}" ] && [ -s "$(rc_pause_dir)/$1" ]; }

# rc_run_pausable <card> <command...>: runs the command; when the card's pause
# file appears, stops it (and its direct children), prints PAUSED and returns 5.
# Otherwise returns the command's exit code. No card: just runs it.
# RC_PAUSE_POLL: seconds between checks (default 10).
rc_run_pausable() {
  local card=$1 cpid
  shift
  if [ -z "$card" ]; then "$@"; return $?; fi
  if rc_paused "$card"; then echo PAUSED; return 5; fi
  "$@" &
  cpid=$!
  # An interrupt or kill of the caller stops the command too, so a lock is never
  # released while its command still runs (the caller's EXIT trap releases it).
  # shellcheck disable=SC2064 # $cpid is meant to be fixed now
  trap "rc_stop $cpid; exit 130" INT TERM
  while kill -0 "$cpid" 2>/dev/null; do
    if rc_paused "$card"; then
      rc_stop "$cpid"
      echo PAUSED
      return 5
    fi
    sleep "${RC_PAUSE_POLL:-10}" &
    wait $! 2>/dev/null || true
  done
  wait "$cpid"
}

# rc_stop <pid>: TERM to the process and its direct children, then KILL after
# RC_STOP_GRACE seconds (default 10) for whatever ignored it.
rc_stop() {
  local pid=$1 i
  pkill -TERM -P "$pid" 2>/dev/null || true
  kill -TERM "$pid" 2>/dev/null || true
  for ((i = 0; i < ${RC_STOP_GRACE:-10}; i++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$pid" 2>/dev/null; then
    pkill -KILL -P "$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  fi
  # It has ended by now (or was never ours): wait only reaps it.
  wait "$pid" 2>/dev/null || true
}
