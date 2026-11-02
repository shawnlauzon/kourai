#!/usr/bin/env bash
# Keeps the rules markers named in the agent files true.
#
# Usage:
#   rules-ranges.sh list    # every "## " section of the core and project rules: file, line, heading
#   rules-ranges.sh check   # every marker in the agent files
#
# The rules are two files: the core rules (rules/core.md in the plugin) and the
# project rules (project.rules_file in the config). An agent reads only its parts.
# A part is written in its agent file as `[core: <section>]`, `[core: <first> to <last>]`
# or `[project: <section>]` (a `[project: ... to ...]` span works the same way):
# section names only, no line numbers, so a rules edit never makes a marker stale and
# two PRs that edit the rules never conflict on a marker. The agent finds the lines
# with `rules-ranges.sh list` and reads the part with offset = the first section's
# heading line and limit = (the line of the heading after the last section - 1) - offset + 1;
# a last section that is the final heading of its file is read to the end with no limit.
# A marker is true when both names are "## " headings of that file and the first comes
# before (or is) the last. `check` fails on a name that is no heading (renamed or
# removed), on a reversed pair, on a retired `[rules.md: ...]` marker, when no marker is
# found at all, when an agent file with a "Read only your parts of" line carries no
# marker, and when the project rules lack one of the four required headings
# (Project settings, Tests, Test servers, Releasing: rules/project-template.md). Headings
# must not contain " to " or "]". A missing file prints "rules-ranges.sh: no such file
# <path>" and exits 2. Reads only; touches nothing.
#
# Files: RULES_CORE, RULES_PROJECT and AGENTS_DIR (a colon-separated list of folders) override
# the config and plugin defaults.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
case "${1:-}" in
  list | check) ;;
  *) echo "usage: rules-ranges.sh list|check" >&2; exit 2 ;;
esac

root=$("$here/kourai-config" path --plugin-root 2>/dev/null || dirname "$here")
core=${RULES_CORE:-$root/rules/core.md}
project=${RULES_PROJECT:-$("$here/kourai-config" get project.rules_file 2>/dev/null || true)}
agents=${AGENTS_DIR:-$root/agents}

for p in "$core" "$project"; do
  if [ -z "$p" ] || [ ! -e "$p" ]; then echo "rules-ranges.sh: no such file ${p:-<project.rules_file is not set>}" >&2; exit 2; fi
done
IFS=: read -r -a adirs <<<"$agents"
for p in "${adirs[@]}"; do
  if [ ! -d "$p" ]; then echo "rules-ranges.sh: no such file $p" >&2; exit 2; fi
done

exec python3 -I - "$1" "$core" "$project" "$agents" <<'PY'
import glob, os, re, sys

mode, core, project, agents = sys.argv[1:5]
files = {"core": core, "project": project}
REQUIRED = ["Project settings", "Tests", "Test servers", "Releasing"]


def parse(path):
    lines = open(path, encoding="utf-8").read().split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    total = len(lines)
    starts = [(i + 1, l[3:].strip()) for i, l in enumerate(lines) if l.startswith("## ")]
    out = []  # (name, first, last)
    for k, (n, name) in enumerate(starts):
        last = starts[k + 1][0] - 1 if k + 1 < len(starts) else total
        out.append((name, n, last))
    return out


secs = {k: parse(v) for k, v in files.items()}

if mode == "list":
    for kind in ("core", "project"):
        for name, a, b in secs[kind]:
            print(f"{kind}\t{files[kind]}\t{a}\t{name}")
    sys.exit(0)

by_name = {k: {s[0]: s for s in v} for k, v in secs.items()}
marker = re.compile(r"\[(core|project): (.+?)(?: to (.+?))?\]")
retired = re.compile(r"\[rules\.md(?: \d+-\d+)?: [^\]]*\]")
bad = 0
seen = 0
for kind in ("core", "project"):
    for name, a, b in secs[kind]:
        if " to " in name or "]" in name:
            print(f"FAIL {kind}:{a}: heading \"{name}\" contains \" to \" or \"]\", which the marker syntax cannot name")
            bad += 1
for need in REQUIRED:
    if need not in by_name["project"]:
        print(f"FAIL project rules lack the required heading \"## {need}\"")
        bad += 1
paths = []
for d in agents.split(":"):
    paths += sorted(glob.glob(os.path.join(d, "*.md")))
for path in paths:
    text = open(path, encoding="utf-8").read()
    who = os.path.basename(path)
    found = list(marker.finditer(text))
    for m in retired.finditer(text):
        # a rules.md marker with placeholder words in a prose example is not a marker
        if re.search(r"First|Last|<|\.\.\.|\{", m.group(0)):
            continue
        print(f"FAIL {who}: {m.group(0)}: retired marker form; write [core: ...] or [project: ...]")
        bad += 1
    if not found and "Read only your parts of" in text:
        print(f"FAIL {who}: reads the rules by parts but has no [core: ...] or [project: ...] marker")
        bad += 1
    for m in found:
        kind = m.group(1)
        first, last = m.group(2), m.group(3) or m.group(2)
        if first in ("First", "Heading", "...") or "<" in first:
            continue  # an explanation, not a marker
        seen += 1
        names = by_name[kind]
        if first not in names or last not in names:
            print(f"FAIL {who}: {m.group(0)}: no such section in the {kind} rules")
            bad += 1
        elif names[first][1] > names[last][1]:
            print(f"FAIL {who}: {m.group(0)}: last section comes before the first")
            bad += 1
if seen == 0:
    print("FAIL no [core: ...] or [project: ...] marker found in any agent file")
    bad += 1
print(f"{seen} markers checked, {bad} wrong")
sys.exit(1 if bad else 0)
PY
