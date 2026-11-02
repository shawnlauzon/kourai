#!/usr/bin/env bash
# Tests that every run an agent file starts in the shared scratchpad writes to a
# log folder of its own: the `--logs` folder of tool/ui_test_all.sh and the
# folder of run-bg.sh / run-wait.sh. Every agent one session starts shares that
# session's scratchpad, so a folder like `<scratchpad, absolute>/before` is the
# same folder for two cards' feature testers: on 2026-10-17 the BEFORE runs of
# two cards wrote into one folder and mixed their results.txt
# ("🪲 [Workflow] Two card runs share one logs folder, so their results.txt gets
# mixed" https://trello.com/c/Zz46N60g).
#
# Usage: .claude/bin/test-run-folders.sh
#   AGENTS_DIR=<dir> RULES_FILE=<file> point it at other copies (the default is
#   this plugin agents and rules/core.md).
#
# A scratchpad folder passes when it names the card and the run
# (`<shortLink>` and `<run>`) or, for the merger, the PR and its head (`<n>` and
# `<head7>`). It also checks that rules.md states the rule, and that
# `date -u +%Y%m%dT%H%M%SZ` (the `<run>` value) gives two runs a second apart
# different folders. Reads only; touches no network. Exits 0 when every case
# passes, 1 otherwise.
set -uo pipefail
export KOURAI_CONFIG=${KOURAI_CONFIG:-$(cd "$(dirname "$0")" && pwd)/fixtures/config.toml}
export KOURAI_BIN=${KOURAI_BIN:-$(cd "$(dirname "$0")/../bin" && pwd)}

root=$(cd "$(dirname "$0")/.." && pwd)
agents=${AGENTS_DIR:-$root/agents}
rules=${RULES_FILE:-$root/rules/core.md}

failures=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; failures=$((failures + 1)); }

[ -d "$agents" ] || { echo "test-run-folders.sh: no such directory $agents" >&2; exit 2; }
[ -f "$rules" ] || { echo "test-run-folders.sh: no such file $rules" >&2; exit 2; }

# Every scratchpad folder given to --logs, run-bg.sh (after an optional --cwd <dir>)
# or run-wait.sh, as "<file>:<line>: <folder>".
folders=$(python3 -I - "$agents" <<'PY'
import os, re, sys
d = sys.argv[1]
pat = re.compile(
    r"(?:--logs\s+|run-bg\.sh\s+(?:--cwd\s+(?:<[^>]*>|\S+)\s+)?|run-wait\.sh\s+)"
    r"(<scratchpad[^>]*>[^\s\x60)]*)")  # \x60: a backquote
for name in sorted(os.listdir(d)):
    if not name.endswith(".md"):
        continue
    with open(os.path.join(d, name), encoding="utf-8") as f:
        for i, line in enumerate(f, 1):
            for m in pat.finditer(line):
                print(f"{name}:{i}: {m.group(1)}")
PY
)

if [ -z "$folders" ]; then
  fail "scratchpad run folders found" "no --logs, run-bg.sh or run-wait.sh folder in the scratchpad in $agents"
else
  while IFS= read -r entry; do
    folder=${entry#*: }
    case "$folder" in
      *'<shortLink>'*'<run>'*|*'<n>'*'<head7>'*) pass "own folder per run: $entry" ;;
      *) fail "own folder per run: $entry" "names neither the card and the run (<shortLink>, <run>) nor the PR and its head (<n>, <head7>)" ;;
    esac
  done <<<"$folders"
fi

if grep -q 'Every run has its own log folder' "$rules"; then
  pass "rules.md states the rule"
else
  fail "rules.md states the rule" "no 'Every run has its own log folder' in $rules"
fi

# Two runs of one card a second apart get different <run> values.
r1=$(date -u +%Y%m%dT%H%M%SZ)
sleep 1
r2=$(date -u +%Y%m%dT%H%M%SZ)
if [ "$r1" != "$r2" ] && [[ "$r1" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then
  pass "two runs a second apart: $r1 and $r2"
else
  fail "two runs a second apart" "got $r1 and $r2"
fi

if [ "$failures" -eq 0 ]; then echo "ALL PASSED"; exit 0; fi
echo "$failures FAILED"; exit 1
