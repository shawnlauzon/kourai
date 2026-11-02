"""Time each card spends per list, from the board's card-move history (rules.md, the time optimizer).

Usage: python3 -I cardtimes.py <since-date> [--actions-file FILE] [--top N]

<since-date> is an ISO date: the cards that reached DONE on or after it are measured, over their
whole path in the history read (a stay that began before the history read is left out of the table and counted in a "Cut off" line).
Without --actions-file the script reads the board's moves from Trello (the key and token in
TRELLO_ENV_FILE, default paths.trello_env; TRELLO_API_BASE overrides
the API; the token is never printed). --actions-file reads a saved list of the same actions
(a JSON array of Trello `createCard` and `updateCard:idList` actions) instead, for tests.

Prints, by list: how many cards passed it, the median, the mean and the p90 hours a card spent
there (all its visits added), then each card's total from its first list to DONE, the cards
that went back (visits above 1 per list), and the N slowest cards with their per-list hours.
Hours in the user's lists (PROPOSED, BUG REPORTS, QUESTIONS, REVIEW, DONE) are reported on their
own lines and never added to the agents' time. Names and numbers only; writes nothing.
"""
import datetime as dt
import json
import os
import re
import statistics
import sys
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
sys.dont_write_bytecode = True
import kourai_config  # noqa: E402

_CFG = kourai_config.load()
BOARD = kourai_config.get(_CFG, "board.id")
# The user's lists (rules.md, The board). Trello stores a list's name as it was when a move happened, so moves
# from before the 2026-10-14 switch carry the old names: BRAINSTORM (now PROPOSED) and WAITING FOR CLARITY (now
# QUESTIONS); they are listed too, or the user's waiting would count as agent time.
USER_LISTS = ("PROPOSED", "BUG", "QUESTIONS", "REVIEW", "DONE", "BRAINSTORM", "WAITING")
END_LISTS = ("DONE",)
PAGE = 1000
MAX_PAGES = 30


def list_word(name):
    """A list's name word: lists carry emoji, so take the first run of capital letters."""
    m = re.search(r"[A-Z][A-Z]+", name or "")
    return m.group(0) if m else (name or "?")


def when(s):
    return dt.datetime.strptime(s[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=dt.timezone.utc)


def fetch(since):
    env_file = os.environ.get("TRELLO_ENV_FILE", kourai_config.get(_CFG, "paths.trello_env"))
    creds = {}
    with open(env_file) as f:
        for line in f:
            k, _, v = line.strip().partition("=")
            creds[k] = v.strip().strip('"').strip("'")
    api = os.environ.get("TRELLO_API_BASE", "https://api.trello.com/1")
    out, before = [], None
    for _ in range(MAX_PAGES):
        q = {"filter": "createCard,updateCard:idList", "limit": PAGE, "fields": "date,data,type",
             "key": creds["TRELLO_KEY"], "token": creds["TRELLO_TOKEN"]}
        if before:
            q["before"] = before
        with urllib.request.urlopen(f"{api}/boards/{BOARD}/actions?" + urllib.parse.urlencode(q), timeout=60) as r:
            page = json.load(r)
        out += page
        if len(page) < PAGE or page[-1]["date"][:10] < since:
            break
        before = page[-1]["id"]
    return out


def pct(vals, p):
    vals = sorted(vals)
    return vals[min(len(vals) - 1, int(round(p * (len(vals) - 1))))]


def main():
    a = sys.argv[1:]
    top = 10
    afile = None
    if "--top" in a:
        i = a.index("--top"); top = int(a[i + 1]); del a[i:i + 2]
    if "--actions-file" in a:
        i = a.index("--actions-file"); afile = a[i + 1]; del a[i:i + 2]
    if len(a) != 1 or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", a[0]):
        sys.exit(__doc__)
    since = a[0]
    acts = json.load(open(afile)) if afile else fetch(since)

    acts = sorted(acts, key=lambda x: x["date"])   # Trello returns newest first; the path logic needs oldest first
    cards = {}   # shortLink -> {"name", "events": [(time, list word)]}
    for x in acts:
        d = x.get("data", {})
        c = d.get("card", {})
        sl = c.get("shortLink")
        if not sl:
            continue
        rec = cards.setdefault(sl, {"name": c.get("name", "?"), "events": []})
        rec["name"] = c.get("name", rec["name"])
        t = when(x["date"])
        if x.get("type") == "createCard":
            rec["events"].append((t, list_word((d.get("list") or {}).get("name")), False))
        elif d.get("listAfter"):
            if not rec["events"]:   # the history starts mid-path: the first move says where the card was
                rec["events"].append((t - dt.timedelta(seconds=1), list_word((d.get("listBefore") or {}).get("name")), True))
            rec["events"].append((t, list_word(d["listAfter"].get("name")), False))

    per_list, cutoff, totals, done_cards = {}, {}, [], []
    for sl, rec in cards.items():
        ev = sorted(rec["events"])
        if not ev or ev[-1][1] not in END_LISTS:
            continue
        if ev[-1][0].date().isoformat() < since:
            continue
        hours, count = {}, {}
        for (t0, w, synth), (t1, _, _) in zip(ev, ev[1:]):
            if synth:   # the stay before the window's first move: its start is unknown, so it is not measured
                cutoff[w] = cutoff.get(w, 0) + 1
                continue
            hours[w] = hours.get(w, 0) + (t1 - t0).total_seconds() / 3600
            count[w] = count.get(w, 0) + 1
        for w, h in hours.items():
            per_list.setdefault(w, []).append(h)
        agent = sum(h for w, h in hours.items() if w not in USER_LISTS)
        user = sum(h for w, h in hours.items() if w in USER_LISTS and w not in END_LISTS)
        total = (ev[-1][0] - ev[0][0]).total_seconds() / 3600
        done_cards.append((total, sl, rec["name"], hours, agent, user, {w: n for w, n in count.items() if n > 1}))
        totals.append(total)

    if not done_cards:
        print(f"No card reached DONE on or after {since} in the history read.")
        return
    print(f"Cards finished since {since}: {len(done_cards)}")
    print("\nHours a card spent in each list (all visits added; user lists marked *):")
    print(f"{'list':<12}{'cards':>6}{'median':>9}{'mean':>9}{'p90':>9}")
    for w in sorted(per_list, key=lambda w: -sum(per_list[w])):
        if w in END_LISTS:
            continue
        v = per_list[w]
        print(f"{w + ('*' if w in USER_LISTS else ''):<12}{len(v):>6}{statistics.median(v):>9.1f}{statistics.mean(v):>9.1f}{pct(v, .9):>9.1f}")
    if cutoff:
        print("Cut off (entered before the history read; that stay is left out of the table): "
              + ", ".join(f"{w} {n}" for w, n in sorted(cutoff.items(), key=lambda p: -p[1])) + " cards")
    ag = [c[4] for c in done_cards]
    us = [c[5] for c in done_cards]
    print(f"\nAgents' lists per card:  median {statistics.median(ag):.1f} h, mean {statistics.mean(ag):.1f} h, p90 {pct(ag, .9):.1f} h")
    print(f"User's lists per card:   median {statistics.median(us):.1f} h, mean {statistics.mean(us):.1f} h, p90 {pct(us, .9):.1f} h (not counted above)")
    print(f"Whole path per card:     median {statistics.median(totals):.1f} h, mean {statistics.mean(totals):.1f} h, p90 {pct(totals, .9):.1f} h")
    back = [(c[2], c[1], c[6]) for c in done_cards if c[6]]
    print(f"\nCards that went back to a list ({len(back)} of {len(done_cards)}):")
    for name, sl, n in back[:top]:
        print(f"  {sl} {name[:70]}: " + ", ".join(f"{w} x{k}" for w, k in n.items()))
    print(f"\n{top} slowest cards on the agents' lists (hours per list):")
    for c in sorted(done_cards, key=lambda c: -c[4])[:top]:
        parts = ", ".join(f"{w} {h:.1f}" for w, h in sorted(c[3].items(), key=lambda p: -p[1]) if w not in USER_LISTS)
        print(f"  {c[4]:6.1f} h  {c[1]} {c[2][:60]}: {parts}")


main()
