#!/usr/bin/env bash
# Tests verify/refusal_scan.py: a transcript with one result of each real refusal prefix, an earlier
# scan's own output, the auto-mode help text and an agent-id result gives exactly two records.
# Usage: verify/test-refusal-scan.sh   Exits 0 when it passes, 1 otherwise. No network.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/proj"
python3 -I - "$T/proj/s.jsonl" <<'PY'
import json, sys
rows = []
def use(i, cmd):
    return {"type": "assistant", "timestamp": "2026-11-01T10:00:0%dZ" % i,
            "message": {"content": [{"type": "tool_use", "id": "t%d" % i, "name": "Bash", "input": {"command": cmd}}]}}
def res(i, text):
    return {"type": "user", "timestamp": "2026-11-01T10:00:0%dZ" % i,
            "message": {"content": [{"type": "tool_result", "tool_use_id": "t%d" % i, "content": text}]}}
texts = [
    "Permission for this action was denied. Reason: [x] a refused thing. If you have other tasks, go on.",
    "The server-side auto mode classifier is unavailable. Reason: [y] it could not decide. If you have other tasks, go on.",
    "2\n1 'Permission for this action was denied'\n(the output of an earlier scan, with the auto mode classifier named in it)",
    "Usage: claude auto-mode [options]\n  Inspect the auto mode classifier configuration",
    "agent-a123: The auto mode classifier said the earlier call was fine; Permission for this action was denied is quoted here",
]
for i, t in enumerate(texts):
    rows += [use(i, "cmd%d" % i), res(i, t)]
open(sys.argv[1], "w").write("\n".join(json.dumps(r) for r in rows) + "\n")
PY
out=$(python3 -I "$here/refusal_scan.py" "$T/proj" "$T/out.json" 2>&1)
n=$(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$T/out.json")
calls=$(python3 -I -c 'import json,sys; print(",".join(r["call"] for r in json.load(open(sys.argv[1]))))' "$T/out.json")
if [ "$n" = 2 ] && [ "$calls" = "cmd0,cmd1" ]; then echo "PASS only the two real refusal prefixes are records"; echo "All cases passed"; exit 0; fi
echo "FAIL records=$n calls=$calls; scan said: $out"; exit 1
