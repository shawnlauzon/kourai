#!/usr/bin/env bash
# Runs every tests/test-*.sh. Before any test runs, tests/fakes goes first on
# PATH so no test can reach AWS, Tailscale, GitHub, Trello or a server: the
# fakes fail loudly and log each call to $KOURAI_TEST_NETLOG.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
export PATH="$root/tests/fakes:$PATH"
export KOURAI_TEST_NETLOG="$root/tests/.tmp/netlog"
mkdir -p "$root/tests/.tmp"
: > "$KOURAI_TEST_NETLOG"
# Never let a test pick up a real installation's config.
unset KOURAI_CONFIG KOURAI_DEFAULTS

for t in aws tailscale ssh curl gh git; do
  case "$(command -v "$t")" in
    "$root/tests/fakes/"*) ;;
    *) echo "SETUP FAILED: $t does not resolve to tests/fakes" >&2; exit 2 ;;
  esac
done

status=0
for t in "$root"/tests/test-*.sh; do
  bash "$t" || status=1
done

if [ -s "$KOURAI_TEST_NETLOG" ]; then
  echo "NETWORK CALLS IN TESTS (each is a test bug):" >&2
  cat "$KOURAI_TEST_NETLOG" >&2
  status=1
fi
rm -rf "$root/tests/.tmp"
[ "$status" -eq 0 ] && echo "ALL GREEN" || echo "RED"
exit "$status"
