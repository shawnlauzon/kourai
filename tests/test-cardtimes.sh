#!/usr/bin/env bash
# Tests usage/cardtimes.py on a saved history (--actions-file): no network, no Trello.
# Trello returns actions newest first; the script must still count each list once.
# Usage: .claude/bin/test-cardtimes.sh   Exits 0 when every case passes, 1 otherwise.
set -uo pipefail
export KOURAI_CONFIG=${KOURAI_CONFIG:-$(cd "$(dirname "$0")" && pwd)/fixtures/config.toml}
export KOURAI_BIN=${KOURAI_BIN:-$(cd "$(dirname "$0")/../bin" && pwd)}
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
mv_() { # date from to
  printf '{"type":"updateCard","date":"%s","data":{"card":{"shortLink":"aaaa","name":"A"},"listBefore":{"name":"%s"},"listAfter":{"name":"%s"}}}' "$1" "$2" "$3"
}
# newest first, as the API returns it; the card moves TESTING -> REVIEW -> RELEASING -> DONE
{
  echo '['
  mv_ 2026-10-17T12:00:00.000Z "RELEASING" "DONE"; echo ,
  mv_ 2026-10-16T12:00:00.000Z "REVIEW" "RELEASING"; echo ,
  mv_ 2026-10-15T12:00:00.000Z "TESTING" "REVIEW"; echo ,
  echo '{"type":"createCard","date":"2026-10-14T12:00:00.000Z","data":{"card":{"shortLink":"aaaa","name":"A"},"list":{"name":"TESTING"}}}'
  echo ']'
} >"$tmp/newest-first.json"
out=$(python3 -I "$root/bin/usage/cardtimes.py" 2026-10-01 --actions-file "$tmp/newest-first.json" 2>&1)
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; echo "$out" | sed 's/^/     /'; fail=1; fi; }
check "newest-first input: no false return to a list" '! grep -q "x2" <<<"$out" && grep -q "Cards that went back to a list (0 of 1)" <<<"$out"'
check "newest-first input: TESTING lasted 24 hours" 'grep -E "^TESTING +1 +24\.0" <<<"$out" >/dev/null'
# cut off: three cards spend 20 h in TESTING; two entered it before the history read (first move seen is TESTING -> MERGING)
{
  echo '['
  for c in b1 b2; do
    printf '{"type":"updateCard","date":"2026-10-12T20:00:00.000Z","data":{"card":{"shortLink":"%s","name":"%s"},"listBefore":{"name":"TESTING"},"listAfter":{"name":"MERGING"}}},\n' $c $c
    printf '{"type":"updateCard","date":"2026-10-13T20:00:00.000Z","data":{"card":{"shortLink":"%s","name":"%s"},"listBefore":{"name":"MERGING"},"listAfter":{"name":"DONE"}}},\n' $c $c
  done
  printf '{"type":"createCard","date":"2026-10-12T00:00:00.000Z","data":{"card":{"shortLink":"c3","name":"c3"},"list":{"name":"TESTING"}}},\n'
  printf '{"type":"updateCard","date":"2026-10-12T20:00:00.000Z","data":{"card":{"shortLink":"c3","name":"c3"},"listBefore":{"name":"TESTING"},"listAfter":{"name":"MERGING"}}},\n'
  printf '{"type":"updateCard","date":"2026-10-13T20:00:00.000Z","data":{"card":{"shortLink":"c3","name":"c3"},"listBefore":{"name":"MERGING"},"listAfter":{"name":"DONE"}}}\n'
  echo ']'
} >"$tmp/cut.json"
out=$(python3 -I "$root/bin/usage/cardtimes.py" 2026-10-01 --actions-file "$tmp/cut.json" 2>&1)
check "cut-off cards: TESTING row has only the real sample (1 card, 20.0 h)" 'grep -E "^TESTING +1 +20\.0" <<<"$out" >/dev/null'
check "cut-off cards: the cut-off count is printed" 'grep -q "Cut off.*TESTING 2" <<<"$out"'
exit $fail
