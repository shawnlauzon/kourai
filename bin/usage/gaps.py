"""Per agent type: gaps between requests, cache writes after long gaps (in tokens and in cost), first-request context size.

Usage: python3 -I gaps.py <projects dir> <since-ISO-date>

Rows are ranked by the cost of the cache writes that came after a gap of 5 minutes or more
(the cache had expired): cost.py prices each write at its request's model, 5-minute or 1-hour
write price. Tokens are shown beside it.
"""
import collections
import datetime
import glob
import importlib.util
import json
import os
import sys

_s = importlib.util.spec_from_file_location("cost", os.path.join(os.path.dirname(os.path.abspath(__file__)), "cost.py"))
cost = importlib.util.module_from_spec(_s)
_s.loader.exec_module(cost)
unpriced = cost.Unpriced()

ROOT, SINCE = sys.argv[1], sys.argv[2]


def ts(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))


stats = collections.defaultdict(lambda: collections.defaultdict(list))
for path in glob.glob(os.path.join(ROOT, "*", "subagents", "agent-*.jsonl")) + glob.glob(os.path.join(ROOT, "*.jsonl")):
    meta_path = path[:-len(".jsonl")] + ".meta.json"
    typ = json.load(open(meta_path)).get("agentType", "?") if os.path.exists(meta_path) else "main-session"
    reqs = {}
    with open(path) as f:
        for line in f:
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                # Partially written last line of a live transcript.
                continue
            m = e.get("message") or {}
            if e.get("type") == "assistant" and m.get("usage") and m.get("id") and m["id"] not in reqs:
                reqs[m["id"]] = (e["timestamp"], m["usage"], m.get("model"))
    seq = sorted(reqs.values(), key=lambda r: r[0])
    if not seq or seq[0][0] < SINCE:
        continue
    s = stats[typ]
    u0 = seq[0][1]
    s["first_ctx"].append(u0.get("cache_creation_input_tokens", 0) + u0.get("cache_read_input_tokens", 0) + u0.get("input_tokens", 0))
    s["models"].append(seq[0][2] if seq[0][2] is not None else cost.UNKNOWN_MODEL)
    last = seq[-1][1]
    s["last_ctx"].append(last.get("cache_creation_input_tokens", 0) + last.get("cache_read_input_tokens", 0) + last.get("input_tokens", 0))
    for (t0, _, _), (t1, u, mdl) in zip(seq, seq[1:]):
        gap = (ts(t1) - ts(t0)).total_seconds()
        w = u.get("cache_creation_input_tokens", 0)
        w1h = (u.get("cache_creation") or {}).get("ephemeral_1h_input_tokens", 0)
        s["gap"].append(gap)
        bucket = "<5m" if gap < 300 else ("5-60m" if gap < 3600 else ">60m")
        s["w_" + bucket].append(w)
        if gap >= 300:
            wk = cost.request_key(mdl, u)
            s["usd_late"].append(cost.usd(wk, {"cache_write_5m": w - w1h, "cache_write_1h": w1h}))
            unpriced.note(wk, cost.rates_for(wk)[1])
        s["w1h"].append(w1h)


def med(v):
    v = sorted(v)
    return v[len(v) // 2] if v else 0


print(f"{'type':20}{'n':>5}{'$ late write':>13}{'ctx@start':>10}{'ctx@end':>9}{'gaps<5m':>9}{'5-60m':>7}{'>60m':>6}{'Mw<5m':>8}{'Mw5-60m':>9}{'Mw>60m':>8}{'1h%':>5}  models")
for typ, s in sorted(stats.items(), key=lambda kv: -sum(kv[1]["usd_late"])):
    g = s["gap"]
    n5 = sum(1 for x in g if x < 300); n60 = sum(1 for x in g if 300 <= x < 3600); nl = len(g) - n5 - n60
    wall = sum(s["w_<5m"]) + sum(s["w_5-60m"]) + sum(s["w_>60m"])
    print(f"{typ:20}{len(s['first_ctx']):>5}{sum(s['usd_late']):>13.2f}{med(s['first_ctx'])//1000:>9}k{med(s['last_ctx'])//1000:>8}k{n5:>9}{n60:>7}{nl:>6}"
          f"{sum(s['w_<5m'])/1e6:>8.1f}{sum(s['w_5-60m'])/1e6:>9.1f}{sum(s['w_>60m'])/1e6:>8.1f}{100*sum(s['w1h'])/max(wall,1):>5.0f}  "
          f"{dict(collections.Counter(s['models']))}")
print(cost.FOOTER)
print(unpriced.line())
