#!/usr/bin/env bash
# Tests the usage scripts' cost (model and token-type weighted) with fake transcripts in a temp
# dir; no network, no real transcripts. Every script runs as the auditor runs it, `python3 -I`,
# from a different working directory (so a broken sibling import fails here).
# Usage: .claude/bin/test-usage-cost.sh. Exits 0 when every case passes, 1 otherwise.
set -uo pipefail
export KOURAI_CONFIG=${KOURAI_CONFIG:-$(cd "$(dirname "$0")" && pwd)/fixtures/config.toml}
export KOURAI_BIN=${KOURAI_BIN:-$(cd "$(dirname "$0")/../bin" && pwd)}
bin=$(cd "$(dirname "$0")/../bin" && pwd)
use=$bin/usage
tmp=$(mktemp -d)
# shellcheck disable=SC2329 # called by the EXIT trap
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
mkdir -p "$tmp/proj" "$tmp/cwd"
cd "$tmp/cwd" || exit 1
failures=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; failures=$((failures + 1)); }
has() { # has <name> <file> <text>
  if grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1" "missing: $3"; sed 's/^/    /' "$2" | head -30; fi
}
hasnt() {
  if grep -qF -- "$3" "$2"; then bad "$1" "unexpected: $3"; else ok "$1"; fi
}

# 1. cost.py by hand-computed values (USD = tokens x price per million / 1e6).
python3 -I - "$use/cost.py" >"$tmp/cost.out" 2>&1 <<'PY'
import importlib.util, sys
s = importlib.util.spec_from_file_location("cost", sys.argv[1]); c = importlib.util.module_from_spec(s); s.loader.exec_module(c)
def near(a, b): return abs(a - b) < 1e-9
A = {"input_tokens": 1000, "cache_creation_input_tokens": 2000, "cache_creation": {"ephemeral_1h_input_tokens": 500},
     "cache_read_input_tokens": 10000, "output_tokens": 100}
d, p = c.request_cost("claude-opus-5-5", A); assert near(d, 0.0195) and p, d
B = {"input_tokens": 1000, "cache_read_input_tokens": 50000, "output_tokens": 200}
d, p = c.request_cost("claude-sonnet-5-5", B); assert near(d, 0.009) and p, d
HS = {"input_tokens": 10000, "cache_read_input_tokens": 20000, "output_tokens": 100}
d, p = c.request_cost("claude-haiku-5-5", HS); assert near(d, 0.00125) and p, d
HL = {"input_tokens": 50000, "cache_read_input_tokens": 60000, "output_tokens": 100}
assert c.request_key("claude-haiku-5-5", HL) == "claude-haiku-5-5>100k"
d, p = c.request_cost("claude-haiku-5-5", HL); assert near(d, 0.02825) and p, d
d, p = c.request_cost("claude-haiku-4-5-20251001", HS); assert near(d, 10000 * 1 / 1e6 + 20000 * 0.10 / 1e6 + 100 * 5 / 1e6) and p
U = {"input_tokens": 1000, "output_tokens": 100}
d, p = c.request_cost("claude-mystery-9", U); assert near(d, 0.006) and not p, (d, p)
d, p = c.request_cost("<synthetic>", A); assert d == 0 and p
d, p = c.request_cost(None, U); assert near(d, 0.006) and not p, (d, p)   # no model id: fallback, unpriced
assert c.request_key(None, U) == "unknown-model"
assert c.RATES_DATE and "platform.claude.com" in c.RATES_URL
print("COST OK")
PY
has "cost.py: per-model, per-kind prices, long tier, fallback, free" "$tmp/cost.out" "COST OK"

# 2. Fake transcripts: alpha (Opus only), beta (Sonnet only, more tokens, less cost), gamma (Opus + Sonnet).
python3 -I - "$tmp/proj" <<'PY'
import json, os, sys
root = sys.argv[1]
A = {"input_tokens": 1000, "cache_creation_input_tokens": 2000, "cache_creation": {"ephemeral_1h_input_tokens": 500},
     "cache_read_input_tokens": 10000, "output_tokens": 100}
B = {"input_tokens": 1000, "cache_read_input_tokens": 50000, "output_tokens": 200}
U = {"input_tokens": 1000, "output_tokens": 100}
def agent(sid, aid, typ, reqs, prompt="work", extra_tool=None):
    d = os.path.join(root, sid, "subagents"); os.makedirs(d, exist_ok=True)
    json.dump({"agentType": typ, "description": typ}, open(os.path.join(d, f"agent-{aid}.meta.json"), "w"))
    with open(os.path.join(d, f"agent-{aid}.jsonl"), "w") as f:
        f.write(json.dumps({"type": "user", "timestamp": "2026-10-17T10:00:00.000Z", "message": {"role": "user", "content": prompt}}) + "\n")
        for i, (model, usage) in enumerate(reqs):
            content = [{"type": "text", "text": "x"}]
            if extra_tool and i == 0:
                content.append(extra_tool)
            f.write(json.dumps({"type": "assistant", "timestamp": f"2026-10-17T10:{i+1:02d}:00.000Z",
                                "message": {"id": f"{aid}-{i}", "model": model, "usage": usage, "content": content}}) + "\n")
            if extra_tool and i == 0:
                f.write(json.dumps({"type": "user", "timestamp": f"2026-10-17T10:{i+1:02d}:30.000Z",
                    "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": extra_tool["id"], "content": "o" * 7000}]}}) + "\n")
OP, SO = "claude-opus-5-5", "claude-sonnet-5-5"
card = "see https://trello.com/c/AAAAAAAA for the card"
agent("s1", "a1", "alpha", [(OP, A)], card)
agent("s1", "b1", "beta", [(SO, B), (SO, B)], card)
agent("s1", "g1", "gamma", [(OP, A), (SO, B)], card)
agent("s1", "h1", "delta", [("claude-haiku-5-5", {"input_tokens": 50000, "cache_read_input_tokens": 60000, "output_tokens": 100}),
                            ("claude-haiku-5-5", {"input_tokens": 10000, "cache_read_input_tokens": 20000, "output_tokens": 100})], card)
agent("s1", "u1", "epsilon", [("claude-mystery-9", U), ("<synthetic>", A)], card)
agent("s1", "z1", "zeta", [(None, U)], card)   # a request with no model id
# the board watcher: one request that reads rules.md and runs a tool, then idles; and a no-action turn
agent("s1", "w1", "board-watcher", [(OP, A), (OP, A)], card,
      extra_tool={"type": "tool_use", "id": "t1", "name": "Read", "input": {"file_path": "/x/board/rules.md"}})
# a main session
with open(os.path.join(root, "main1.jsonl"), "w") as f:
    f.write(json.dumps({"type": "user", "timestamp": "2026-10-17T10:00:00.000Z", "message": {"role": "user", "content": "hi"}}) + "\n")
    f.write(json.dumps({"type": "assistant", "timestamp": "2026-10-17T10:01:00.000Z",
                        "message": {"id": "m-0", "model": SO, "usage": B, "content": []}}) + "\n")
PY

run() { # run <outfile> <script> <args…> ; python3 -I from the other cwd
  local out=$1; shift
  python3 -I "$use/$1" "${@:2}" >"$out" 2>&1 || { bad "$1 runs under python3 -I" "exit $?"; sed 's/^/    /' "$out" | head; }
}
run "$tmp/tokens.out" tokens.py "$tmp/proj" "$tmp/tokens.json"
has "tokens.py counts the agents" "$tmp/tokens.out" "7 agents, 1 main sessions"
python3 -I - "$tmp/tokens.json" >"$tmp/bm.out" 2>&1 <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
g = [a for a in d["agents"] if a["type"] == "gamma"][0]
assert set(g["by_model"]) == {"claude-opus-5-5", "claude-sonnet-5-5"}, g["by_model"]
assert g["by_model"]["claude-opus-5-5"]["cache_write_1h"] == 500 and g["by_model"]["claude-sonnet-5-5"]["cache_read"] == 50000
h = [a for a in d["agents"] if a["type"] == "delta"][0]
assert set(h["by_model"]) == {"claude-haiku-5-5", "claude-haiku-5-5>100k"}, h["by_model"]
assert g["tokens"]["input"] == 2000
print("BY MODEL OK")
PY
has "tokens.py writes tokens by model and kind (mixed agent, long tier)" "$tmp/bm.out" "BY MODEL OK"

run "$tmp/agg.out" agg.py "$tmp/tokens.json"
# gamma = 0.0195 + 0.009 = 0.0285; alpha 0.0195; beta 0.018: cost order alpha > beta although beta has more tokens
python3 -I - "$tmp/agg.out" >"$tmp/rank.out" 2>&1 <<'PY'
import re, sys
rows = {}
for line in open(sys.argv[1]):
    m = re.match(r"(alpha|beta|gamma|delta)\s+(\S+)\s+(\d+)\s+(\d+)", line)
    if m: rows.setdefault(m.group(1), []).append(m.group(2))
order = [l.split()[0] for l in open(sys.argv[1]) if l.split() and l.split()[0] in ("alpha", "beta", "gamma", "delta")]
assert order.index("alpha") < order.index("beta"), order   # fewer tokens, higher cost, ranked first
assert set(rows["gamma"]) == {"claude-opus-5-5", "claude-sonnet-5-5"}, rows
print("RANK OK")
PY
has "agg.py ranks an Opus agent with fewer tokens above a Sonnet agent with more tokens" "$tmp/rank.out" "RANK OK"
has "agg.py splits a mixed agent into one row per model" "$tmp/agg.out" "gamma                 claude-sonnet-5-5"
has "agg.py prices the long tier row separately" "$tmp/agg.out" "claude-haiku-5-5>100k"
has "agg.py marks and lists an unpriced model" "$tmp/agg.out" "unpriced models (priced at the most expensive known rate): claude-mystery-9, unknown-model;"
has "agg.py marks the fallback row" "$tmp/agg.out" "claude-mystery-9*"
has "agg.py marks a request with no model id as unknown-model" "$tmp/agg.out" "unknown-model*"
hasnt "agg.py never shows a model id as None" "$tmp/agg.out" "None"
hasnt "agg.py does not list <synthetic> as unpriced" "$tmp/agg.out" "synthetic>;"
has "agg.py states the price table and its date" "$tmp/agg.out" "Prices: API list prices from https://platform.claude.com/docs/en/about-claude/pricing as of "
# total cost: alpha .0195 + beta .018 + gamma .0285 + delta .0295 + epsilon .006 + zeta .006 + watcher .039 + main .009
has "agg.py total is the sum of the priced shares" "$tmp/agg.out" "total \$0"
COSTPY="$use/cost.py" python3 -I - "$tmp/tokens.json" >"$tmp/sum.out" 2>&1 <<'PY'
import importlib.util, json, sys, os
s = importlib.util.spec_from_file_location("cost", os.environ["COSTPY"]); c = importlib.util.module_from_spec(s); s.loader.exec_module(c)
d = json.load(open(sys.argv[1]))
g = [a for a in d["agents"] if a["type"] == "gamma"][0]
tot = sum(c.usd(k, t) for k, t in g["by_model"].items())
assert abs(tot - 0.0285) < 1e-9, tot
print("MIXED SUM OK")
PY
has "a mixed Opus and Sonnet agent costs the sum of the two priced shares" "$tmp/sum.out" "MIXED SUM OK"

run "$tmp/permodel.out" permodel.py "$tmp/tokens.json" 2026-10-01
has "permodel.py prints cost per hour and the price line" "$tmp/permodel.out" "Prices: API list prices"
run "$tmp/reqcat.out" reqcat.py "$tmp/proj" 2026-10-01 board-watcher
has "reqcat.py prints cost" "$tmp/reqcat.out" "cost \$0"
REQCAT="$use/reqcat.py" python3 -I - >"$tmp/cls.out" 2>&1 <<'PY'
import importlib.util, os
import ast, re, types
src = open(os.environ["REQCAT"]).read()
fn = [n for n in ast.parse(src).body if isinstance(n, ast.FunctionDef) and n.name == "cls"][0]
m = types.SimpleNamespace(); g = {"re": re}
exec(compile(ast.Module([fn], []), "cls", "exec"), g); m.cls = g["cls"]
assert m.cls("Bash", {"command": "/x/.claude/bin/agent-state.sh --owner AbCd1234 card-manager tok"}) == "ownership/state read"
assert m.cls("Bash", {"command": "/x/.claude/bin/agent-state.sh --token"}) == "ownership/state read"
assert m.cls("Bash", {"command": "/x/.claude/bin/agent-state.sh heartbeat"}) == "ownership/state read"
assert m.cls("Bash", {"command": "touch heartbeat"}) == "heartbeat/liveness"
print("CLS OK")
PY
has "reqcat.py counts agent-state.sh calls as ownership/state read, not heartbeat" "$tmp/cls.out" "CLS OK"
run "$tmp/cmwake.out" cmwake.py "$tmp/proj" 2026-10-01 board-watcher
has "cmwake.py prints cost per trigger" "$tmp/cmwake.out" "cost \$"
run "$tmp/excess.out" excess.py "$tmp/proj" 2026-10-01 5
has "excess.py prices the tokens above the cap" "$tmp/excess.out" "above cap \$"
run "$tmp/noop.out" noop.py "$tmp/proj" 2026-10-01
has "noop.py prints cost" "$tmp/noop.out" "cost_usd"
run "$tmp/rules.out" rules.py "$tmp/proj" 2026-10-01
has "rules.py prints cost after the read" "$tmp/rules.out" "cost after read \$"
run "$tmp/gaps.out" gaps.py "$tmp/proj" 2026-10-01
has "gaps.py prints the cost of late cache writes" "$tmp/gaps.out" "\$ late write"
has "gaps.py names a request with no model id unknown-model" "$tmp/gaps.out" "unknown-model"
hasnt "gaps.py never shows a model id as None" "$tmp/gaps.out" "None"
run "$tmp/toolout.out" toolout.py "$tmp/proj" 2026-10-01
has "toolout.py prices tool output at the cache-read price and says it is an estimate" "$tmp/toolout.out" "estimated \$"
run "$tmp/first.out" first.py "$tmp/proj" 2026-10-01
ok "first.py still runs (a context-size check, no cost)"

# 3. An old tokens.json without by_model fails loudly, never silently priced.
python3 -I - "$tmp/tokens.json" "$tmp/old.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for a in d["agents"] + d["mains"]: a.pop("by_model", None)
json.dump(d, open(sys.argv[2], "w"))
PY
if python3 -I "$use/agg.py" "$tmp/old.json" >"$tmp/old.out" 2>&1; then bad "agg.py refuses a tokens.json without by_model" "exit 0"; else has "agg.py refuses a tokens.json without by_model" "$tmp/old.out" "run the current tokens.py again"; fi

# 4. No wording left that ranks by raw tokens. Returns 0 clean, 1 wording found, 2 a folder missing or grep failed
# (a missing folder must never read as clean).
check_no_raw_wording() { # check_no_raw_wording <agents dir> <usage dir>
  local d
  for d in "$1" "$2"; do [ -d "$d" ] || return 2; done
  grep -rniE "rank (and compare )?by raw tokens|raw tokens first" "$1" "$2" >"$tmp/grep.out" 2>/dev/null
  case $? in 0) return 1 ;; 1) return 0 ;; *) return 2 ;; esac
}
bash "$bin/../tests/test-board-content.sh" >"$tmp/board-content.out" 2>&1; st=$?
if [ "$st" -eq 0 ]; then ok "the live files pass test-board-content.sh (no ranking-by-raw-tokens wording in agents/ or bin/usage/)"; else bad "test-board-content.sh" "status $st: $(grep '^FAIL' "$tmp/board-content.out")"; fi
check_no_raw_wording "$tmp/no-such-agents" "$bin/usage"; st=$?
if [ "$st" -eq 2 ]; then ok "the raw-tokens check fails (status 2) when the agents folder is missing"; else bad "the raw-tokens check with a missing agents folder" "expected status 2, got $st"; fi

echo
if [ "$failures" -eq 0 ]; then echo "ALL PASSED"; exit 0; else echo "$failures FAILED"; exit 1; fi
