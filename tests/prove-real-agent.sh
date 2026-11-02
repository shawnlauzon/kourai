#!/usr/bin/env bash
# One real `claude -p --plugin-dir` run on a scratch copy, to prove three things the mock tests cannot:
#   1. ${CLAUDE_PLUGIN_ROOT} is substituted in a plugin agent's body;
#   2. the plugin's bin/ is on the PATH of a project agent's Bash;
#   3. a project agent can find and read the core rules (kourai-config path --plugin-root).
# It is NOT part of tests/run.sh: it calls the model once (a probe prompt with two probe agents,
# nothing from the board) and uses the live Claude login, so no CLAUDE_CONFIG_DIR and no
# `claude plugin` command here. It never runs /kourai:run-board or a real board agent.
# Prints PROVEN/UNPROVEN per piece and the slash-command names from the init message.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d /tmp/kourai-proof.XXXXXX)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/plugin" "$T/proj/.claude/agents"
(cd "$root" && git ls-files | grep -v '^tests/' | tar -cf - -T - | tar -xf - -C "$T/plugin")
cat > "$T/plugin/agents/probe-plugin.md" <<'EOA'
---
name: probe-plugin
description: "Probe. Reports the plugin root it was given."
model: haiku
tools: Read
---
Reply with exactly one line and nothing else: `PLUGIN_ROOT=${CLAUDE_PLUGIN_ROOT}`
EOA
cat > "$T/proj/.claude/agents/probe-project.md" <<'EOA'
---
name: probe-project
description: "Probe. Checks the plugin bin/ on PATH and reads the core rules."
model: haiku
tools: Bash, Read
---
Run these two Bash commands, then reply with exactly two lines and nothing else.
1. `command -v kourai-config` : line one is `BIN=<the printed path, or NONE>`.
2. `head -1 "$(kourai-config path --plugin-root)/rules/core.md"` : line two is `RULES=<the printed first line>`.
EOA
export KOURAI_CONFIG="$root/tests/fixtures/config.toml" KOURAI_DEFAULTS="$T/plugin/config/defaults.toml"
cd "$T/proj"
out=$(claude -p "Call the Agent tool twice, once with subagent_type kourai:probe-plugin and once with subagent_type probe-project, each with the prompt 'go'. Then print each agent's reply verbatim, nothing else." \
  --strict-mcp-config --output-format stream-json --verbose --plugin-dir "$T/plugin" \
  --allowedTools "Bash(command -v kourai-config)" "Bash(head -1 *)" "Bash(kourai-config *)" Read 2>&1)
rc=$?
echo "$out" > "$T/stream.jsonl"; [ -n "${KEEP_STREAM:-}" ] && cp "$T/stream.jsonl" "$KEEP_STREAM"
echo "claude exit: $rc"
python3 - "$T/stream.jsonl" "$T/plugin" <<'PY'
import json, re, sys
path, plug = sys.argv[1], sys.argv[2]
text, cmds = "", []
for line in open(path):
    try: o = json.loads(line)
    except Exception: continue
    if o.get("type") == "system" and o.get("subtype") == "init":
        cmds = o.get("slash_commands", [])
    text += json.dumps(o)
print("slash commands containing run-board:", [c for c in cmds if "run-board" in c])
m = re.search(r"PLUGIN_ROOT=([^\\\"\s]+)", text)
print("PROVEN" if m and "${" not in m.group(1) and m.group(1) else "UNPROVEN", "plugin agent body substitution:", m.group(1) if m else "no PLUGIN_ROOT line")
b = re.search(r"BIN=([^\\\"\s]+)", text)
print("PROVEN" if b and b.group(1) != "NONE" else "UNPROVEN", "plugin bin/ on a project agent's PATH:", b.group(1) if b else "no BIN line")
r = re.search(r"RULES=([^\\\"]+)", text)
print("PROVEN" if r and "core" in text.lower() and r.group(1).strip() else "UNPROVEN", "project agent reads core rules:", (r.group(1)[:60] if r else "no RULES line"))
PY
