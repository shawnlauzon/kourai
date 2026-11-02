"""Cost and tokens per agent and per hour, by model, for the main board roles.

Usage: python3 -I permodel.py <tokens.json> <since-date>

<tokens.json> is tokens.py's output; <since-date> is an ISO date (e.g. 2026-10-09):
only agents that started on or after it are counted. Prints one line per role and
model (price key of cost.py): agents, hours awake, then cost first ($ per agent and per hour,
each model's share priced with its own row), and raw tokens beside it (Mtok per agent and per
hour, cache writes per hour, output per agent, requests per agent). An agent on two models
counts once in each model's line; its hours are split by that model's share of the agent's
requests. A model priced at the fallback rate is marked "*".
"""
import collections
import datetime
import importlib.util
import json
import os
import sys

_s = importlib.util.spec_from_file_location("cost", os.path.join(os.path.dirname(os.path.abspath(__file__)), "cost.py"))
cost = importlib.util.module_from_spec(_s)
_s.loader.exec_module(cost)

if len(sys.argv) != 3:
    sys.exit(__doc__)
DATA, SINCE = sys.argv[1], sys.argv[2]
d = json.load(open(DATA))
unpriced = cost.Unpriced()


def ts(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))


for typ in ("board-watcher", "card-manager", "feature-tester", "server-builder", "mobile-builder", "test-builder",
            "merger", "promoter"):
    agg = collections.defaultdict(collections.Counter)
    for a in d["agents"]:
        if a["type"] != typ or not a["start"] or a["start"] < SINCE:
            continue
        if "by_model" not in a:
            sys.exit("permodel.py: tokens.json has no by_model; run the current tokens.py again")
        hours = (ts(a["end"]) - ts(a["start"])).total_seconds() / 3600
        for key, t in a["by_model"].items():
            priced = cost.rates_for(key)[1]
            unpriced.note(key, priced)
            c = agg[key + ("" if priced else "*")]
            c["n"] += 1
            c["hours"] += hours * t["requests"] / max(a["requests"], 1)
            c["usd"] += cost.usd(key, t)
            for k in cost.KINDS:
                c[k] += t[k]
            c["req"] += t["requests"]
    for key, c in sorted(agg.items(), key=lambda kv: -kv[1]["usd"]):
        tot = sum(c[k] for k in cost.KINDS)
        w = c["cache_write_5m"] + c["cache_write_1h"]
        h = max(c["hours"], .01)
        print(f"{typ:15} {key:27} n={c['n']:3} hours={c['hours']:6.1f} $/agent={c['usd']/c['n']:6.2f} $/hour={c['usd']/h:6.2f} "
              f"| Mtok/agent={tot/c['n']/1e6:5.1f} Mtok/hour={tot/h/1e6:5.1f} "
              f"write Mtok/hour={w/h/1e6:4.1f} out Ktok/agent={c['output']/c['n']/1e3:4.0f} req/agent={c['req']/c['n']:.0f}")
print("\n" + cost.FOOTER)
print(unpriced.line())
