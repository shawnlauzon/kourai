"""The time optimizer's measurements that cardtimes.py does not make (rules.md, the time optimizer).

Usage: python3 -I timereads.py occupancy <since-date> [--actions-file FILE]
       python3 -I timereads.py release <since-date> [--logs-dir DIR]
       python3 -I timereads.py ci-failures <owner/repo> <since-date>
       python3 -I timereads.py suite-steps <owner/repo> [<job name>] [<workflow name>]
       python3 -I timereads.py gap

occupancy   the card test servers against the TODO queue, from the board's card-move history (the same
            actions cardtimes.py reads): hour by hour since the date, how many cards sat in TESTING (each holds
            a test server; the board has 3) and in TODO; prints the mean and p90 of cards in TESTING, the mean
            of cards in TODO, and the hours in which every server was taken while TODO was not empty.
release     the release logs (default .claude/worktrees/release-logs in the main checkout): per release folder
            the first and last file times, the hours between them and the longest gaps between files.
ci-failures the failed runs since the date of the repo's workflows, with the failed jobs counted by job name
            (`gh run list`, `gh run view --json jobs`).
suite-steps the last 10 completed runs of the job (default `Integration Suite / Integration Suite`) in the workflow (default `CI`): the median
            and the longest minutes of each step.
gap         prints what has no machine-readable source: near-whole-suite AFTER runs against what they caught.
Names and numbers only; reads Trello (key in TRELLO_ENV_FILE) and GitHub (`gh`), writes nothing.
"""
import datetime as dt
import glob
import json
import os
import re
import statistics
import subprocess
import sys
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
sys.dont_write_bytecode = True
import kourai_config  # noqa: E402

_CFG = kourai_config.load()
BOARD = kourai_config.get(_CFG, "board.id")
SERVERS = kourai_config.get(_CFG, "limits.card_test_servers")


def when(s):
    return dt.datetime.strptime(s[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=dt.timezone.utc)


def word(name):
    m = re.search(r"[A-Z][A-Z]+", name or "")
    return m.group(0) if m else (name or "?")


def fetch(since):
    env = os.environ.get("TRELLO_ENV_FILE", kourai_config.get(_CFG, "paths.trello_env"))
    creds = {}
    for line in open(env):
        k, _, v = line.strip().partition("=")
        creds[k] = v.strip().strip('"').strip("'")
    api = os.environ.get("TRELLO_API_BASE", "https://api.trello.com/1")
    out, before = [], None
    for _ in range(30):
        q = {"filter": "createCard,updateCard:idList", "limit": 1000, "fields": "date,data,type",
             "key": creds["TRELLO_KEY"], "token": creds["TRELLO_TOKEN"]}
        if before:
            q["before"] = before
        with urllib.request.urlopen(f"{api}/boards/{BOARD}/actions?" + urllib.parse.urlencode(q), timeout=60) as r:
            page = json.load(r)
        out += page
        if len(page) < 1000 or page[-1]["date"][:10] < since:
            break
        before = page[-1]["id"]
    return out


def occupancy(a):
    afile = None
    if "--actions-file" in a:
        i = a.index("--actions-file"); afile = a[i + 1]; del a[i:i + 2]
    if len(a) != 1 or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", a[0]):
        sys.exit(__doc__)
    since = when(a[0] + "T00:00:00")
    acts = sorted(json.load(open(afile)) if afile else fetch(a[0]), key=lambda x: x["date"])
    where, moves = {}, []   # card -> list word; (time, card, list word)
    for x in acts:
        d = x.get("data", {}); sl = d.get("card", {}).get("shortLink")
        if not sl:
            continue
        if x.get("type") == "createCard":
            moves.append((when(x["date"]), sl, word((d.get("list") or {}).get("name"))))
        elif d.get("listAfter"):
            moves.append((when(x["date"]), sl, word(d["listAfter"].get("name"))))
    if not moves:
        print("NO MOVES in the history read."); return
    end = when(max(x["date"] for x in acts)); t = since; i = 0
    testing, todo, full = [], [], 0
    while t < end:
        while i < len(moves) and moves[i][0] <= t:
            where[moves[i][1]] = moves[i][2]; i += 1
        n_t = sum(1 for w in where.values() if w == "TESTING"); n_q = sum(1 for w in where.values() if w == "TODO")
        testing.append(n_t); todo.append(n_q)
        if n_t >= SERVERS and n_q > 0:
            full += 1
        t += dt.timedelta(hours=1)
    if not testing:
        print("NO HOURS between the date and the newest move."); return
    ts = sorted(testing)
    print(f"Hours measured since {a[0]}: {len(testing)}")
    print(f"Cards in TESTING (each holds a test server, of {SERVERS}): mean {statistics.mean(testing):.2f}, p90 {ts[min(len(ts) - 1, int(round(.9 * (len(ts) - 1))))]}")
    print(f"Cards in TODO: mean {statistics.mean(todo):.2f}")
    print(f"Hours with every server taken while TODO was not empty: {full} of {len(testing)}")


def release(a):
    logs = os.path.join(kourai_config.get(_CFG, "repos.0.path"), kourai_config.get(_CFG, "paths.worktree_root"), "release-logs")
    if "--logs-dir" in a:
        i = a.index("--logs-dir"); logs = a[i + 1]; del a[i:i + 2]
    if len(a) != 1 or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", a[0]):
        sys.exit(__doc__)
    cut = dt.datetime.fromisoformat(a[0]).timestamp()
    seen = False
    for d in sorted(glob.glob(os.path.join(logs, "*"))):
        files = sorted((os.path.getmtime(f), os.path.basename(f)) for f in glob.glob(os.path.join(d, "*")) if os.path.isfile(f))
        files = [f for f in files if f[0] >= cut]
        if len(files) < 2:
            continue
        seen = True
        gaps = sorted(((b[0] - p[0], b[1]) for p, b in zip(files, files[1:])), reverse=True)[:3]
        print(f"{os.path.basename(d)}: {(files[-1][0] - files[0][0]) / 3600:.2f} h from {files[0][1]} to {files[-1][1]}; longest gaps before: "
              + ", ".join(f"{n} {g / 60:.0f} min" for g, n in gaps))
    if not seen:
        print(f"NO RELEASE LOGS since {a[0]} in {logs}")


def gh(*args):
    r = subprocess.run(["gh", *args], capture_output=True, text=True)
    if r.returncode != 0:
        print(f"gh {' '.join(args[:2])} failed: {r.stderr.strip()[:200]}"); sys.exit(1)
    return json.loads(r.stdout)


def ci_failures(a):
    if len(a) != 2 or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", a[1]):
        sys.exit(__doc__)
    repo, since = a
    runs = gh("run", "list", "--repo", repo, "--status", "failure", "--json", "databaseId,name,createdAt", "--limit", "100")
    runs = [r for r in runs if r["createdAt"][:10] >= since]
    by_job, by_wf = {}, {}
    for r in runs:
        by_wf[r["name"]] = by_wf.get(r["name"], 0) + 1
        for j in gh("run", "view", str(r["databaseId"]), "--repo", repo, "--json", "jobs")["jobs"]:
            if j.get("conclusion") == "failure":
                by_job[j["name"]] = by_job.get(j["name"], 0) + 1
    print(f"Failed runs of {repo} since {since}: {len(runs)}")
    for n, c in sorted(by_wf.items(), key=lambda p: -p[1]):
        print(f"  workflow {n}: {c}")
    for n, c in sorted(by_job.items(), key=lambda p: -p[1]):
        print(f"  failed job {n}: {c}")


def suite_steps(a):
    if not 1 <= len(a) <= 3:
        sys.exit(__doc__)
    repo = a[0]; job = a[1] if len(a) > 1 else "Integration Suite / Integration Suite"; wf = a[2] if len(a) > 2 else "CI"
    runs = gh("run", "list", "--repo", repo, "--workflow", wf, "--status", "completed", "--json", "databaseId", "--limit", "10")
    steps = {}
    for r in runs:
        for j in gh("run", "view", str(r["databaseId"]), "--repo", repo, "--json", "jobs")["jobs"]:
            if j["name"] != job:
                continue
            for s in j.get("steps", []):
                if s.get("startedAt") and s.get("completedAt"):
                    steps.setdefault(s["name"], []).append((when(s["completedAt"]) - when(s["startedAt"])).total_seconds() / 60)
    if not steps:
        print(f"NO STEPS for job {job} in the last 10 completed {wf} runs of {repo}"); return
    print(f"Minutes per step of {job} ({wf}), last {len(runs)} completed runs:")
    for n, v in sorted(steps.items(), key=lambda p: -max(p[1])):
        print(f"  {n}: median {statistics.median(v):.1f}, longest {max(v):.1f} ({len(v)} runs)")


def gap():
    print("NO SOURCE: near-whole-suite AFTER runs against what they caught. The AFTER run's report names the tests it ran "
          "in words only; no file lists the run's size next to the failure it found. Say so in the check; do not estimate it.")


def main():
    a = sys.argv[1:]
    cmds = {"occupancy": occupancy, "release": release, "ci-failures": ci_failures, "suite-steps": suite_steps}
    if a and a[0] == "gap":
        gap()
    elif a and a[0] in cmds:
        cmds[a[0]](a[1:])
    else:
        sys.exit(__doc__)


main()
