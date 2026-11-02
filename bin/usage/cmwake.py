"""Tokens by what woke an agent: finds wake-ups for nothing and interim-notice cascades.

Usage: python3 -I cmwake.py <projects dir> <since-date> <type|main>

<projects dir> is the Claude Code projects folder of the repo; <since-date> is an ISO date
(transcripts that started before it are skipped). <type> is an agent type from .meta.json
(agentType; reads */subagents/agent-*.jsonl), or "main" for the top-level sessions (*.jsonl).

Every request is charged to the last thing that woke the agent:
- start: its first prompt;
- user/other: a typed message or another prompt (main sessions);
- message: a SendMessage from another agent or session;
- background command: one of its own background commands ended;
- child final report: a child agent finished and delivered its result;
- child interim notice: a child ended its turn with background work still running
  ("the result below may be interim"). These are the cascade: each costs the parent a wake
  at its full context. A healthy board has few.
Prints per trigger, ranked by cost (cost.py: model and token type weighted): wakes, requests,
cost, share, then tokens, cache writes and reads beside it, requests per wake; then the children that sent the most interim notices (by description, ids masked).
Never prints transcript text beyond those descriptions.
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
ROOT, SINCE, TYPE = sys.argv[1], sys.argv[2], sys.argv[3]

if TYPE == "main":
    paths = glob.glob(os.path.join(ROOT, "*.jsonl"))
else:
    paths = []
    for p in glob.glob(os.path.join(ROOT, "*", "subagents", "agent-*.jsonl")):
        meta = p[:-len(".jsonl")] + ".meta.json"
        if os.path.exists(meta) and json.load(open(meta)).get("agentType") == TYPE:
            paths.append(p)

tok, req, wakes, wr, rd, usd = (collections.Counter() for _ in range(6))
senders = collections.Counter()
for path in paths:
    trig, seen, start = "start", set(), None
    wakes["start"] += 1
    with open(path) as f:
        for line in f:
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                # Partially written last line of a live transcript: nothing to count in it.
                continue
            start = start or e.get("timestamp")
            if start and start < SINCE:
                break
            if e.get("type") == "user":
                m = e["message"].get("content")
                if isinstance(m, list) and any(isinstance(b, dict) and b.get("type") == "tool_result" for b in m):
                    continue
                t = m if isinstance(m, str) else " ".join(
                    b.get("text", "") for b in (m or []) if isinstance(b, dict) and b.get("type") == "text")
                t = t.strip()
                if not t or t.startswith(("<system-reminder", "<command", "<local-command")):
                    continue
                blocks = re.findall(r"<task-notification>.*?</task-notification>", t, re.S)
                if blocks:
                    kinds = []
                    for blk in blocks:
                        a = re.search(r'Agent "([^"]*)"', blk)
                        if not a:
                            kinds.append("background command")
                        elif "may be interim" in blk:
                            kinds.append("child interim notice")
                            senders[re.sub(r"[A-Za-z0-9]{8,}", "<id>", a.group(1))[:50]] += 1
                        else:
                            kinds.append("child final report")
                    trig = kinds[-1]
                    for k in kinds:
                        wakes[k] += 1
                elif "<agent-message" in t or "sent a message" in t[:200]:
                    trig = "message"
                    wakes[trig] += 1
                elif not seen:
                    trig = "start"  # the first prompt, already counted as the start wake
                else:
                    trig = "user/other"
                    wakes[trig] += 1
            elif e.get("type") == "assistant":
                m = e["message"]
                if m.get("id") in seen:  # a response is split over several lines: count its usage once
                    continue
                seen.add(m.get("id"))
                u = m.get("usage", {})
                tok[trig] += cost.context(u)
                d, priced = cost.request_cost(m.get("model"), u)
                unpriced.note(cost.request_key(m.get("model"), u), priced)
                usd[trig] += d
                req[trig] += 1
                wr[trig] += u.get("cache_creation_input_tokens", 0)
                rd[trig] += u.get("cache_read_input_tokens", 0)
    if start and start < SINCE:
        wakes["start"] -= 1

T = sum(usd.values()) or 1e-9
print(f"{TYPE}: cost ${sum(usd.values()):.0f}, tokens {sum(tok.values())/1e6:.0f}M since {SINCE}")
for k in sorted(usd, key=lambda k: -usd[k]):
    print(f"  {k:22} wakes {wakes[k]:5} requests {req[k]:5} cost ${usd[k]:8.2f} {100*usd[k]/T:4.0f}%  tokens {tok[k]/1e6:7.1f}M  "
          f"writes {wr[k]/1e6:6.1f}M reads {rd[k]/1e6:7.1f}M  requests/wake {req[k]/max(wakes[k],1):4.1f}")
if senders:
    print("  interim notices by child:")
    for s, c in senders.most_common(8):
        print(f"    {c:5}  {s}")
print(cost.FOOTER)
print(unpriced.line())
