"""Starting context per agent type: the fixed cost every request re-reads.

Usage: python3 -I first.py <projects dir> <since-date> [agents dir]

<projects dir> is the Claude Code projects folder of the repo (its */subagents/agent-*.jsonl
transcripts with their .meta.json are read); <since-date> is an ISO date (agents that started
before it are skipped). [agents dir], if given (e.g. <repo>/.claude/agents), is used to
subtract each type's agent file (current size / 3.5) from its start.

Prints per type: agents, the median and minimum first-request context, the median first
prompt, and, with [agents dir], the agent file's size and the base left (system prompt, tool
descriptions, CLAUDE.md and memory). Use it to check that tools: and omitClaudeMd took
effect: the base should drop from ~34k to ~15-20k. Prints numbers only.
"""
import collections
import glob
import json
import os
import statistics
import sys

if len(sys.argv) not in (3, 4):
    sys.exit(__doc__)
ROOT, SINCE = sys.argv[1], sys.argv[2]
AGENTS = sys.argv[3] if len(sys.argv) == 4 else None

r = collections.defaultdict(list)
for path in glob.glob(os.path.join(ROOT, "*", "subagents", "agent-*.jsonl")):
    meta = path[:-len(".jsonl")] + ".meta.json"
    typ = json.load(open(meta)).get("agentType", "?") if os.path.exists(meta) else "?"
    first, start, plen = None, None, None
    with open(path) as f:
        for line in f:
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                # Partially written last line of a live transcript: nothing to count in it.
                continue
            start = start or e.get("timestamp")
            if e.get("type") == "user" and plen is None:
                c = e["message"].get("content")
                plen = len(c) / 3.5 if isinstance(c, str) else 0
            if e.get("type") == "assistant":
                u = e["message"].get("usage", {})
                first = u.get("input_tokens", 0) + u.get("cache_read_input_tokens", 0) + u.get("cache_creation_input_tokens", 0)
                break
    if first and (start or "") >= SINCE:
        r[typ].append((first, plen or 0))

print(f"{'type':22}{'n':>5}{'first med k':>12}{'first min k':>12}{'prompt k':>9}" + (f"{'agent file k':>13}{'base k':>8}" if AGENTS else ""))
for t, v in sorted(r.items(), key=lambda kv: -len(kv[1])):
    med = statistics.median(x[0] for x in v) / 1e3
    line = f"{t:22}{len(v):>5}{med:>12.1f}{min(x[0] for x in v)/1e3:>12.1f}{statistics.median(x[1] for x in v)/1e3:>9.1f}"
    if AGENTS:
        md = os.path.join(AGENTS, t + ".md")
        mdk = os.path.getsize(md) / 3.5 / 1e3 if os.path.exists(md) else 0
        base = statistics.median(x[0] - x[1] for x in v) / 1e3 - mdk
        line += f"{mdk:>13.1f}{base:>8.1f}"
    print(line)
