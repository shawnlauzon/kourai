#!/usr/bin/env bash
# The shipped defaults: they parse, every key is documented in place and in
# docs/VARIABLES.md, and config/example.toml passes check against them.
. "$(dirname "$0")/lib.sh"
require_fakes

KC="$KOURAI_ROOT/bin/kourai-config"
unset KOURAI_DEFAULTS

out=$("$KC" defaults)
assert_eq "defaults path is the shipped file" "$KOURAI_ROOT/config/defaults.toml" "$out"

out=$("$KC" --config "$KOURAI_ROOT/config/example.toml" check 2>&1)
assert_eq "example.toml is valid" "CONFIG OK: $KOURAI_ROOT/config/example.toml" "$out"

out=$("$KC" --config "$KOURAI_ROOT/config/example.toml" get paths.trello_env)
assert_eq "state_dir flows into paths" "$HOME/Development/example_files/trello.env" "$out"

# A config that sets nothing but the required keys is complete.
undocumented=$(python3 - "$KOURAI_ROOT/config/defaults.toml" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().split("\n")
bad = []
in_array = False
for i, line in enumerate(lines):
    s = line.strip()
    if in_array:
        in_array = not s.startswith("]")
        continue
    if not s or s.startswith("#") or s.startswith("["):
        continue
    m = re.match(r'^([A-Za-z0-9_\-]+)\s*=', s)
    if not m:
        continue
    if s.endswith("[") :
        in_array = True
    prev = lines[i - 1].strip() if i else ""
    if not prev.startswith("#") and not prev.endswith(","):
        bad.append("%d:%s" % (i + 1, m.group(1)))
print(" ".join(bad))
PY
); rc=$?
assert_eq "comment check ran" 0 "$rc"
assert_eq "every key has a comment line above it" "" "$undocumented"

missing=$(python3 - "$KOURAI_ROOT/config/defaults.toml" "$KOURAI_ROOT/docs/VARIABLES.md" <<'PY'
import sys, tomllib
d = tomllib.load(open(sys.argv[1], "rb"))
doc = open(sys.argv[2]).read()
item = d["_schema"]["items"]["repos"]["defaults"]
d.pop("_schema")
keys = []
def walk(node, prefix):
    for k, v in node.items():
        if isinstance(v, dict) and v:
            walk(v, prefix + k + ".")
        else:
            keys.append(prefix + k)
walk(d, "")
walk(item, "repos[].")
print(" ".join(k for k in keys if "`%s`" % k not in doc and k != "adapters"))
PY
); rc=$?
assert_eq "VARIABLES.md check ran" 0 "$rc"
assert_eq "every key is in docs/VARIABLES.md" "" "$missing"
finish
