#!/usr/bin/env bash
# Test for decisions-index.sh, in temporary directories.
set -uo pipefail
export KOURAI_CONFIG=${KOURAI_CONFIG:-$(cd "$(dirname "$0")" && pwd)/fixtures/config.toml}
export KOURAI_BIN=${KOURAI_BIN:-$(cd "$(dirname "$0")/../bin" && pwd)}
here=$(cd "$(dirname "$0")/../bin" && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir "$t/d"; printf '# log\n| Date | Decision |\n|---|---|\n| 2026-10-06 | old |\n' > "$t/log.md"
printf '| 2026-10-20 | later |\n' > "$t/d/2026-10-20-bbbb.md"
printf '| 2026-10-19 | earlier |\n' > "$t/d/2026-10-19-aaaa.md"
printf 'note\n' > "$t/d/README.md"
out=$(DECISIONS_LOG="$t/log.md" DECISIONS_DIR="$t/d" bash "$here/decisions-index.sh"); fail=0
exp=$'# log\n| Date | Decision |\n|---|---|\n| 2026-10-06 | old |\n| 2026-10-19 | earlier |\n| 2026-10-20 | later |'
[ "$out" = "$exp" ] && echo "PASS history, then files by date" || { echo "FAIL: $out"; fail=1; }
DECISIONS_LOG="$t/none" DECISIONS_DIR="$t/d" bash "$here/decisions-index.sh" >/dev/null 2>&1; [ $? = 2 ] && echo "PASS missing log exits 2" || { echo FAIL missing; fail=1; }
exit $fail
