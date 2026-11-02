#!/bin/bash
# Waits for the code-review skill's forked background agent that reviews one target
# path, and prints its result (the code reviewer's wait script, started by
# .claude/agents/code-reviewer.md; card "[AGENTS] An agent code-reviews every
# production code change; builders load the project skills"
# https://trello.com/c/nA1Tn2R1).
#
# The `code-review` skill (Skill tool) runs as a forked background agent and returns at
# once; its result reaches the caller later as a task notification. This script finds
# that fork on disk instead, so the reviewer can wait for it in one blocking call:
#   <projects dir>/<session>/subagents/agent-<id>.forked-skill.json  {"skillName":"code-review",...}
#   <projects dir>/<session>/subagents/agent-<id>.meta.json           {"finished":true} once done
#   <projects dir>/<session>/subagents/agent-<id>.jsonl               its first user line starts
#       "Review target: `<the skill's args, holding the target path as a word>`"; its last assistant text is the result.
#
# Usage: code-review-wait.sh <target path, absolute>
#   Takes the newest fork whose review target text holds <target> as a whole path word, then polls (10 seconds)
#   until it is finished or the wait limit (CODE_REVIEW_WAIT_LIMIT, default 270 seconds) ends.
# Prints one line first:
#   REVIEW: DONE <id> <transcript>      then the fork's final text      exit 0
#   REVIEW: RUNNING <id>                (call again at once)            exit 1
#   REVIEW: NOT STARTED <target>        no fork for it after the limit  exit 3
#   REVIEW: DEAD <id>: no transcript write for 20 minutes               exit 3
#   ERROR: <what>                                                       exit 2
# Reads only. Overrides (tests): CODE_REVIEW_PROJECT_DIR (default
# ~/.claude/projects/-Users-shawn-Development-github-runner-city), CODE_REVIEW_WAIT_LIMIT,
# CODE_REVIEW_POLL (seconds between polls, default 10), CODE_REVIEW_STALE (seconds, default 1200).
set -u -o pipefail

target=${1:-}
[ "$#" -eq 1 ] && [ -n "$target" ] || { echo "usage: code-review-wait.sh <target path>" >&2; exit 2; }
case "$target" in /*) ;; *) echo "ERROR: the target must be an absolute path: $target"; exit 2 ;; esac

exec python3 -I - "$target" <<'PY'
import glob, json, os, sys, time

target = sys.argv[1]
root = os.environ.get("CODE_REVIEW_PROJECT_DIR") or os.path.expanduser("~/.claude/projects/-Users-shawn-Development-github-runner-city")
limit = float(os.environ.get("CODE_REVIEW_WAIT_LIMIT", "270"))
poll = float(os.environ.get("CODE_REVIEW_POLL", "10"))
stale = float(os.environ.get("CODE_REVIEW_STALE", "1200"))
now = time.time
# The skill's first line reads "Review target: `<its args>`", and the args are words around the path
# ("medium the uncommitted diff in <wt>"). A run matches when the backticked text holds the target as a whole
# path token (not followed or preceded by a path character, so /wt/thre and /wt/three/sub do not match /wt/three).
import re
token = re.compile(r"(?<![\w./-])" + re.escape(target) + r"(?![\w./-])")
head = re.compile(r"Review target: `([^`]*)`")

def first_line_content(path):
    try:
        with open(path, encoding="utf-8") as f:
            o = json.loads(f.readline())
    except (OSError, ValueError):
        # A transcript that is not written yet or is cut mid-line is not a match yet; the next poll reads it again.
        return ""
    c = (o.get("message") or {}).get("content", "")
    if isinstance(c, list):
        c = " ".join(b.get("text", "") for b in c if isinstance(b, dict))
    return c if isinstance(c, str) else ""

def find():
    best = None
    for skill in glob.glob(os.path.join(root, "*", "subagents", "agent-*.forked-skill.json")):
        try:
            if json.load(open(skill)).get("skillName") != "code-review":
                continue
        except (OSError, ValueError):
            # Unreadable marker file: not a usable fork; ignore it.
            continue
        base = skill[: -len(".forked-skill.json")]
        jl = base + ".jsonl"
        if not os.path.exists(jl):
            continue
        m = head.match(first_line_content(jl))
        if not m or not token.search(m.group(1)):
            continue
        m = os.path.getmtime(skill)
        if best is None or m > best[0]:
            best = (m, base)
    return best

def final_text(jl):
    last = ""
    with open(jl, encoding="utf-8") as f:
        for line in f:
            try:
                o = json.loads(line)
            except ValueError:
                continue  # a half-written last line; the lines before it are whole
            if o.get("type") == "assistant":
                c = (o.get("message") or {}).get("content", [])
                t = "".join(b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text") if isinstance(c, list) else str(c)
                if t.strip():
                    last = t
    return last

deadline = now() + limit
while True:
    hit = find()
    if hit:
        base = hit[1]
        ident = os.path.basename(base)[len("agent-"):]
        jl = base + ".jsonl"
        try:
            finished = bool(json.load(open(base + ".meta.json")).get("finished"))
        except (OSError, ValueError):
            finished = False  # meta not written yet: still running
        if finished:
            print("REVIEW: DONE %s %s" % (ident, jl))
            print(final_text(jl))
            sys.exit(0)
        if now() - os.path.getmtime(jl) > stale:
            print("REVIEW: DEAD %s: no transcript write for 20 minutes" % ident)
            sys.exit(3)
        if now() >= deadline:
            print("REVIEW: RUNNING %s" % ident)
            sys.exit(1)
    elif now() >= deadline:
        print("REVIEW: NOT STARTED %s" % target)
        sys.exit(3)
    time.sleep(poll)
PY
