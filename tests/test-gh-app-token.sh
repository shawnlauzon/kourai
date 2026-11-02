#!/usr/bin/env bash
# Tests gh-app-token.sh's lookup of the mobile repo under both of its names
# (example-org/example-app and, from before the move, example-user/example-app-old).
#
# Usage: .claude/bin/test-gh-app-token.sh
#
# Nothing real is touched: curl and openssl are fakes first on PATH, the private
# key is an empty file in a temporary home, and no request leaves the machine.
# Exits 0 when every case passes, 1 otherwise.
set -uo pipefail
export KOURAI_CONFIG=${KOURAI_CONFIG:-$(cd "$(dirname "$0")" && pwd)/fixtures/config.toml}
export KOURAI_BIN=${KOURAI_BIN:-$(cd "$(dirname "$0")/../bin" && pwd)}

bin=$(cd "$(dirname "$0")/../bin" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home/Development/example_files"
touch "$tmp/home/Development/example_files/example-bot.2026-10-04.private-key.pem"
cat >"$tmp/bin/openssl" <<'E'
#!/bin/bash
if [ "$1" = base64 ]; then base64; else cat >/dev/null; echo sig; fi
E
# installation lookups: NEW_OK / OLD_OK say whether the app is installed on the repo under that name.
# The fake honors -w '\n%{http_code}': it prints the body, then a newline and the status. SEQ_FILE (optional) lists
# one status per request to the token endpoint, consumed in order; COUNT_FILE counts every request.
cat >"$tmp/bin/curl" <<'E'
#!/bin/bash
for a in "$@"; do case "$a" in https://*) u=$a ;; esac; done
[ -n "${COUNT_FILE:-}" ] && echo x >>"$COUNT_FILE"
reply() { printf '%s\n%s' "$2" "$1"; }
case "$u" in
  *repos/example-org/example-app/installation) [ "${NEW_OK:-0}" = 1 ] && reply 200 '{"id":111}' || reply 404 '{}' ;;
    *repos/example-user/example-app-old/installation) [ "${OLD_OK:-0}" = 1 ] && reply 200 '{"id":222}' || reply 404 '{}' ;;
  *repos/example-org/example-api/installation) reply 200 '{"id":333}' ;;
  *installations/*/access_tokens)
    i=${u#*installations/}
    code=200
    if [ -n "${SEQ_FILE:-}" ] && [ -s "$SEQ_FILE" ]; then code=$(head -1 "$SEQ_FILE"); sed '1d' "$SEQ_FILE" >"$SEQ_FILE.n"; mv "$SEQ_FILE.n" "$SEQ_FILE"; fi
    reply "$code" "{\"token\":\"tok-${i%%/*}\"}" ;;
  *repos/RunnerCityOrg/flaky/installation)
    if [ -n "${SEQ_FILE:-}" ] && [ -s "$SEQ_FILE" ]; then code=$(head -1 "$SEQ_FILE"); sed '1d' "$SEQ_FILE" >"$SEQ_FILE.n"; mv "$SEQ_FILE.n" "$SEQ_FILE"; else code=200; fi
    reply "$code" '{"id":444}' ;;
  *) reply 404 '{}' ;;
esac
E
chmod +x "$tmp/bin/"*

failures=0
check() { # check <name> <new installed 0|1> <old installed 0|1> <repo> <want output>
  local got
  got=$(NEW_OK=$2 OLD_OK=$3 HOME=$tmp/home PATH=$tmp/bin:/usr/bin:/bin bash "$bin/gh-app-token.sh" "$4" 2>&1)
  if [ "$got" = "$5" ]; then echo "PASS $1"; else echo "FAIL $1: want '$5', got '$got'"; failures=$((failures + 1)); fi
}
check "the new name, app on the organization's repo" 1 0 example-org/example-app tok-111
check "the new name before the move: found under the old name" 0 1 example-org/example-app tok-222
check "the old name before the move" 0 1 example-user/example-app-old tok-222
check "the old name after the move: found under the new name" 1 0 example-user/example-app-old tok-111
check "the app is installed under neither name" 0 0 example-org/example-app "gh-app-token: example-bot isn't installed on example-org/example-app"
check "the server repo is looked up under its own name only" 0 0 example-org/example-api tok-333

# Retries: 2 seconds is shortened to 0 for the tests. COUNT_FILE counts requests.
retry() { # retry <name> <statuses for the lookup, space separated> <statuses for the token> <want output> <want requests>
  local got n
  : >"$tmp/count"; : >"$tmp/seq"
  for c in $2; do echo "$c" >>"$tmp/seq"; done
  got=$(GH_APP_TOKEN_RETRY_PAUSE=0 SEQ_FILE=$tmp/seq COUNT_FILE=$tmp/count HOME=$tmp/home PATH=$tmp/bin:/usr/bin:/bin bash "$bin/gh-app-token.sh" RunnerCityOrg/flaky 2>&1)
  n=$(wc -l <"$tmp/count" | tr -d ' ')
  if [ "$got" = "$3" ] && [ "$n" = "$4" ]; then echo "PASS $1"; else echo "FAIL $1: want '$3' in $4 requests, got '$got' in $n"; failures=$((failures + 1)); fi
}
# The flaky repo's lookup answers from the sequence; the token request after it answers 200.
retry "a 503 then a 200 on the lookup gives a token" "503 200" "tok-444" 3
retry "a 429 then a 200 on the lookup gives a token" "429 200" "tok-444" 3
retry "a 404 on the lookup is one request and fails" "404" "gh-app-token: example-bot isn't installed on RunnerCityOrg/flaky" 1
retry "a 401 on the lookup is one request and fails" "401" "gh-app-token: example-bot isn't installed on RunnerCityOrg/flaky" 1
retry "two 503s on the lookup stop after two requests" "503 503" "gh-app-token: example-bot isn't installed on RunnerCityOrg/flaky" 2
[ "$failures" = 0 ] && echo "All cases passed" || { echo "$failures case(s) failed"; exit 1; }
