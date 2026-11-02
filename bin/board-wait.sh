#!/bin/bash
# The board watcher's wait: run in the foreground, with the Bash tool's
# timeout: 600000. It ends on its own within about 5 minutes (inside the 5-minute prompt cache), printing what to
# act on, or QUIET (exit 3: call it again at once). See board-wait.py for the
# events, settings and state file. Takes no arguments, except `--worktrees` (prints the
# DISK REMOVE: lines for the current candidates and nothing else; read only) and `holds` (the open release
# holds from the state file: read-only, no Trello call, no wait).
set -u
[ $# -eq 0 ] || [ "$*" = "--worktrees" ] || [ "$*" = "holds" ] || { echo "usage: board-wait.sh [--worktrees|holds]   (settings in board-wait.py)" >&2; exit 2; }
exec python3 -I "$(cd "$(dirname "$0")" && pwd)/board-wait.py" "$@"
