#!/usr/bin/env bash
# Tests .claude/bin/standing-card.sh with a fake curl (no network). Usage: .claude/bin/test-standing-card.sh
set -uo pipefail
export KOURAI_CONFIG=${KOURAI_CONFIG:-$(cd "$(dirname "$0")" && pwd)/fixtures/config.toml}
export KOURAI_BIN=${KOURAI_BIN:-$(cd "$(dirname "$0")/../bin" && pwd)}
bin=$(cd "$(dirname "$0")/../bin" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failures=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; failures=$((failures + 1)); }
mkdir -p "$tmp/fakebin" "$tmp/t"
printf 'TRELLO_KEY=SECRETKEY\nTRELLO_TOKEN=SECRETTOKEN\n' >"$tmp/trello.env"
cat >"$tmp/fakebin/curl" <<'EOF'
#!/usr/bin/env bash
out="" url=""
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2 ;; -w) shift 2 ;; -*) shift ;; *) url=$1; shift ;; esac; done
path=${url#https://trello.test/1/}; path=${path%%\?*}
if [ -e "$FAKE/fail" ]; then : >"$out"; printf 500; exit 0; fi
cp "$FAKE/${path//\//_}.json" "$out"; printf 200
EOF
chmod +x "$tmp/fakebin/curl"
export FAKE=$tmp/t RC_RETRY_SLEEP=0
echo '[{"id":"b2","name":"Technical debt: High","pos":9},{"id":"b1","name":"Technical debt: High","pos":2},{"id":"b3","name":"Other","pos":1}]' >"$FAKE/boards_AbCd1234_cards.json"
long=$(printf 'x%.0s' $(seq 1 400))
cat >"$FAKE/cards_b1_checklists.json" <<EOF
[{"id":"k2","name":"Server","pos":2,"checkItems":[{"id":"i3","name":"Retry the login call","state":"incomplete","pos":1}]},
 {"id":"k1","name":"Mobile","pos":1,"checkItems":[{"id":"i1","name":"Chat sends twice (x/y#1 review: l)","state":"incomplete","pos":1},{"id":"i2","name":"Done Chat item\nsecond line $long","state":"complete","pos":2}]}]
EOF
run() { env PATH="$tmp/fakebin:$PATH" TRELLO_ENV_FILE="$tmp/trello.env" TRELLO_API_BASE=https://trello.test/1 "$bin/standing-card.sh" "$@" 2>&1; echo "rc=$?"; }

out=$(run "Technical debt: High" --find chat item)
grep -q '^CARD ari:cloud:trello::card/workspace/000000000000000000000000/b1$' <<<"$out" && pass "the first card by position is used" || fail "first card by position" "$out"
grep -q '^CHECKLIST ari:cloud:trello::checklist/workspace/000000000000000000000000/k1 Mobile items=2$' <<<"$out" && pass "a checklist line has ARI, name and item count" || fail "checklist line" "$out"
grep -q '^ITEM ari:cloud:trello::check-item/workspace/000000000000000000000000/i2 checked Done Chat item second line x' <<<"$out" && pass "a matched item shows ARI, checked state and one line" || fail "matched item" "$out"
! grep -q 'i1 ' <<<"$out" && pass "an item missing a find word is not printed" || fail "non-match printed" "$out"
[ "$(grep '^ITEM' <<<"$out" | wc -c)" -lt 420 ] && pass "item text is cut at 300 characters" || fail "item cut" "$out"
grep -q '^rc=0$' <<<"$out" && pass "exit 0" || fail "exit 0" "$out"
out=$(run "Technical debt: High" --link 'x/y#1')
grep -q 'ITEM .*/i1 unchecked Chat sends twice' <<<"$out" && pass "--link matches an item holding the text" || fail "--link" "$out"
out=$(run "Technical debt: High")
! grep -q '^ITEM' <<<"$out" && grep -q '^CHECKLIST .* Server items=1$' <<<"$out" && pass "no --find and no --link prints no item" || fail "no item" "$out"
# FULL at 190 items
python3 - "$FAKE/cards_b1_checklists.json" <<'PY'
import json, sys
json.dump([{"id": "k1", "name": "Mobile", "pos": 1, "checkItems": [{"id": "i%d" % n, "name": "n", "state": "incomplete", "pos": n} for n in range(190)]}], open(sys.argv[1], "w"))
PY
out=$(run "Technical debt: High")
grep -q '^CHECKLIST .* Mobile items=190 FULL$' <<<"$out" && pass "190 items is FULL" || fail "FULL" "$out"
out=$(run "No such card")
grep -q '^MISSING card$' <<<"$out" && pass "an unknown card prints MISSING card" || fail "MISSING" "$out"
grep -q 'SECRET' <<<"$out" && fail "key printed" "$out" || pass "the key and token are never printed"
touch "$FAKE/fail"
out=$(run "Technical debt: High")
grep -q '^rc=1$' <<<"$out" && pass "a failing Trello request exits 1" || fail "failure exit" "$out"
rm "$FAKE/fail"
out=$(run); grep -q '^rc=2$' <<<"$out" && pass "no card name is a usage error" || fail "usage" "$out"
[ "$failures" = 0 ] && echo "All cases passed" || { echo "$failures FAILED"; exit 1; }
