#!/usr/bin/env bash
# Tests release-gap.sh with a fake curl (no network): a few seconds.
# Usage: .claude/bin/test-release-gap.sh. Exits 0 when every case passes, 1 otherwise.
set -uo pipefail
export KOURAI_CONFIG=${KOURAI_CONFIG:-$(cd "$(dirname "$0")" && pwd)/fixtures/config.toml}
export KOURAI_BIN=${KOURAI_BIN:-$(cd "$(dirname "$0")/../bin" && pwd)}
bin=$(cd "$(dirname "$0")/../bin" && pwd)
tmp=$(mktemp -d)
# shellcheck disable=SC2329 # called by the EXIT trap
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
mkdir -p "$tmp/fakebin"
for c in aws tailscale ssh; do
  printf '#!/usr/bin/env bash\necho "test: %s is not allowed in tests" >&2\nexit 99\n' "$c" >"$tmp/fakebin/$c"
  chmod +x "$tmp/fakebin/$c"
done
cat >"$tmp/fakebin/curl" <<EOF2
#!/usr/bin/env bash
out=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out=\$2; shift 2 ;; *) shift ;; esac; done
[ -f $tmp/moves.json ] || exit 22
cp $tmp/moves.json "\$out"
EOF2
chmod +x "$tmp/fakebin/curl"
export PATH="$tmp/fakebin:$PATH"
printf 'TRELLO_KEY=k\nTRELLO_TOKEN=t\n' >"$tmp/trello.env"
export TRELLO_ENV_FILE=$tmp/trello.env TRELLO_API_BASE=https://trello.test/1
failures=0
t() { # t <name> <expected rc> <expected text> <args…>
  local name=$1 rc=$2 text=$3; shift 3
  out=$("$bin/release-gap.sh" "$@" 2>&1); got=$?
  if [ "$got" = "$rc" ] && grep -qF -- "$text" <<<"$out"; then echo "PASS $name"
  else echo "FAIL $name: rc=$got out=$out"; failures=$((failures + 1)); fi
}
move() { printf '{"date":"%s","data":{"listBefore":{"name":"%s"},"listAfter":{"name":"%s"}}}' "$1" "$2" "$3"; }
now=$(python3 -I -c 'import datetime as d; print(int(d.datetime(2026,10,16,12,0,tzinfo=d.timezone.utc).timestamp()))')
export RELEASE_GAP_NOW=$now

# Release ended 09:00 (3 h ago): wait until 17:00. Older moves and other moves are ignored.
echo "[$(move 2026-10-16T09:00:00.000Z '🚀 RELEASING' '✅ DONE'),$(move 2026-10-16T11:00:00.000Z 'MERGING' 'MERGED'),$(move 2026-10-15T01:00:00.000Z 'RELEASING' 'DONE')]" >"$tmp/moves.json"
t "3 hours after a DONE move: wait" 1 "GAP WAIT: until 2026-10-16 17:00 UTC (the last release ended 2026-10-16 09:00 UTC)"
t "an urgent release is exempt" 0 "GAP EXEMPT: urgent release" --urgent
# Back to MERGED counts as an end too; 8 hours exactly is over.
echo "[$(move 2026-10-16T04:00:00.000Z 'RELEASING' 'MERGED')]" >"$tmp/moves.json"
t "exactly 8 hours after a move back to MERGED: over" 0 "GAP OVER: no release has ended in the last 8 hours"
echo "[$(move 2026-10-16T04:00:01.000Z 'RELEASING' 'MERGED')]" >"$tmp/moves.json"
t "1 second short of 8 hours: wait" 1 "GAP WAIT"
# A move into VERIFY (an external card released) ends the release like one into DONE.
echo "[$(move 2026-10-16T09:00:00.000Z 'RELEASING' 'VERIFY')]" >"$tmp/moves.json"
t "3 hours after a VERIFY move: wait" 1 "GAP WAIT: until 2026-10-16 17:00 UTC"
# The default is 8 hours, not 12: 4 hours and 1 minute after an end still waits.
echo "[$(move 2026-10-16T07:59:00.000Z 'RELEASING' 'DONE')]" >"$tmp/moves.json"
t "4 hours after an end: still waits (default 8)" 1 "GAP WAIT: until 2026-10-16 15:59 UTC"
# Only moves that are not out of RELEASING: no release has ended.
echo "[$(move 2026-10-16T11:00:00.000Z 'MERGED' 'RELEASING'),$(move 2026-10-16T11:30:00.000Z 'MERGING' 'DONE')]" >"$tmp/moves.json"
t "no move out of RELEASING: over" 0 "last end none"
echo "[]" >"$tmp/moves.json"
t "an empty history: over" 0 "GAP OVER"
rm "$tmp/moves.json"
t "a failed Trello request: exit 3, never starts" 3 "Trello request failed"
# A 429 from Trello (curl -f exits 22) is a failed read too: exit 3 (never 1, which means "gap not over"), with the message, and no retry
# (the caller allows 30 seconds; card https://trello.com/c/xXtokNFg). The fake curl fails the same way when moves.json is missing.
t "a Trello 429 (curl exit 22): exit 3, not 1" 3 "release-gap: Trello request failed"
t "usage" 2 "usage" --bad
RELEASE_GAP_HOURS=2 t "the hours setting is read" 2 "usage" a b
echo "[$(move 2026-10-16T09:00:00.000Z 'RELEASING' 'DONE')]" >"$tmp/moves.json"
RELEASE_GAP_HOURS=2 t "a 2 hour gap is over after 3 hours" 0 "GAP OVER"
echo
if [ "$failures" -eq 0 ]; then echo "All cases passed"; exit 0; fi
echo "$failures case(s) failed"; exit 1
