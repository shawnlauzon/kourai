#!/usr/bin/env bash
# Prints the user's decisions: the closed history (.claude/board/decisions-log.md),
# then every file in .claude/board/decisions/ in date order (file names start with
# yyyy-mm-dd). Read-only. DECISIONS_DIR and DECISIONS_LOG override the paths (tests).
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
log=${DECISIONS_LOG:-$root/.claude/board/decisions-log.md}
dir=${DECISIONS_DIR:-$root/.claude/board/decisions}
[ -f "$log" ] || { echo "decisions-index.sh: no such file $log" >&2; exit 2; }
[ -d "$dir" ] || { echo "decisions-index.sh: no such directory $dir" >&2; exit 2; }
cat "$log"
for f in $(ls "$dir" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}-.*\.md$' | LC_ALL=C sort); do
  grep -E '^\| [0-9]{4}-' "$dir/$f"
done
