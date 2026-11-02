"""Sum token usage per subagent transcript and attribute agents to Trello cards.

Usage: python3 -I tokens.py <projects dir> <out.json>

Per agent and main session it writes the totals by token kind ("tokens"), the request count
per model id ("models"), and the tokens by model and kind ("by_model": {price key: {input,
cache_write_5m, cache_write_1h, cache_read, output, requests}}). The price key is the model
id, or id + ">100k" for a request of a model with a long-prompt tier (cost.py), so a cost is
the sum of each key's share priced with its own row.
"""
import glob
import json
import os
import re
import sys

ROOT, OUT = sys.argv[1], sys.argv[2]
import importlib.util
_s = importlib.util.spec_from_file_location("cost", os.path.join(os.path.dirname(os.path.abspath(__file__)), "cost.py"))
cost = importlib.util.module_from_spec(_s)
_s.loader.exec_module(cost)
CARD_RE = re.compile(r"trello\.com/c/([A-Za-z0-9]{8})")


def first_text(content):
    if isinstance(content, str):
        return content
    return "\n".join(c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text")


def scan(path):
    msgs = {}  # message id -> (usage, model); a response is split over several lines
    first_prompt, start, end, tool_calls = None, None, None, {}
    with open(path) as f:
        for line in f:
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                # A partially written last line of a live transcript; nothing to count in it.
                continue
            ts = e.get("timestamp")
            if ts:
                start = start or ts
                end = ts
            m = e.get("message") or {}
            if first_prompt is None and e.get("type") == "user":
                first_prompt = first_text(m.get("content", ""))
            if e.get("type") == "assistant" and m.get("usage") and m.get("id"):
                prev = msgs.get(m["id"])
                if prev is None or m["usage"].get("output_tokens", 0) >= prev[0].get("output_tokens", 0):
                    msgs[m["id"]] = (m["usage"], m.get("model"))
                for c in m.get("content", []):
                    if isinstance(c, dict) and c.get("type") == "tool_use":
                        tool_calls[c["name"]] = tool_calls.get(c["name"], 0) + 1
    tot = {"input": 0, "cache_write_5m": 0, "cache_write_1h": 0, "cache_read": 0, "output": 0}
    models, by_model = {}, {}
    for u, model in msgs.values():
        key = str(cost.request_key(model, u))
        b = by_model.setdefault(key, {"input": 0, "cache_write_5m": 0, "cache_write_1h": 0,
                                      "cache_read": 0, "output": 0, "requests": 0})
        for k, v in cost.usage_tokens(u).items():
            b[k] += v
        b["requests"] += 1
        cc = u.get("cache_creation") or {}
        tot["input"] += u.get("input_tokens", 0)
        w1h = cc.get("ephemeral_1h_input_tokens", 0)
        tot["cache_write_1h"] += w1h
        tot["cache_write_5m"] += u.get("cache_creation_input_tokens", 0) - w1h
        tot["cache_read"] += u.get("cache_read_input_tokens", 0)
        tot["output"] += u.get("output_tokens", 0)
        mname = model if model is not None else cost.UNKNOWN_MODEL
        models[mname] = models.get(mname, 0) + 1
    return {"tokens": tot, "models": models, "by_model": by_model, "requests": len(msgs), "start": start, "end": end,
            "prompt": (first_prompt or "")[:600], "tools": tool_calls}


agents = []
for path in glob.glob(os.path.join(ROOT, "*", "subagents", "agent-*.jsonl")):
    meta_path = path[:-len(".jsonl")] + ".meta.json"
    meta = json.load(open(meta_path)) if os.path.exists(meta_path) else {}
    r = scan(path)
    r.update({"id": os.path.basename(path)[6:-6], "session": path.split("/")[-3],
              "type": meta.get("agentType", "?"), "desc": meta.get("description", ""),
              "parent": meta.get("parentAgentId")})
    cards = CARD_RE.findall(r["prompt"])
    r["card"] = cards[0] if cards else None
    agents.append(r)

mains = []
for path in glob.glob(os.path.join(ROOT, "*.jsonl")):
    r = scan(path)
    r.update({"id": "main", "session": os.path.basename(path)[:-6], "type": "main-session", "parent": None, "card": None})
    mains.append(r)

by_id = {a["id"]: a for a in agents}
for a in agents:
    p, seen = a, set()
    while a["card"] is None and p.get("parent") in by_id and p["parent"] not in seen:
        seen.add(p["parent"])
        p = by_id[p["parent"]]
        if p["type"] == "card-manager":
            a["card"] = p["card"]
json.dump({"agents": agents, "mains": mains}, open(OUT, "w"))
print(len(agents), "agents,", len(mains), "main sessions")
