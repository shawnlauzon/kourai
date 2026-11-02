"""Aggregate tokens.json: cost (model and token-type weighted) and raw tokens, per agent type, model, card and period.

Usage: python3 -I agg.py <tokens.json> [since-date]

<tokens.json> is tokens.py's output; [since-date] is an ISO date: only agents that
started (and main sessions that ended) on or after it are counted.

Cost is each model's share of an agent's tokens priced with that model's own row of cost.py
(five prices: input, 5-minute and 1-hour cache write, cache read, output; Haiku 5.5's
long-prompt tier by request). These are API list prices, the stated proxy for Max, whose weights
are unpublished. Rank and compare by cost; raw tokens are shown beside it, never the basis of a
recommendation.

Prints, in order:
1. Cost by agent type and model: cost, share, cost per agent, then raw tokens beside it
   (Mtok all kinds, requests, cache reads, cache writes, output). A model priced at the
   fallback rate is marked "*" and listed on the unpriced line at the end.
2. Cost by token kind.
3. Cost per card for the card's own agents (median, mean, p90, by agent type; the top cards).
4. Raw tokens per card for the same agents, secondary.
5. The price table's source, date and age, and the unpriced models.
"""
import collections
import importlib.util
import json
import os
import sys

_s = importlib.util.spec_from_file_location("cost", os.path.join(os.path.dirname(os.path.abspath(__file__)), "cost.py"))
cost = importlib.util.module_from_spec(_s)
_s.loader.exec_module(cost)

# Roles that serve every card: left out of the per-card tables.
SHARED = ("board-watcher", "merger", "promoter", "cani-agent", "workflow-builder", "workflow-verifier",
          "token-auditor", "time-optimizer", "fraud-watcher", "sentry-triager", "general-purpose", "Explore")
unpriced = cost.Unpriced()


def shares(a):
    """(price key, tokens by kind with requests, USD, priced) for each model the agent used."""
    if "by_model" not in a:
        sys.exit("agg.py: tokens.json has no by_model; run the current tokens.py again")
    out = []
    for key, t in a["by_model"].items():
        _, priced = cost.rates_for(key)
        unpriced.note(key, priced)
        out.append((key, t, cost.usd(key, t), priced))
    return out


data = json.load(open(sys.argv[1]))
since = sys.argv[2] if len(sys.argv) > 2 else ""
agents = [a for a in data["agents"] if (a["start"] or "") >= since]
mains = [a for a in data["mains"] if (a["end"] or "") >= since]

for a in agents + mains:
    a["shares"] = shares(a)
    a["cost"] = sum(x[2] for x in a["shares"])
    a["total"] = sum(a["tokens"].values())

print(f"agents since {since or 'ever'}: {len(agents)}; main sessions: {len(mains)}")

# 1. Cost by agent type and model, raw tokens beside it.
by_type = collections.defaultdict(collections.Counter)
priced_of = {}
for a in agents + mains:
    for key, t, usd, priced in a["shares"]:
        c = by_type[(a["type"], key)]
        priced_of[key] = priced
        c["n"] += 1  # agents that used this model (an agent on two models counts once in each row)
        c["cost"] += usd
        c["req"] += t["requests"]
        c["tok"] += sum(v for k, v in t.items() if k != "requests")
        for k in ("cache_read", "cache_write_5m", "cache_write_1h", "output"):
            c[k] += t[k]
tot = sum(c["cost"] for c in by_type.values()) or 1
grand = sum(c["tok"] for c in by_type.values())
print(f"\ncost by agent type and model (rank by cost; raw tokens beside it): ${tot:.0f}, raw {grand/1e9:.2f}B tokens")
print(f"{'type':22}{'model':28}{'n':>5}{'$':>9}{'%':>6}{'$/agent':>9}{'Mtok':>8}{'req/agent':>10}{'Mtok read':>10}{'Mtok write':>11}{'Ktok out':>9}")
for (ty, key), c in sorted(by_type.items(), key=lambda kv: -kv[1]["cost"]):
    mark = "" if priced_of[key] else "*"
    print(f"{ty:22}{key + mark:28}{c['n']:>5}{c['cost']:>9.0f}{100*c['cost']/tot:>6.1f}{c['cost']/c['n']:>9.2f}"
          f"{c['tok']/1e6:>8.0f}{c['req']/c['n']:>10.0f}{c['cache_read']/1e6:>10.1f}"
          f"{(c['cache_write_5m']+c['cache_write_1h'])/1e6:>11.1f}{c['output']/1e3:>9.0f}")
print(f"total ${tot:.0f}")

# 2. Cost split by token kind, each model's share at its own prices.
kinds = collections.Counter()
for a in agents + mains:
    for key, t, usd, priced in a["shares"]:
        rate = dict(zip(cost.KINDS, cost.rates_for(key)[0]))
        for k in ("cache_read", "cache_write_5m", "cache_write_1h", "output", "input"):
            kinds[k.replace("_", " ")] += t[k] * rate[k] / 1e6
print("\nby token kind:", {k: f"${v:.0f} ({100*v/tot:.0f}%)" for k, v in kinds.most_common()})

# 3. Cost per card, the card's own agents (shared roles left out).
cards = collections.defaultdict(collections.Counter)
for a in agents:
    if a["card"] and a["type"] not in SHARED:
        cards[a["card"]]["cost"] += a["cost"]
        cards[a["card"]][a["type"]] += a["cost"]
        cards[a["card"]]["agents"] += 1
vals = sorted(c["cost"] for c in cards.values())
if vals:
    print(f"\ncards: {len(vals)}  median ${vals[len(vals)//2]:.0f}  mean ${sum(vals)/len(vals):.0f}  p90 ${vals[int(len(vals)*.9)]:.0f}  max ${vals[-1]:.0f}")
    per_type = collections.Counter()
    for c in cards.values():
        for k, v in c.items():
            if k not in ("cost", "agents"):
                per_type[k] += v
    print("per-card cost by agent type (mean $/card):", {k: round(v / len(vals), 1) for k, v in per_type.most_common()})
    print("\ntop cards (by cost):")
    for cid, c in sorted(cards.items(), key=lambda kv: -kv[1]["cost"])[:12]:
        print(f"  {cid} ${c['cost']:.0f} agents={c['agents']}", {k: round(v) for k, v in c.items() if k not in ('cost', 'agents')})

# 4. Raw tokens per card, secondary: the same agents.
rawcard = collections.Counter()
for a in agents:
    if a["card"] and a["type"] not in SHARED:
        rawcard[a["card"]] += a["total"]
rv = sorted(rawcard.values())
if rv:
    print(f"\nraw tokens per card, secondary (own agents): cards {len(rv)}  median {rv[len(rv)//2]/1e6:.1f}M  "
          f"mean {sum(rv)/len(rv)/1e6:.1f}M  p90 {rv[int(len(rv)*.9)]/1e6:.1f}M")

# 5. The price table.
print("\n" + cost.FOOTER)
print(unpriced.line())
