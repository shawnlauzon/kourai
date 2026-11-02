#!/usr/bin/env bash
# Runs a long command for an agent that starts it with run_in_background and
# then waits on it with run-wait.sh (rules.md, Waiting): its output goes to a
# file, not into the agent's context.
#
# Usage: run-bg.sh [--cwd <dir>] <log dir> <command...>
#
# Writes <log dir>/PID (this process), <log dir>/output.log (the command's
# stdout and stderr) and, when the command ends, <log dir>/END ("END <exit
# code>"). A new run in the same folder starts from an empty one. Exits with the
# command's exit code (2: usage).
set -u

cwd=""
if [ "${1:-}" = --cwd ]; then cwd=${2:-}; shift 2 || true; fi
[ $# -ge 2 ] || { echo "usage: run-bg.sh [--cwd <dir>] <log dir> <command...>" >&2; exit 2; }
dir=$1; shift
mkdir -p "$dir" || exit 2
rm -f "$dir/END" "$dir/output.log"
echo $$ >"$dir/PID"
if [ -n "$cwd" ]; then cd "$cwd" || { echo "END 2" >"$dir/END"; exit 2; }; fi
"$@" >"$dir/output.log" 2>&1
rc=$?
echo "END $rc" >"$dir/END"
exit "$rc"
