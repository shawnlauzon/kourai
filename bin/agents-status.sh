#!/usr/bin/env bash
# What each live board agent is doing and how far along it is, for the user to
# watch from a second terminal tab or from Claude Code's status line.
#
# Usage:
#   agents-status.sh                 one table, then exit
#   agents-status.sh --watch [secs]  refresh the table every <secs> (default 5)
#   agents-status.sh --statusline    one line for a Claude Code status line
#
# Table, one row per live board agent (running, waiting, unknown, or the
# current board-watcher; reported and dead agents are left out):
#   ROLE  CARD  STEP  PROGRESS  LAST
#   STEP      "<n>/<total> <step>", the agent's place in its role's known
#             sequence of steps (the lists in STEPS below);
#   PROGRESS  a bar of that place; a second line under the row gives the test
#             counts of a UI run the agent started (from its results.txt);
#   LAST      seconds (or minutes) since the agent's transcript was last written,
#             and its last action: the tool and the first two words of a command.
# The status line: "<n> agents · <card> <step> <i>/<n> · …" (one entry per card,
# the card manager's, else the first agent's).
#
# Where it reads (all read-only; agents do nothing extra, so it costs no tokens):
#   - which agents are live, their role and card: agent-state.sh (transcripts);
#   - the step: the card's newest status comments, one Trello read per card, cached
#     for AGENTS_STATUS_TTL seconds (default 30) in AGENTS_STATUS_CACHE, plus the
#     agent's own last action;
#   - test counts: the results.txt of the newest `--logs <dir>` in the agent's
#     own tool calls (tool/ui_test_all.sh's folder).
# It never writes to Trello, GitHub or AWS, never prints a command's environment
# prefix, flags or later words, and never prints a secret or a file's content.
# A Trello read that fails leaves the step as "?" and says so on stderr.
#
# Exit 0; 2 usage; 1 when agent-state.sh fails.
# Overrides (tests): AGENT_STATE_SCRIPT (default: agent-state.sh beside this
# file), AGENT_TRANSCRIPTS_DIR and AGENT_STATE_NOW (passed on to it),
# AGENTS_STATUS_CACHE, AGENTS_STATUS_TTL, AGENTS_STATUS_NOW, TRELLO_ENV_FILE,
# TRELLO_API_BASE.
set -u -o pipefail
. "$(dirname "${BASH_SOURCE[0]}")/kourai-env.sh"

here=$(cd "$(dirname "$0")" && pwd)
mode=table watch_secs=5
case "${1:-}" in
  "") ;;
  --statusline) mode=statusline ;;
  --watch) mode=watch; watch_secs=${2:-5}
           [[ "$watch_secs" =~ ^[0-9]+$ ]] && [ "$watch_secs" -ge 1 ] || { echo "usage: agents-status.sh [--watch [seconds] | --statusline]" >&2; exit 2; } ;;
  -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
  *) echo "usage: agents-status.sh [--watch [seconds] | --statusline]" >&2; exit 2 ;;
esac

state_script=${AGENT_STATE_SCRIPT:-$here/agent-state.sh}
env_file=${TRELLO_ENV_FILE:-$(kc paths.trello_env)}
api=${TRELLO_API_BASE:-https://api.trello.com/1}
cache=${AGENTS_STATUS_CACHE:-$(kc paths.agents_status_cache)}
ttl=${AGENTS_STATUS_TTL:-30}
now=${AGENTS_STATUS_NOW:-$(date +%s)}

render() {
  local lines rc
  lines=$("$state_script") ; rc=$?
  [ "$rc" = 0 ] || { echo "agents-status: agent-state.sh failed (exit $rc)" >&2; return 1; }
  # Trello credentials are read into this process only for the card reads below.
  if [ -f "$env_file" ]; then
    set -a
    # shellcheck disable=SC1090 # the user's own env file
    . "$env_file"
    set +a
  fi
  printf '%s\n' "$lines" | python3 -I -c "$py" "$mode" "$now" "$cache" "$ttl" "$api" "${TRELLO_KEY:-}" "${TRELLO_TOKEN:-}" "$(kc board.members.agent)"
}

py='
import json, os, re, subprocess, sys, tempfile, time

mode, now, cache, ttl, api, key, token = sys.argv[1], float(sys.argv[2]), sys.argv[3], float(sys.argv[4]), sys.argv[5], sys.argv[6], sys.argv[7]
CLAUDE = sys.argv[8]   # the agent Trello account (board.members.agent)
ALIVE = {"current", "running", "waiting", "unknown"}

# Each role: its steps in order, then rules (regex, step number) tried in order
# against (a) the card comments text, newest first ("c"), (b) the agent last action ("a").
STEPS = {
 "card-manager": ["read card", "aspects", "BEFORE test", "builders", "function test (AFTER)", "review policy"],
 "feature-tester": ["setup", "BEFORE tests", "BEFORE run", "AFTER run", "report"],
 "mobile-builder": ["read card", "tests first", "code", "unit tests", "PR"],
 "server-builder": ["read card", "tests first", "code", "unit tests", "PR"],
 "test-builder": ["read card", "write tests", "run tests", "PR"],
 "workflow-builder": ["take card", "worktree", "build", "prove", "commit and PR", "send on"],
 "code-reviewer": ["read card", "worktree", "review", "verify findings", "post"],
 "merger": ["checks", "merge", "record"],
 "promoter": ["pin", "full test", "staging", "app builds", "smoke", "upload", "done"],
}
COMMENT_RULES = {  # newest status comment of the card -> step
 "card-manager": [(r"^(MERGE READY|REVIEW):", 6), (r"^TEST PASSED", 6), (r"^TEST FAILED", 4),
                  (r"^IN PROGRESS:.*(AFTER|function)", 5), (r"^PR:", 4), (r"^BEFORE:", 4),
                  (r"^IN PROGRESS:.*BEFORE", 3), (r"^IN PROGRESS", 2)],
 "feature-tester": [(r"^TEST (PASSED|FAILED)", 5), (r"^BEFORE:", 4), (r"^IN PROGRESS:.*AFTER", 4),
                    (r"^IN PROGRESS:.*BEFORE", 3)],
 "merger": [(r"^MERGED:", 3)],
 "promoter": [(r"^FULL SUITE GREEN", 3), (r"^STAGING (DEPLOYED|UNCHANGED)", 4), (r"^(ANDROID|IOS) BUILT", 5),
              (r"^SMOKE PASSED", 6), (r"^(ANDROID|IOS) UPLOADED", 7), (r"^PROMOTING", 2)],
}
ACTION_RULES = {  # the agent last action (tool and command words) -> step
 "card-manager": [(r"^Agent", 4), (r"gh pr|review-policy", 6)],
 "feature-tester": [(r"watch-results|ui_test_all|ui_test\.sh", None), (r"test-server\.sh|card-test-server", 1)],
 "mobile-builder": [(r"^(Edit|Write)", 3), (r"flutter test|flutter analyze", 4), (r"as-claude|gh api|git push|git -C \S+ push", 5)],
 "server-builder": [(r"^(Edit|Write)", 3), (r"rails test|run-locked|bundle exec", 4), (r"as-claude|gh api|git push|git -C \S+ push", 5)],
 "test-builder": [(r"^(Edit|Write)", 2), (r"ui_test|rails test|flutter test", 3), (r"as-claude|gh api|git push", 4)],
 "workflow-builder": [(r"worktree", 2), (r"^(Edit|Write)", 3), (r"bash -n|test-|grep ", 4),
                      (r"git -C \S+ commit|as-claude|git push", 5), (r"review-policy|pr-conflicts", 6)],
 "code-reviewer": [(r"worktree", 2), (r"code-review-wait|^Skill", 3), (r"as-claude|gh api", 5)],
 "merger": [(r"as-claude.* merge|gh pr merge", 2), (r"ci-wait|pr-ready|review-policy|pr-conflicts", 1)],
 "promoter": [(r"staging", 3), (r"ui_test_all|test-server|run-locked", 2)],
}

def short_action(tool, inp):
    # tool name plus the first two words of a command, minus VAR=value prefixes: a
    # command line can hold a token or a path, so nothing later is ever printed
    if tool == "Bash":
        cmd = str(inp.get("command", ""))
        if cmd.startswith("cd ") and "&&" in cmd:
            cmd = cmd.split("&&", 1)[1]
        words = cmd.split()
        while words and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0]):
            words.pop(0)
        words = [os.path.basename(w) if w.startswith("/") else w for w in words[:2]]
        return "Bash " + " ".join(words)
    return tool

def last_info(path):
    # the agent newest tool call (and the whole command, for rule matching only)
    # and the newest --logs folder in any of its commands, with the test count asked for
    action, full, logs, total = "-", "", None, None
    try:
        for line in open(path, errors="replace"):
            try:
                d = json.loads(line)
            except ValueError:
                continue
            c = (d.get("message") or {}).get("content")
            if d.get("type") != "assistant" or not isinstance(c, list):
                continue
            for b in c:
                if b.get("type") != "tool_use":
                    continue
                inp = b.get("input") or {}
                action, full = short_action(b.get("name", ""), inp), (b.get("name", "") + " " + str(inp.get("command", "")))
                m = re.search(r"--logs\s+(\S+)", str(inp.get("command", "")))
                if m and "ui_test_all" in str(inp.get("command", "")):
                    logs = m.group(1)
                    total = len(re.findall(r"\S+_ui_test\.dart\b", str(inp.get("command", "")))) or None
    except OSError:
        pass
    return action, full, logs, total

def card_comments(card):
    # one Trello read per card, cached for ttl seconds
    os.makedirs(cache, exist_ok=True)
    f = os.path.join(cache, card + ".json")
    if os.path.exists(f) and now - os.path.getmtime(f) <= ttl:
        try:
            return json.load(open(f))
        except ValueError:
            pass  # a half-written cache file: read Trello again
    if not key or not token:
        print("agents-status: no Trello credentials: step unknown for %s" % card, file=sys.stderr)
        return None
    url = "%s/cards/%s/actions?filter=commentCard&limit=15&fields=data,date,idMemberCreator&key=%s&token=%s" % (api, card, key, token)
    out = tempfile.NamedTemporaryFile(delete=False).name
    try:
        r = subprocess.run(["curl", "-sf", "--max-time", "8", "-o", out, url], capture_output=True)
        if r.returncode != 0:
            print("agents-status: Trello read failed for %s" % card, file=sys.stderr)
            return None
        data = json.load(open(out))
    except (OSError, ValueError):
        print("agents-status: Trello answer unreadable for %s" % card, file=sys.stderr)
        return None
    finally:
        os.unlink(out)
    texts = [a["data"]["text"] for a in sorted(data, key=lambda a: a["date"], reverse=True)
             if a.get("idMemberCreator") == CLAUDE and (a.get("data") or {}).get("text")]
    json.dump(texts, open(f, "w"))
    return texts

def results(logs):
    p = os.path.join(logs, "results.txt")
    try:
        ls = open(p, errors="replace").read().splitlines()
    except OSError:
        return None
    done = sum(1 for l in ls if re.match(r"^(PASS|FLAKY)\b", l))
    failed = sum(1 for l in ls if re.match(r"^FAIL\b", l))
    return done, failed, any(l.startswith("END ") for l in ls)

def age(s):
    return "%ds" % s if s < 120 else "%dm" % (s // 60)

rows = []
for line in sys.stdin.read().splitlines():
    m = re.match(r"^(\S+) (\S+) card=(\S+) id=(\S+) last=(\d+)s children=(\d+) (.*?)(\S+)$", line)
    if not m or m.group(1) not in ALIVE:
        continue
    state, role, card, aid, last, kids, detail, path = m.groups()
    rows.append({"state": state, "role": role, "card": card, "last": int(last), "path": path})

comments = {}
for r in rows:
    steps = STEPS.get(r["role"])
    action, full, logs, total = last_info(r["path"])
    r["action"], r["tests"], r["step"], r["n"] = action, None, 0, len(steps) if steps else 0
    if logs:
        res = results(logs)
        if res:
            r["tests"] = "tests %d%s passed%s%s" % (res[0], "/%d" % total if total else "", ", %d failed" % res[1] if res[1] else "", ", run ended" if res[2] else "")
    if not steps:
        continue
    step = 0
    if r["card"] != "-":
        if r["card"] not in comments:
            comments[r["card"]] = card_comments(r["card"])
        for t in comments[r["card"]] or []:
            for rx, n in COMMENT_RULES.get(r["role"], []):
                if re.search(rx, t, re.S):
                    step = n
                    break
            if step:
                break
    for rx, n in ACTION_RULES.get(r["role"], []):
        if re.search(rx, full):
            if n is None:   # a UI run in progress: the role UI-run step
                n = 3 if r["role"] == "feature-tester" and step < 4 else 4
            step = max(step, n) if r["role"] != "feature-tester" else n
            break
    r["step"] = step or 1
    if r["card"] != "-" and comments.get(r["card"]) is None:
        r["unsure"] = True   # the card comments could not be read: the step is a guess

def label(r):
    steps = STEPS.get(r["role"])
    if not steps:
        return "-"
    return "%d/%d %s%s" % (r["step"], r["n"], steps[r["step"] - 1], " ?" if r.get("unsure") else "")

def bar(r):
    if not r["n"]:
        return ""
    return "█" * r["step"] + "░" * (r["n"] - r["step"]) + " %d/%d" % (r["step"], r["n"])

if mode == "statusline":
    if not rows:
        print("0 agents")
        sys.exit(0)
    seen = {}
    for r in rows:
        c = r["card"]
        if c == "-":
            continue
        if c not in seen or r["role"] == "card-manager":
            seen[c] = r
    parts = ["%s %s %d/%d" % (c, STEPS[r["role"]][r["step"] - 1].split(" (")[0], r["step"], r["n"]) if r["n"] else "%s %s" % (c, r["role"])
             for c, r in seen.items()]
    print(" · ".join(["%d agent%s" % (len(rows), "" if len(rows) == 1 else "s")] + parts))
    sys.exit(0)

if not rows:
    print("No live board agents.")
    sys.exit(0)
print("%-17s %-9s %-33s %-14s %s" % ("ROLE", "CARD", "STEP", "PROGRESS", "LAST"))
for r in rows:
    print("%-17s %-9s %-33s %-14s %s" % (r["role"], r["card"], label(r), bar(r), "%s  %s" % (age(r["last"]), r["action"])))
    if r["tests"]:
        print("%-17s %s" % ("", r["tests"]))
'

case "$mode" in
  watch)
    # clear and redraw; ends with Ctrl-C
    while :; do
      out=$(render) || exit 1
      printf '\033[H\033[2J%s\n\n(refreshing every %ss; Ctrl-C ends)\n' "$out" "$watch_secs"
      sleep "$watch_secs"
    done ;;
  *) render ;;
esac
