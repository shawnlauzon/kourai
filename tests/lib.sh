#!/usr/bin/env bash
# Shared helpers for kourai script tests. Sourced by each tests/test-*.sh.
# tests/run.sh has already put tests/fakes first on PATH; a test run on its
# own refuses to start without that (see require_fakes).

KOURAI_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export KOURAI_ROOT
FAILS=0
PASSES=0

require_fakes() {
  local t
  for t in aws tailscale ssh curl gh git; do
    case "$(command -v "$t")" in
      "$KOURAI_ROOT/tests/fakes/"*) ;;
      *) echo "SETUP FAILED: $t is not the fake from tests/fakes; run tests through tests/run.sh" >&2; exit 2 ;;
    esac
  done
}

new_tmp() {
  mkdir -p "$KOURAI_ROOT/tests/.tmp"
  mktemp -d "$KOURAI_ROOT/tests/.tmp/t.XXXXXX"
}

pass() { PASSES=$((PASSES + 1)); }
fail() { FAILS=$((FAILS + 1)); echo "  FAIL: $*" >&2; }

# assert_eq <name> <expected> <actual>
assert_eq() {
  if [ "$2" = "$3" ]; then pass; else fail "$1: expected [$2], got [$3]"; fi
}

# assert_contains <name> <needle> <haystack>
assert_contains() {
  case "$3" in
    *"$2"*) pass ;;
    *) fail "$1: [$2] not in [$3]" ;;
  esac
}

finish() {
  echo "$(basename "$0"): $PASSES passed, $FAILS failed"
  [ "$FAILS" -eq 0 ]
}

# guard_claude_config: an installer test runs `claude plugin ...` only against a scratch
# CLAUDE_CONFIG_DIR, never the live ~/.claude. Call it before any such command.
guard_claude_config() {
  case "${CLAUDE_CONFIG_DIR:-}" in
    "") echo "SETUP FAILED: CLAUDE_CONFIG_DIR is unset" >&2; exit 2 ;;
    "$HOME/.claude"|"$HOME/.claude/"*) echo "SETUP FAILED: CLAUDE_CONFIG_DIR is the live ~/.claude" >&2; exit 2 ;;
  esac
}

# guard_path <path>: refuse any path under the live ~/.claude or the live runner_city checkout.
guard_path() {
  case "$1" in
    "$HOME/.claude"|"$HOME/.claude/"*|/Users/shawn/Development/github/runner_city|/Users/shawn/Development/github/runner_city/*)
      echo "SETUP FAILED: test path $1 is live" >&2; exit 2 ;;
  esac
}
