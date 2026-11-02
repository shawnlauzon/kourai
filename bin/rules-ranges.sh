#!/usr/bin/env bash
# Keeps the rules.md markers named in the agent files true.
#
# Usage:
#   rules-ranges.sh list    # every "## " section of rules.md with its line
#   rules-ranges.sh check   # every [rules.md: First to Last] marker in .claude/agents/*.md
#
# An agent reads only its parts of rules.md. A part is written in its agent file
# as `[rules.md: <first section>]` or `[rules.md: <first section> to <last section>]`:
# section names only, no line numbers, so a rules.md edit never makes a marker
# stale and two PRs that edit rules.md never conflict on a marker. The agent finds
# the lines with one heading lookup (grep -n '^## ' on rules.md) and reads the part
# with offset = the first section's heading line and limit = (the line of the
# heading after the last section - 1) - offset + 1; a last section that is the
# final heading of the file is read from its line to the end with no limit.
# A marker is true when both names are "## " headings of rules.md and the first
# comes before (or is) the last. `check` fails on a name that is no heading
# (renamed or removed), on a reversed pair, and on an old numeric marker
# `[rules.md A-B: ...]` (it prints the replacement), and when no marker is found
# at all, and when an agent file that has a "Read only your parts of ... rules.md"
# line carries no marker. Headings must not contain " to " or "]", because the
# marker syntax splits on them; `check` fails on such a heading. A missing rules
# file or agents directory prints "rules-ranges.sh: no such file <path>" and
# exits 2. Reads only; touches nothing.
set -uo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
rules=${RULES_FILE:-$root/.claude/board/rules.md}
agents=${AGENTS_DIR:-$root/.claude/agents}

case "${1:-}" in
  list | check) ;;
  *) echo "usage: rules-ranges.sh list|check" >&2; exit 2 ;;
esac

for p in "$rules" "$agents"; do
  if [ ! -e "$p" ]; then echo "rules-ranges.sh: no such file $p" >&2; exit 2; fi
done

exec python3 -I - "$1" "$rules" "$agents" <<'PY'
import glob, os, re, sys

mode, rules, agents = sys.argv[1:4]
lines = open(rules, encoding="utf-8").read().split("\n")
if lines and lines[-1] == "":
    lines.pop()
total = len(lines)
starts = [(i + 1, l[3:].strip()) for i, l in enumerate(lines) if l.startswith("## ")]
sections = []  # (name, first, last)
for k, (n, name) in enumerate(starts):
    last = starts[k + 1][0] - 1 if k + 1 < len(starts) else total
    sections.append((name, n, last))

if mode == "list":
    for name, a, b in sections:
        print(f"{a}\t{name}")
    sys.exit(0)

by_name = {s[0]: s for s in sections}
marker = re.compile(r"\[rules\.md: (.+?)(?: to (.+?))?\]")
old = re.compile(r"\[rules\.md (\d+)-(\d+): [^\]]*\]")


def name_at(line, want_start):
    for name, a, b in sections:
        if (want_start and a == line) or (not want_start and a <= line <= b):
            return name
    return None


bad = 0
seen = 0
for name, a, b in sections:
    if " to " in name or "]" in name:
        print(f"FAIL rules.md:{a}: heading \"{name}\" contains \" to \" or \"]\", which the marker syntax cannot name")
        bad += 1
for path in sorted(glob.glob(os.path.join(agents, "*.md"))):
    text = open(path, encoding="utf-8").read()
    who = os.path.basename(path)
    found = list(marker.finditer(text))
    for m in old.finditer(text):
        a, b = int(m.group(1)), int(m.group(2))
        f, l = name_at(a, True), name_at(b, False)
        rep = f"[rules.md: {f}]" if f and f == l else (f"[rules.md: {f} to {l}]" if f and l else "[rules.md: <first section> to <last section>]")
        print(f"FAIL {who}: {m.group(0)}: numeric markers are retired; write {rep}")
        bad += 1
    if not found and not old.search(text) and "Read only your parts of" in text:
        print(f"FAIL {who}: reads rules.md by parts but has no [rules.md: ...] marker")
        bad += 1
    for m in found:
        seen += 1
        first, last = m.group(1), m.group(2) or m.group(1)
        if first not in by_name or last not in by_name:
            print(f"FAIL {who}: {m.group(0)}: no such section in rules.md")
            bad += 1
        elif by_name[first][1] > by_name[last][1]:
            print(f"FAIL {who}: {m.group(0)}: last section comes before the first")
            bad += 1
if seen == 0:
    print("FAIL no [rules.md: ...] marker found in any agent file")
    bad += 1
print(f"{seen} markers checked, {bad} wrong")
sys.exit(1 if bad else 0)
PY
