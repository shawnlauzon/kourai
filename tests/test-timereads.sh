#!/usr/bin/env bash
# Tests .claude/bin/usage/timereads.py with saved actions, a fake gh and temporary release logs. No network.
# Usage: .claude/bin/test-timereads.sh
set -uo pipefail
export KOURAI_CONFIG=${KOURAI_CONFIG:-$(cd "$(dirname "$0")" && pwd)/fixtures/config.toml}
export KOURAI_BIN=${KOURAI_BIN:-$(cd "$(dirname "$0")/../bin" && pwd)}
bin=$(cd "$(dirname "$0")/../bin" && pwd)
tr=$bin/usage/timereads.py
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
failures=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; failures=$((failures + 1)); }
has() { if grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1" "missing '$3' in: $(cat "$2")"; fi; }
mkdir -p "$tmp/fakebin" "$tmp/logs/full-a"
export PATH="$tmp/fakebin:$PATH"

cat >"$tmp/actions.json" <<'EOF'
[{"type":"createCard","date":"2026-10-30T00:00:00.000Z","data":{"card":{"shortLink":"AAAA0001","name":"a"},"list":{"name":"TODO"}}},
 {"type":"createCard","date":"2026-10-30T00:00:00.000Z","data":{"card":{"shortLink":"BBBB0001","name":"b"},"list":{"name":"TODO"}}},
 {"type":"updateCard","date":"2026-10-30T01:00:00.000Z","data":{"card":{"shortLink":"AAAA0001"},"listBefore":{"name":"TODO"},"listAfter":{"name":"🧪 TESTING"}}},
 {"type":"updateCard","date":"2026-10-30T03:00:00.000Z","data":{"card":{"shortLink":"AAAA0001"},"listBefore":{"name":"TESTING"},"listAfter":{"name":"DONE"}}}]
EOF
python3 -I "$tr" occupancy 2026-10-30 --actions-file "$tmp/actions.json" >"$tmp/occ" 2>&1
has "occupancy counts the hours measured" "$tmp/occ" "Hours measured since 2026-10-30: 3"
has "occupancy: one card in TESTING for two of the three hours" "$tmp/occ" "Cards in TESTING (each holds a test server, of 3): mean 0.67"
has "occupancy: no hour has every server taken" "$tmp/occ" "Hours with every server taken while TODO was not empty: 0 of 3"

touch -t 202610300800 "$tmp/logs/full-a/one.log"; touch -t 202610300930 "$tmp/logs/full-a/two.log"; touch -t 202610301000 "$tmp/logs/full-a/three.log"
python3 -I "$tr" release 2026-10-01 --logs-dir "$tmp/logs" >"$tmp/rel" 2>&1
has "release: the span and the longest gap" "$tmp/rel" "full-a: 2.00 h from one.log to three.log; longest gaps before: two.log 90 min"
python3 -I "$tr" release 2027-01-01 --logs-dir "$tmp/logs" >"$tmp/rel2" 2>&1
has "release: no logs since the date is said" "$tmp/rel2" "NO RELEASE LOGS since 2027-01-01"

cat >"$tmp/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "run list --repo o/r --status failure"*) echo '[{"databaseId":1,"name":"CI","createdAt":"2026-10-31T00:00:00Z"},{"databaseId":2,"name":"CI","createdAt":"2026-09-01T00:00:00Z"}]' ;;
  "run list --repo o/r --workflow CI"*) echo '[{"databaseId":5}]' ;;
  "run view 1 "*) echo '{"jobs":[{"name":"integration","conclusion":"failure"},{"name":"unit","conclusion":"success"}]}' ;;
  "run view 5 "*) echo '{"jobs":[{"name":"Integration Suite / Integration Suite","steps":[{"name":"Run suite","startedAt":"2026-10-31T00:00:00Z","completedAt":"2026-10-31T00:12:00Z"}]}]}' ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/fakebin/gh"
python3 -I "$tr" ci-failures o/r 2026-10-01 >"$tmp/ci" 2>&1
has "ci-failures: counts only runs since the date" "$tmp/ci" "Failed runs of o/r since 2026-10-01: 1"
has "ci-failures: failed jobs by name" "$tmp/ci" "failed job integration: 1"
python3 -I "$tr" suite-steps o/r >"$tmp/ss" 2>&1
has "suite-steps: minutes per step" "$tmp/ss" "Run suite: median 12.0, longest 12.0 (1 runs)"
python3 -I "$tr" gap >"$tmp/gap" 2>&1
has "gap names the missing source" "$tmp/gap" "NO SOURCE: near-whole-suite AFTER runs"
python3 -I "$tr" >"$tmp/u" 2>&1; has "no argument prints the usage" "$tmp/u" "Usage: python3 -I timereads.py"
[ "$failures" = 0 ] && echo "All cases passed" || { echo "$failures FAILED"; exit 1; }
