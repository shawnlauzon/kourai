"""Split each agent type's tokens by what each request did (the fixed vs per-run split).

Usage: python3 -I reqcat.py <projects dir> <since-date> <type[,type...]>

<projects dir> is the Claude Code projects folder of the repo (its */subagents/agent-*.jsonl
transcripts with their .meta.json are read); <since-date> is an ISO date (agents that started
before it are skipped); the types are agent types from .meta.json (agentType), comma-separated,
summed together.

Each request is classed by the tool call(s) it makes; a request with several classes is split
evenly between them. A request's cost is priced by its model and token types (cost.py); its tokens are its whole
context (input + cache read + cache write + output). Prints, per class: cost (rank by it), share,
tokens beside it, and requests per agent, then the price table line. "final text/no tool" is a
turn end, usually an agent waiting for a child's report or a background command.

The regexes in cls() name today's scripts (ui_test.sh, red_green.sh, heartbeat.sh,
agent-state.sh, test-server.sh, card-test-server.sh, board-wait.sh ...). When scripts are
renamed or added (the verdict-wait scripts, the card summary script), update them, or their
requests land in "bash other". Prints only class names and numbers, never transcript text.
"""
import collections
import glob
import json
import os
import re
import sys

import importlib.util

_s = importlib.util.spec_from_file_location("cost", os.path.join(os.path.dirname(os.path.abspath(__file__)), "cost.py"))
cost = importlib.util.module_from_spec(_s)
_s.loader.exec_module(cost)
unpriced = cost.Unpriced()

if len(sys.argv) != 4:
    sys.exit(__doc__)
ROOT, SINCE, TYPES = sys.argv[1], sys.argv[2], sys.argv[3].split(",")


def cls(name, inp):
    if name == "Bash":
        c = inp.get("command", "")
        if re.search(r"agent-state\.sh", c):
            return "ownership/state read"
        if re.search(r"ui_test|red_green|flutter (test|drive).*integration|rails test.*integration|tests/integration|run_api|api_test", c):
            return "run tests"
        if re.search(r"sleep|until |wait|tail|BashOutput|\.output|tasks/", c):
            return "wait/poll/log"
        if re.search(r"screenshot|png|imgur|upload|attach", c):
            return "screenshots"
        if re.search(r"gh |as-claude|git push|trello", c):
            return "github/trello bookkeeping"
        if re.search(r"test-server|card-test-server|adb|emulator|lock", c):
            return "server/emulator setup"
        if re.search(r"heartbeat", c):
            return "heartbeat/liveness"
        if re.search(r"^git|git -C|worktree", c):
            return "worktree work (git, builds, unit runs)"
        if re.search(r"^(cat|grep|ls|head|find|wc|rg)", c.strip()):
            return "read code/files"
        return "bash other"
    if name == "Read":
        p = inp.get("file_path", "")
        if p.endswith((".png", ".jpg")):
            return "screenshots"
        if p.endswith("rules.md") or "/.claude/" in p:
            return "read rules/agent docs"
        if "tasks/" in p or p.endswith((".output", ".log")) or "tool-results" in p:
            return "wait/poll/log"
        return "read code/files"
    if name in ("Write", "Edit", "NotebookEdit"):
        return "write/edit code and tests"
    if name in ("Grep", "Glob"):
        return "read code/files"
    if name.startswith("mcp__trello"):
        return "github/trello bookkeeping"
    if name in ("Monitor", "TaskOutput", "TaskStop"):
        return "wait/poll/log"
    if name == "ToolSearch":
        return "tool loading"
    if name in ("SendMessage", "SubagentHandback", "Agent"):
        return "report/start agents"
    return "other tool: " + name


tot, n, agents, T = collections.Counter(), collections.Counter(), 0, 0
usd, U = collections.Counter(), 0.0
for path in glob.glob(os.path.join(ROOT, "*", "subagents", "agent-*.jsonl")):
    meta = path[:-len(".jsonl")] + ".meta.json"
    if not os.path.exists(meta) or json.load(open(meta)).get("agentType") not in TYPES:
        continue
    reqs, order, start = {}, [], None
    with open(path) as f:
        for line in f:
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                # Partially written last line of a live transcript: nothing to count in it.
                continue
            start = start or e.get("timestamp")
            if e.get("type") != "assistant":
                continue
            m = e["message"]
            mid, u = m.get("id"), m.get("usage", {})
            if mid not in reqs:  # a response is split over several lines: count its usage once
                d, priced = cost.request_cost(m.get("model"), u)
                unpriced.note(cost.request_key(m.get("model"), u), priced)
                reqs[mid] = [cost.context(u) + u.get("output_tokens", 0), set(), d]
                order.append(mid)
            for b in m.get("content", []) if isinstance(m.get("content"), list) else []:
                if b.get("type") == "tool_use":
                    reqs[mid][1].add(cls(b["name"], b.get("input", {})))
    if (start or "") < SINCE or not reqs:
        continue
    agents += 1
    for mid in order:
        ctx, cs, d = reqs[mid]
        if not cs:
            cs = {"final text/no tool"}
        for x in cs:
            tot[x] += ctx / len(cs)
            n[x] += 1 / len(cs)
            usd[x] += d / len(cs)
        T += ctx
        U += d
print(f"{','.join(TYPES)}: agents {agents}, cost ${U:.0f}, tokens {T/1e6:.0f}M")
for k, v in usd.most_common():
    print(f"  {k:40}${v:8.2f} {100*v/max(U,1e-9):5.1f}%   tokens {tot[k]/1e6:7.1f}M   requests/agent {n[k]/max(agents,1):5.1f}")
print(cost.FOOTER)
print(unpriced.line())
