#!/usr/bin/env bash
# Waits for a run started with run-bg.sh, and ends on its own within the wait
# limit (rules.md, Waiting).
#
# Usage: run-wait.sh <log dir> [--card <shortLink>]
#        run-wait.sh stop <log dir>
#
# stop: ends a run started with run-bg.sh by signalling only the DESCENDANTS of
# the PID in <log dir>/PID (children first: TERM, then KILL after RC_STOP_GRACE
# seconds, default 10), never run-bg.sh itself, so run-bg.sh writes its own
# `END <code>`. It refuses unless the PID is a run-bg.sh process and END is
# absent. Prints `STOPPED <log dir>` (exit 0) or `NOT RUNNING` (exit 0, nothing
# signalled; also when the PID is not run-bg.sh). A process the run started
# (an emulator it booted) ends with it; the next run boots a fresh one.
#
# Prints, and exits with:
#   END <code>, then the last lines of output.log   the run ended    its code
#   RUNNING                                         still going: call again   124
#   PAUSED                                          the card's pause file, or
#                                                   the run ended on PAUSED (run-locked
#                                                   stopped it for a pause)   5
#   RUN DIED: …                                     no END and its process
#                                                   is gone (the run is void) 6
# Exit 2: usage. Start run-bg.sh alone, and this in the next call, so it never
# reads the folder before run-bg.sh has cleared it. Only the last lines of the output are printed (10 after a
# success, 40 after a failure); the whole log stays in output.log.
#
# Settings (tests): RUN_WAIT_LIMIT (seconds, default 270), RUN_WAIT_POLL
# (default 5), RC_PAUSE_DIR.
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=pause-lib.sh source-path=SCRIPTDIR
. "$here/pause-lib.sh"

if [ "${1:-}" = stop ]; then
  sdir=${2:-}
  [ -n "$sdir" ] || { echo "usage: run-wait.sh stop <log dir>" >&2; exit 2; }
  spid=$(cat "$sdir/PID" 2>/dev/null || true)
  if [ -f "$sdir/END" ] || [ -z "$spid" ] || ! kill -0 "$spid" 2>/dev/null \
     || ! ps -p "$spid" -o command= 2>/dev/null | grep -q 'run-bg\.sh'; then
    echo "NOT RUNNING"; exit 0
  fi
  # Descendants, deepest first (so a parent cannot respawn what we just signalled).
  table=$(ps -A -o pid= -o ppid= 2>/dev/null)
  desc=""
  walk() { local k; for k in $(printf '%s\n' "$table" | awk -v p="$1" '$2==p{print $1}'); do walk "$k"; desc="$desc $k"; done; }
  walk "$spid"
  # shellcheck disable=SC2086
  [ -z "$desc" ] || kill -TERM $desc 2>/dev/null || true
  for _ in $(seq 1 "${RC_STOP_GRACE:-10}"); do
    alive=""; for k in $desc; do kill -0 "$k" 2>/dev/null && alive="$alive $k"; done
    [ -z "$alive" ] && break
    sleep 1
  done
  # shellcheck disable=SC2086
  [ -z "${alive:-}" ] || kill -KILL $alive 2>/dev/null || true
  echo "STOPPED $sdir"; exit 0
fi

dir=${1:-}
[ -n "$dir" ] || { echo "usage: run-wait.sh <log dir> [--card <shortLink>]" >&2; exit 2; }
card=""
if [ "${2:-}" = --card ]; then card=${3:-}; fi

limit=${RUN_WAIT_LIMIT:-270} poll=${RUN_WAIT_POLL:-5}
start=$SECONDS
# run-bg.sh may still be starting: give it up to 30 seconds to write its PID.
for _ in $(seq 1 30); do [ -f "$dir/PID" ] || [ -f "$dir/END" ] && break; sleep 1; done
while :; do
  if [ -f "$dir/END" ]; then
    read -r _ code <"$dir/END"
    # run-locked.sh stopped the command for a pause: a paused run, not a result.
    if [ -f "$dir/output.log" ] && [ "$(tail -n 1 "$dir/output.log")" = PAUSED ]; then echo PAUSED; exit 5; fi
    echo "END $code"
    if [ "$code" = 0 ]; then n=10; else n=40; fi
    [ -f "$dir/output.log" ] && tail -n "$n" "$dir/output.log"
    exit "$code"
  fi
  if rc_paused "$card"; then echo PAUSED; exit 5; fi
  pid=$(cat "$dir/PID" 2>/dev/null || true)
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    # A run that ended between the END check and here wrote its END: look once more.
    if [ -f "$dir/END" ]; then continue; fi
    echo "RUN DIED: no END in $dir and its process ${pid:-?} is gone; the run is void"
    [ -f "$dir/output.log" ] && tail -n 20 "$dir/output.log"
    exit 6
  fi
  if [ $((SECONDS - start)) -ge "$limit" ]; then echo RUNNING; exit 124; fi
  sleep "$poll"
done
