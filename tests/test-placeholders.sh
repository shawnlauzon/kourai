#!/usr/bin/env bash
# Every setting-like placeholder (<app-checkout>, <state_dir>, <board-id>, <conflict-label-id>, <bot-name>, ...)
# used in the agents, commands and rules must be in the Placeholders table of rules/core.md, and each
# table key must exist in config/defaults.toml. Fill-ins (<n>, <card>, <why>, ...) need no row.
#
# Usage: tests/test-placeholders.sh [<extra folder holding agents/ and commands/ or .claude/agents> ...]
# Reads only; no network. Prints PASS/FAIL lines, then ALL PASSED or <n> FAILED.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
exec python3 -I - "$here" "$@" <<'PY'
import glob, os, re, sys, tomllib
root, extra = sys.argv[1], sys.argv[2:]
fails = 0
def fail(m):
    global fails
    fails += 1
    print("FAIL " + m)
core = open(os.path.join(root, "rules/core.md")).read()
rows = dict(re.findall(r"^\| `(<[^`]+>)` \| `([^`]+)` \|", core, re.M))
defaults = tomllib.load(open(os.path.join(root, "config/defaults.toml"), "rb"))
def key_exists(k):
    parts = k.split(".")
    if parts[0] == "repos" and len(parts) == 3 and parts[1].isdigit():
        return parts[2] in defaults["_schema"]["items"]["repos"]["defaults"]
    cur = defaults
    for p in parts:
        if not isinstance(cur, dict) or p not in cur:
            return False
        cur = cur[p]
    return True
for ph, key in rows.items():
    if not key_exists(key):
        fail(f"placeholder-key: {ph} maps to {key}, not in config/defaults.toml")
if rows:
    print("PASS table-keys-exist")
files = glob.glob(root + "/agents/*.md") + glob.glob(root + "/commands/*.md") + [root + "/rules/core.md"]
for e in extra:
    files += glob.glob(e + "/agents/*.md") + glob.glob(e + "/commands/*.md") + glob.glob(e + "/.claude/agents/*.md") \
        + glob.glob(e + "/.claude/commands/*.md") + glob.glob(e + "/.claude/board/rules.md")
settingish = re.compile(r"^<(?:[a-z0-9]+(?:-[a-z0-9]+)*-(?:checkout|repo|id|name)|[a-z_]+_dir|app-repo-old-name)>$")
seen = {}
for f in files:
    for m in re.findall(r"<[a-z][a-z0-9_\-]*>", open(f).read()):
        if settingish.match(m) and m not in rows:
            seen.setdefault(m, set()).add(os.path.basename(f))
for m, fs in sorted(seen.items()):
    fail(f"placeholder-in-table: {m} (in {', '.join(sorted(fs))}) has no row in the Placeholders table of rules/core.md")
if not seen:
    print("PASS every-setting-placeholder-has-a-row")
print("ALL PASSED" if not fails else f"{fails} FAILED")
sys.exit(1 if fails else 0)
PY
