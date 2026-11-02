#!/bin/bash
# What each board agent is really doing, read from the agents' own transcripts
# (.claude/board/WORKFLOW.md, "Lifetimes, handoffs and recovery"). The
# board-watcher runs it on its first pass and on every pass after, instead of
# trusting a heartbeat (agents write none since the switch to the new workflow;
# rules.md, Liveness comes from transcripts): when a board-watcher ends, the
# agents it started may die with it or outlive it (https://trello.com/c/VXYjRajE).
#
# Usage:
#   agent-state.sh [--all] [<filter>...]
#   agent-state.sh --token
#   agent-state.sh --owner <short link> <agent type> <token>
#
# --token prints `TOKEN: <32 hex digits>`, a fresh random token. --owner is the
# per-card guard (rules.md, "One owner per card"): an agent that owns a card (a
# card manager, a workflow builder) runs it with a token it got from --token, so
# the script finds the agent's own transcript (the one whose Bash call carries the
# token). The card is held by the oldest copy of that agent type on that card that
# is alive (current, running, waiting or unknown) and never delivered a report.
# Prints one line and exits:
#   0 `OWNER: <own id> holds <type> card <short link>` (plus a `NEWER: <id> <state>`
#     line per newer live copy, which stands down at its own check);
#   1 `STAND DOWN: <type> <id> (<state>, started <time>, last write <n>s ago) holds
#     card <short link>: <its transcript>`: touch nothing more and report;
#   2 `ERROR: <why>` (no transcript or several carry the token): touch nothing, report.
#
# Prints one line per board agent seen in the last AGENT_STATE_HOURS hours
# (default 24), newest agent per (type, card) only unless --all:
#   <state> <agent type> card=<short link or -> id=<agent id> last=<seconds since
#   its last transcript write>s children=<live child agents> reqs=<requests so far>
#   ctx=<tokens in its latest request> <detail> <transcript>
# card= is the card an agent was started for (card manager, builders, test builder,
# feature tester, workflow builder, workflow verifier: the first card link in its prompt;
# the main session starts one workflow builder per card, rules.md "Fresh context per task";
# a verifier reading other cards' plans and PRs for overlap still counts as working on the
# card it was started for). For the other roles (merger, promoter, and a workflow builder
# or verifier whose prompt names no card: the weekly drift check) it is the card of the agent's newest Trello call or card-summary.sh call (a
# card link, or a card id that an earlier Trello answer in its transcript mapped to its
# short link); - until it touches one.
# cards= (only for an agent with more than one card) lists every card it works on: a
# workflow builder given a batch of related cards for one PR names them on a line of its
# prompt that starts "Cards:" (run-board.md), and card= is the first of them.
# ctx= is the context size of the agent's latest request (input plus cached tokens;
# the board watcher hands off a card manager or promoter past the ceiling).
# A <filter> keeps only lines whose card short link (card= or any of cards=) or agent
# type equals it.
#
# States, from the transcript only (never from a heartbeat):
#   current   the board-watcher that started newest (there is only ever one; after
#             its HANDOFF: report its detail says handed_off_at_<time>: restart it);
#   handed-off  an earlier board-watcher that wrote its HANDOFF: report. Its
#             children's reports still wake it, and it may only relay them to the
#             main session (SendMessage); it is never a second watcher. Any other
#             tool call it made after the handoff is named in its detail
#             (acted_after_handoff:<tool>x<n>,...), and board-wait.sh prints
#             OLD WATCHER ACTED: for it;
#   reported  it called SubagentHandback: it ended and its report was delivered;
#   dead      it was interrupted ("[Request interrupted") and its own marker is its
#             last write, with no tool call open and no background command running
#             (dead at once; a write after the marker, a resume, keeps it alive),
#             or an agent above it
#             was interrupted and it wrote nothing after that (it died with its
#             parent: stopping an agent stops every agent it started),
#             AND it has no tool call open AND its transcript has been quiet for
#             more than AGENT_STATE_QUIET seconds (default 900); detail names why.
#             An agent above it that ended any other way (it reported, handed off,
#             died on an API error, or a newer board-watcher started) leaves it
#             running: its children's reports wake it (2026-10-17: a handed-off
#             watcher's card managers were taken for dead and started twice,
#             https://trello.com/c/Vfym22hq). Never dead while a child agent of
#             its own is live: then it is unknown;
#   unknown   the same signs of an end as dead, but it has a tool call open or
#             wrote within AGENT_STATE_QUIET seconds: it may well be alive (aspect
#             agents outlive their card manager, and a promoter in a long command
#             writes nothing for minutes; https://trello.com/c/YZYVBwC9). Never
#             treat it as dead: look again later;
#   running   a tool call of its own is still open (a command, a test run);
#   waiting   its turn ended and nothing above it ended: it waits for its child
#             agents or a background command (children= says how many are live),
#             or it ended without SubagentHandback (look at its report).
# A background command it started (run_in_background) with no task notification
# for it yet keeps it alive whatever else the transcript says: Claude Code
# resumes the agent when that command ends, even after its turn ended, it was
# interrupted, or a newer board-watcher started (2026-10-12: board-watcher
# a7fa6a6 showed "completed", a new watcher started, and a7fa6a6 came back when
# its board-wait.sh ended and ran beside it). Its line is then running or
# waiting, never dead or unknown, and its detail names the background tasks.
# A background command started more than AGENT_STATE_BG_MAX seconds ago (default
# 14400, 4 hours: longer than any board command) with no notification is taken
# to be gone (its agent was stopped without one).
# A background command is also checked live: Claude Code writes its output to the
# file its start names ("Output is being written to: <file>"), and the command's
# processes hold that file open while it runs. A command whose file no process
# holds (lsof) and that was not written within AGENT_STATE_GRACE seconds is gone,
# notice or not (2026-10-17: a stopped merger showed "waiting" on six background
# commands that no longer existed, and no new merger started). A command whose
# start names no file, or when lsof cannot run, counts as running as before.
# An agent that kept writing more than AGENT_STATE_GRACE seconds (default 120)
# after an agent above it was interrupted is not dead: its detail says "outlived <id>".
# An agent that died on an API error is dead once AGENT_STATE_GRACE seconds have passed with
# no tool call open (sooner it is "unknown": Claude Code retries a dropped response within
# seconds, https://trello.com/c/TuxG4qvA), whatever the quiet time:
# its transcript's last entry is the synthetic assistant message Claude Code
# writes when the request failed ("Autocompact is thrashing: the context
# refilled to the limit ...", "API Error: ...", "Prompt is too long", "Credit
# balance is too low", a request or overloaded error). It ended with no report,
# so it used to show "waiting" for hours and nobody restarted it (two promoters
# on 2026-10-16: https://trello.com/c/TuxG4qvA). Any later write of it (a resume
# by SendMessage) clears the error. A background command of its own that is
# still running keeps it alive as above.
# A usage limit ("You've hit your weekly limit · resets Oct 19 at 7am (America/Chicago)") is such
# an error; the dead row's detail then also carries `limit_reset=<the text after "resets", spaces
# as underscores>` (for example `limit_reset=Oct_19_at_7am_(America/Chicago)`), which board-wait.py
# reads to print RESUME: once the limit is over.
# An agent whose turn ended with no report, no open tool call, no live child
# agent and no running background command, and that wrote nothing for more than
# AGENT_STATE_STALE seconds (default 1200, 20 minutes), is dead too: nothing
# can wake it. Its detail says "no write for <n> minutes".
# An agent whose foreground tool call (not a call to a child agent, Monitor, AskUserQuestion or
# ExitPlanMode) has been open for more than AGENT_STATE_TOOL_MAX seconds (default 3600: one Bash
# call ends within 600 seconds, but parallel calls run one after another, so the last of five can
# stay open for 15 minutes or more while the agent is alive) AND whose transcript has been quiet for
# more than AGENT_STATE_QUIET seconds, and that has no running background command, is dead too: it
# was orphaned and the call will never return (without this it stayed "running" until the 24-hour
# window, and its card had no owner to start; https://trello.com/c/u7rEBbGc). A recent write
# (a result of a queued call) keeps it alive. No process can be asked about a foreground call
# (it has no output file), so the quiet time is the check. Its detail says "tool_call_open_for_<n>_minutes".
# An agent is confirmed dead only when its transcript and its children both say
# so: its line says dead and children=0 (.claude/board/rules.md, "Liveness comes
# from transcripts"). `reported` needs nothing more.
#
# One agent can have transcripts in several session folders (a resumed or restarted session keeps
# writing it in the new folder): all of them are read as one, so a
# report delivered in a later folder makes it `reported`, whatever its leftover background tasks say.
# A later folder can hold a meta file of its own that names another agent type
# ("general-purpose"); the meta file that names a board agent type counts.
#
# Without --all, it prints the newest agent per (type, card), plus every older
# one of the same type and card that may be alive (running, waiting or unknown), so a second
# copy (two promoters, two card managers on one card) is never hidden.
#
# Overrides (tests): AGENT_TRANSCRIPTS_DIR (default: project.transcripts_dir of the config),
# AGENT_STATE_CACHE (the folder of the per-agent transcript cache, default
# paths.agent_state_cache of the config; empty turns it off; off when
# AGENT_TRANSCRIPTS_DIR is set without it), AGENT_STATE_DEBUG_BYTES (prints the bytes parsed to stderr),
# AGENT_STATE_NOW (epoch seconds), AGENT_STATE_HOURS, AGENT_STATE_GRACE,
# AGENT_STATE_QUIET, AGENT_STATE_BG_MAX, AGENT_STATE_STALE, AGENT_STATE_TOOL_MAX, AGENT_STATE_LSOF (the
# lsof command).
set -u
. "$(dirname "${BASH_SOURCE[0]}")/kourai-env.sh"

all=0
filters=()
owner_card="" owner_type="" owner_token=""
while [ $# -gt 0 ]; do
  case "$1" in
    --all) all=1 ;;
    --token)
      exec python3 -I -c 'import secrets; print("TOKEN: " + secrets.token_hex(16))' ;;
    --owner)
      if [ $# -lt 4 ]; then echo "ERROR: usage: agent-state.sh --owner <short link> <agent type> <token>"; exit 2; fi
      owner_card=$2 owner_type=$3 owner_token=$4
      shift 3 ;;
    -h|--help) awk 'NR > 1 && /^#/ {print; next} NR > 1 {exit}' "$0"; exit 0 ;;
    -*) echo "agent-state.sh: unknown option '$1'" >&2; exit 2 ;;
    *) filters+=("$1") ;;
  esac
  shift
done
if [ -n "$owner_token" ] && [ ${#owner_token} -lt 16 ]; then
  echo "ERROR: the token must be the one agent-state.sh --token printed (32 hex digits)"; exit 2
fi

dir=${AGENT_TRANSCRIPTS_DIR:-$(kc project.transcripts_dir)}
# The agent roles (config): the board agents are the plugin's and the project's; the card and floating roles are liveness.*.
# A plugin agent's transcript names its type "kourai:<role>"; the prefix is dropped, so both forms count.
AGENT_STATE_ROLES_BOARD=$(printf '%s\n%s\n' "$(kc agents.plugin)" "$(kc agents.project)" | tr '\n' ' ')
AGENT_STATE_ROLES_CARD=$(kc liveness.card_roles | tr '\n' ' ')
AGENT_STATE_ROLES_FLOATING=$(kc liveness.floating_roles | tr '\n' ' ')
export AGENT_STATE_ROLES_BOARD AGENT_STATE_ROLES_CARD AGENT_STATE_ROLES_FLOATING
[ -d "$dir" ] || { echo "agent-state.sh: no transcript folder $dir" >&2; exit 1; }

py='
import json, os, re, sys, glob, datetime, subprocess

root, now, hours, grace, quiet, bg_max, stale, show_all = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5]), float(sys.argv[6]), float(sys.argv[7]), sys.argv[8] == "1"
lsof_cmd, owner_card, owner_type, owner_token = sys.argv[9], sys.argv[10], sys.argv[11], sys.argv[12]
filters = set(sys.argv[13:])
BOARD = set(os.environ["AGENT_STATE_ROLES_BOARD"].split())
CARD_AGENTS = set(os.environ["AGENT_STATE_ROLES_CARD"].split())


def bare(t):
    """The type of a plugin agent is kourai:<role>; the role is what the rest of the file uses."""
    return (t or "").split(":", 1)[-1]

# roles whose card is the first card link in their prompt
PROMPT_CARD = CARD_AGENTS | {"workflow-builder", "workflow-verifier"}
CARD = re.compile(r"trello\.com/c/([A-Za-z0-9]{8})")
CARDS_LINE = re.compile(r"^Cards:(.*)$", re.M)
# roles that are not started for one card (or a workflow builder whose prompt names
# none): their card is the one they touched last
FLOATING = set(os.environ["AGENT_STATE_ROLES_FLOATING"].split())
CARD_CMD = re.compile(r"(?:trello\.com/c/|card-summary\.sh\s+|pr-ready\.sh\s+)([A-Za-z0-9]{8})\b")
CARD_ID = re.compile(r"card/workspace/[0-9a-f]+/([0-9a-f]{24})")
TASK_DONE = re.compile(r"<task-id>([A-Za-z0-9_-]+)</task-id>")
# where Claude Code writes the output of a background command (its start result names the file)
BG_OUTPUT = re.compile(r"Output is being written to: (\S+?\.output)\b")
# the text of the synthetic message Claude Code writes when a request failed
API_ERROR = re.compile(r"^(Autocompact is thrashing|API Error|Prompt is too long|Credit balance is too low|"
                       r"Request timed out|Overloaded|Invalid API key|Context (limit|window)|"
                       r"The conversation (is|has) too long|Claude usage limit)", re.I)
# the usage-limit message of Claude Code; the group is the reset time as written
LIMIT_RESET = re.compile(r"hit your .{0,40}?limit\b.*?\bresets\s+(.+?)\s*$", re.I | re.S)
# the only tools a handed-off board-watcher may use: relaying a report to the main session
RELAY_TOOLS = {"SendMessage", "ToolSearch", "SubagentHandback"}

def ts(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()

def text_of(body):
    if isinstance(body, str):
        return body
    return " ".join(str(x.get("text", "")) for x in (body or []) if isinstance(x, dict))

def feed(a, line):
    try:
        d = json.loads(line)
    except ValueError:
        return  # the agent is writing this line right now
    t = d.get("timestamp")
    if t:
        t = ts(t)
        a["start"] = a["start"] if a["start"] is not None else t
        a["last"] = t
    msg = d.get("message") or {}
    content = msg.get("content")
    if d.get("type") in ("user", "assistant") and a["interrupted"] is not None:
        # an entry after the interrupt marker that is not itself a marker (Claude Code writes the
        # marker more than once) is the agent being resumed (SendMessage, a new user message)
        marks = [content] if isinstance(content, str) else [c.get("text", "") for c in (content or []) if isinstance(c, dict) and c.get("type") == "text"]
        if not (marks and all(str(m).startswith("[Request interrupted") for m in marks)):
            a["wrote_after"] = False if False else True
    if d.get("type") in ("user", "assistant"):
        err = None
        lim = None
        if d.get("type") == "assistant" and (d.get("isApiErrorMessage") or msg.get("model") == "<synthetic>"):
            text = " ".join(str(c.get("text", "")) for c in (content or []) if isinstance(c, dict) and c.get("type") == "text") \
                if isinstance(content, list) else str(content or "")
            if d.get("isApiErrorMessage") or API_ERROR.match(text.strip()):
                err = text.strip()[:80]
                # a usage limit (the message reads: hit your weekly limit, resets Oct 19 at 7am (America/Chicago)): keep
                # the text after "resets" whole; board-wait.py reads it as limit_reset= (RESUME:)
                m = LIMIT_RESET.search(text.strip())
                lim = m.group(1) if m else None
        a["api_error"] = err  # only the last user or assistant entry counts
        a["limit_reset"] = lim
    if d.get("type") == "attachment":
        # a notice that arrived while the agent was busy is queued and written as an
        # attachment, not a user entry (2026-10-17: a finished background command of a
        # workflow builder still showed "still running" after its notice)
        att = d.get("attachment") or {}
        if isinstance(att, dict):
            a["bg_done"].update(TASK_DONE.findall(str(att.get("prompt") or "")))
    if d.get("type") == "user":
        tur = d.get("toolUseResult")
        if isinstance(tur, dict) and tur.get("backgroundTaskId"):
            a["bg"][tur["backgroundTaskId"]] = t
            for c in (content if isinstance(content, list) else []):
                if isinstance(c, dict) and c.get("type") == "tool_result":
                    m = BG_OUTPUT.search(text_of(c.get("content")))
                    if m:
                        a["bg_path"][tur["backgroundTaskId"]] = m.group(1)
        texts = [content] if isinstance(content, str) else [
            str(c.get("text", "")) for c in (content or []) if isinstance(c, dict) and c.get("type") == "text"]
        for x in texts:
            a["bg_done"].update(TASK_DONE.findall(x))
        if a["card"] == "-" and a["type"] in PROMPT_CARD and isinstance(content, str):
            m = CARD.search(content)
            if m:
                a["card"] = m.group(1)
                a["card_from"] = "prompt"
                a["cards"] = [m.group(1)]
            # a workflow builder given a batch of related cards: every card on the
            # Cards: line of the prompt is its (run-board.md, WORKFLOW WORK:)
            cl = CARDS_LINE.search(content) if a["type"] == "workflow-builder" else None
            if cl and CARD.search(cl.group(1)):
                a["cards"] = list(dict.fromkeys(CARD.findall(cl.group(1))))
                a["card"] = a["cards"][0]
        if isinstance(content, list):
            for c in content:
                if c.get("type") == "tool_result":
                    a["open_tools"].discard(c.get("tool_use_id"))
                    a["open_at"].pop(c.get("tool_use_id"), None)
                    if a["type"] in FLOATING:
                        body = text_of(c.get("content"))
                        # a Trello answer names a card by id and by link: remember both
                        for card_text in re.split(r"(?=\"id\":\"ari:cloud:trello::card/)", body)[1:]:
                            i, sl = CARD_ID.search(card_text), CARD.search(card_text)
                            if i and sl:
                                a["idmap"][i.group(1)] = sl.group(1)
                elif c.get("type") == "text" and str(c.get("text", "")).startswith("[Request interrupted"):
                    a["interrupted"] = t
                    a["wrote_after"] = False
        elif isinstance(content, str) and content.startswith("[Request interrupted"):
            a["interrupted"] = t
            a["wrote_after"] = False
    elif d.get("type") == "assistant" and isinstance(content, list):
        usage = msg.get("usage")
        if isinstance(usage, dict):
            mid = msg.get("id") or "n%d" % len(a["reqids"])
            a["reqids"].add(mid)
            a["ctx"] = sum(int(usage.get(k) or 0) for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
        for c in content:
            if c.get("type") == "tool_use":
                a["open_tools"].add(c.get("id"))
                a["open_at"][c.get("id")] = (t, c.get("name"))
                inp = c.get("input") or {}
                if a["handoff"] is not None and c.get("name") not in RELAY_TOOLS:
                    a["after_handoff"][c.get("name")] = a["after_handoff"].get(c.get("name"), 0) + 1
                if c.get("name") == "Bash":
                    # the owner check (--owner) depends on the call, so only the hex runs are kept (cached);
                    # has_token is worked out on every call from them
                    a["bash_tokens"].update(HEXRUN.findall(str(inp.get("command", ""))))
                if a["type"] in FLOATING:
                    ref = str(inp.get("cardIdOrUrl") or inp.get("cardId") or "")
                    m = CARD_CMD.search(ref) or (CARD_CMD.search(str(inp.get("command", ""))) if c.get("name") == "Bash" else None)
                    if m:
                        a["refs"].append(m.group(1))
                    elif CARD_ID.search(ref):
                        a["refs"].append("id:" + CARD_ID.search(ref).group(1))
                if c.get("name") == "SubagentHandback":
                    a["handback"] = t
                    a["reported_ever"] = True
                    if a["type"] == "board-watcher" and a["handoff"] is None \
                            and str(inp.get("message", "")).lstrip().startswith("HANDOFF:"):
                        a["handoff"] = t

HEXRUN = re.compile(r"[0-9a-f]{16,}")
import hashlib, pickle, atexit
cache_dir = os.environ.get("AGENT_STATE_CACHE")
if cache_dir is None and not os.environ.get("AGENT_TRANSCRIPTS_DIR"):
    cache_dir = os.environ["AGENT_STATE_CACHE_DEFAULT"]
# the cache is valid only for the script text that wrote it (a changed script may add keys or change what is stored)
SRC_VER = os.environ.get("AGENT_STATE_SRC_VER", "")
debug_bytes = bool(os.environ.get("AGENT_STATE_DEBUG_BYTES"))
parsed_bytes = 0
if debug_bytes:
    atexit.register(lambda: print("agent-state.sh: parsed %d bytes" % parsed_bytes, file=sys.stderr))

def first_hash(path):
    with open(path, "rb") as f:
        return hashlib.sha1(f.read(256)).hexdigest()

def feed_all(a, data):
    global parsed_bytes
    parsed_bytes += len(data)
    for ln in data.decode("utf-8", errors="replace").split("\n"):
        feed(a, ln)

def parse_agent(a, files):
    """Fill `a` from the agent transcripts. One file: the state after its complete lines is cached
    (offset, size, hash of the first 256 bytes) and the next call reads only the appended bytes."""
    global parsed_bytes
    if len(files) != 1 or not cache_dir:
        for f in files:
            with open(f, "rb") as fh:
                feed_all(a, fh.read())
        return
    path = files[0]
    cpath = os.path.join(cache_dir, a["id"] + ".pickle")
    fresh = {k: (set() if isinstance(v, set) else v) for k, v in a.items()}
    offset = 0
    try:
        size = os.path.getsize(path)
        fh0 = first_hash(path)
        with open(cpath, "rb") as cf:
            c = pickle.load(cf)
        if c["ver"] == SRC_VER and c["path"] == path and c["hash"] == fh0 and c["offset"] <= size:
            a.clear(); a.update(c["a"]); offset = c["offset"]
    except FileNotFoundError:
        pass
    except Exception as e:  # unreadable or corrupt cache (or a vanished transcript): a miss, full parse
        print("agent-state.sh: cache %s unusable (%s): full parse" % (cpath, e), file=sys.stderr)
        a.clear(); a.update(fresh)
    with open(path, "rb") as fh:
        fh.seek(offset)
        data = fh.read()
    cut = data.rfind(b"\n") + 1
    complete, tail = data[:cut], data[cut:]
    feed_all(a, complete)
    try:
        os.makedirs(cache_dir, exist_ok=True)
        tmp = "%s.%d.tmp" % (cpath, os.getpid())
        with open(tmp, "wb") as cf:
            pickle.dump({"ver": SRC_VER, "path": path, "hash": first_hash(path), "offset": offset + cut, "a": a}, cf)
        os.replace(tmp, cpath)
    except OSError as e:  # a cache that cannot be written only costs the next call a full parse
        print("agent-state.sh: cannot write cache %s (%s)" % (cpath, e), file=sys.stderr)
    if tail:
        feed_all(a, tail)

metas = {}
for meta_path in glob.glob(os.path.join(root, "*", "subagents", "agent-*.meta.json")):
    aid = os.path.basename(meta_path)[len("agent-"):-len(".meta.json")]
    metas.setdefault(aid, []).append(meta_path)

# one directory scan for every transcript file, not one glob per agent
transcripts = {}
for tp in glob.glob(os.path.join(root, "*", "subagents", "agent-*.jsonl")):
    transcripts.setdefault(os.path.basename(tp)[len("agent-"):-len(".jsonl")], []).append(tp)

agents = {}
for aid, meta_paths in metas.items():
    # One agent can have a transcript in more than one session folder: a session that was
    # resumed or restarted keeps writing the agent there. Its later entries (its final report)
    # are in the other file, so read them all in order of age (2026-10-17: promoter
    # a1a0fba6b22301f44 delivered its report in a later folder, and the first folder alone
    # showed it "waiting" for background tasks that were gone).
    files = sorted(transcripts.get(aid, []), key=os.path.getmtime)
    if not files or now - os.path.getmtime(files[-1]) > hours * 3600:
        continue
    path = files[-1]
    # The later folder can have a meta file of its own naming another type ("general-purpose",
    # 2026-10-17): the one that names a board agent type counts, whichever the folder order.
    meta = None
    for mp in sorted(meta_paths):
        try:
            m = json.load(open(mp))
        except Exception as e:  # a half-written meta file: skip it, say so
            print("agent-state.sh: unreadable %s: %s" % (mp, e), file=sys.stderr)
            continue
        if bare(m.get("agentType")) in BOARD:
            meta = m
            break
    if meta is None:
        continue
    a = {"id": aid, "type": bare(meta["agentType"]), "parent": meta.get("parentAgentId"), "path": path,
         "start": None, "last": None, "card": "-", "card_from": "-", "cards": [], "handback": None, "interrupted": None, "wrote_after": False,
         "reported_ever": False, "handoff": None, "after_handoff": {}, "has_token": False, "bash_tokens": set(),
         "open_tools": set(), "open_at": {}, "bg": {}, "bg_path": {}, "bg_done": set(),
         "api_error": None, "limit_reset": None,
         "reqids": set(), "ctx": 0, "refs": [], "idmap": {}}
    a["bash_tokens"] = set()
    parse_agent(a, files)
    if a["card"] == "-" and a["type"] in FLOATING:
        for ref in reversed(a["refs"]):
            sl = a["idmap"].get(ref[3:]) if ref.startswith("id:") else ref
            if sl:
                a["card"] = sl
                a["card_from"] = "call"
                break
    if not a["cards"]:
        a["cards"] = [a["card"]]
    a["has_token"] = bool(owner_token) and owner_token in a["bash_tokens"]
    if a["start"] is None:
        a["start"] = a["last"] = os.path.getmtime(path)
    a["bg_pending"] = sorted(b for b, bt in a["bg"].items()
                             if b not in a["bg_done"] and (bt is None or now - bt <= bg_max))
    # an agent can be resumed (SendMessage) after it reported or was interrupted:
    # only the last thing it did counts
    for k in ("handback", "interrupted"):
        if a[k] is not None and a["last"] - a[k] > grace:
            a[k] = None
    agents[aid] = a

if cache_dir and not filters and not owner_token and os.path.isdir(cache_dir):
    # housekeeping: entries of agents outside the window, and temp files a dead writer left
    for fn in os.listdir(cache_dir):
        fp = os.path.join(cache_dir, fn)
        try:
            if fn.endswith(".pickle") and fn[:-len(".pickle")] not in agents:
                os.remove(fp)
            elif fn.endswith(".tmp") and now - os.path.getmtime(fp) > 3600:
                os.remove(fp)
        except OSError:
            pass  # another caller removed it first

# Live check of the background commands no notice has ended: a running command holds its
# output file open. One lsof call for all of them; when it cannot run, trust them as before.
paths = sorted({os.path.realpath(a["bg_path"][b]) for a in agents.values() for b in a["bg_pending"]
                if b in a["bg_path"] and os.path.exists(a["bg_path"][b])})
held = set()
if paths:
    try:
        r = subprocess.run(lsof_cmd.split() + ["-Fn", "--"] + paths, capture_output=True, text=True, timeout=60)
        held = {os.path.realpath(ln[1:]) for ln in r.stdout.splitlines() if ln.startswith("n")}
    except (OSError, subprocess.SubprocessError) as e:
        print("agent-state.sh: cannot check background commands with %s (%s): counting them as running" % (lsof_cmd, e), file=sys.stderr)
        held = None
for a in agents.values():
    a["bg_gone"] = []
    if held is None:
        continue
    for b in list(a["bg_pending"]):
        p = a["bg_path"].get(b)
        if p is None:
            continue  # its start named no file: counted as running, as before
        rp = os.path.realpath(p)
        if rp in held:
            continue
        if os.path.exists(rp) and now - os.path.getmtime(rp) <= grace:
            continue  # it just ended: its notice is on the way
        a["bg_pending"].remove(b)
        a["bg_gone"].append(b)

watchers = sorted((a for a in agents.values() if a["type"] == "board-watcher"), key=lambda a: a["start"])
current = watchers[-1]["id"] if watchers else None

def hm(t):
    return datetime.datetime.fromtimestamp(t).astimezone().strftime("%H:%M:%S%Z")

# end time of an agent: None while it can still be alive. The third value says whether
# the end takes the agents it started with it: only a stop does (TaskStop or an interrupt
# stops every agent below; 2026-10-17). A report, a handoff, an API error or a newer
# board-watcher leaves them running, and their reports wake it again.
memo = {}
def end(aid, depth=0):
    if aid in memo:
        return memo[aid]
    a = agents.get(aid)
    if a is None or depth > 10:
        return (None, "", False)  # started by the session itself, or outside the window
    if a["handback"] is not None:
        r = (a["handback"], "reported", False)
    elif a["bg_pending"]:
        # Claude Code resumes it when a background command of its own ends
        r = (None, "background task %s still running" % ",".join(a["bg_pending"]), False)
    elif a["api_error"] is not None:
        r = (a["last"], "died on an API error: %s" % a["api_error"], False)
    elif a["interrupted"] is not None:
        r = (a["interrupted"], "interrupted at %s" % hm(a["interrupted"]), True)
    elif a["type"] == "board-watcher" and aid != current:
        # it may have sat idle between passes before it ended, so its last write
        # is not its end; it was gone at the latest when the next watcher started
        nxt = min(w["start"] for w in watchers if w["start"] > a["start"]) if any(w["start"] > a["start"] for w in watchers) else a["last"]
        r = (max(nxt, a["last"]), "a newer board-watcher started", False)
    else:
        pe, pwhy, kills = end(a["parent"], depth + 1) if a["parent"] else (None, "", False)
        if pe is not None and kills and a["last"] <= pe + grace:
            r = (pe, "died with %s %s, which was stopped at %s" % (agents[a["parent"]]["type"], a["parent"], hm(pe)), True)
        else:
            r = (None, "outlived %s" % a["parent"] if pe is not None and kills else "", False)
    memo[aid] = r
    return r

# A foreground tool call that has been open longer than any tool can run is hung: its agent was
# orphaned (the process that would return the result is gone) and nothing will ever wake it.
# One Bash call ends within 600 s, but parallel calls run one after another (the last of five was
# open 942 s while its agent was alive), so the limit (AGENT_STATE_TOOL_MAX, default 3600) is only
# half the rule: the transcript must also be quiet for more than AGENT_STATE_QUIET. Calls that
# legitimately stay open for hours never count (a child agent, Monitor, a question to the user, plan
# approval); a live background command is judged apart (bg_pending).
TOOL_MAX = float(os.environ.get("AGENT_STATE_TOOL_MAX", "3600"))
LONG_CALLS = {"Agent", "Task", "Monitor", "AskUserQuestion", "ExitPlanMode"}
def hung_for(a):
    """Seconds the oldest hung foreground call has been open, or None."""
    ages = [now - at for at, name in a["open_at"].values() if at is not None and name not in LONG_CALLS and now - at > TOOL_MAX]
    return max(ages) if ages else None

states = {}
for a in agents.values():
    e, why, _ = end(a["id"])
    if a["id"] == current:
        state, why = "current", "the newest board-watcher"
        if a["handoff"] is not None:
            why += ", handed off at %s: restart it" % hm(a["handoff"])
    elif a["type"] == "board-watcher" and a["handoff"] is not None and a["interrupted"] is None:
        # an earlier watcher that handed off: the reports of its children still wake it, and it
        # may only relay them; never a second watcher, never dead while it can still relay
        state, why = "handed-off", "handed off at %s" % hm(a["handoff"])
        if a["after_handoff"]:
            why += ", acted_after_handoff:" + ",".join("%sx%d" % (k, v) for k, v in sorted(a["after_handoff"].items()))
    elif a["handback"] is not None:
        state = "reported"
    elif a["api_error"] is not None and a["handback"] is None and e is not None and why.startswith("died on an API error") \
            and not a["open_tools"] and now - a["last"] > grace:
        # the request failed and nothing resumed it within the grace time (Claude Code
        # retries a dropped response within seconds: before that it is "unknown" below)
        state = "dead"
    elif a["open_tools"] and not a["bg_pending"] and hung_for(a) is not None and now - a["last"] > quiet:
        # a foreground call open past the limit with a quiet transcript: orphaned (a live child agent below
        # turns this into "unknown" again; a live background command keeps it running above)
        state, why = "dead", "tool_call_open_for_%d_minutes_and_quiet" % int(hung_for(a) / 60)
    elif e is not None:
        # signs of an end, but never "dead" while it may still be working: a
        # tool call open (a long command writes nothing until it returns) or a
        # recent write (https://trello.com/c/YZYVBwC9: a promoter and aspect
        # agents were reported dead while they ran, and were started twice)
        if a["open_tools"]:
            state, why = "unknown", why + ", but a tool call is still open"
        elif a["interrupted"] is not None and e == a["interrupted"] and not a["wrote_after"]:
            # its own interrupt marker is its last write (the rejected tool result and the marker
            # only): it was stopped, nothing is running, so it is dead at once. A write after the
            # marker (a resume) or a stop of the parent alone keeps the quiet time above
            state, why = "dead", "interrupted at %s, nothing written after the marker" % hm(a["interrupted"])
        elif now - a["last"] <= quiet:
            state, why = "unknown", why + ", but it wrote %ds ago" % int(now - a["last"])
        else:
            state = "dead"
    elif a["open_tools"]:
        state = "running"
    else:
        state = "waiting"
    states[a["id"]] = (state, why)

ALIVE = {"current", "running", "waiting", "unknown"}
def live_children(aid):
    return [c for c in agents.values() if c["parent"] == aid and states[c["id"]][0] in ALIVE]
# a waiting agent that nothing can wake: no live child, no running background
# command, and silent for more than the stale time. A parent waiting on a child
# that this turns dead is judged on the next round.
changed = True
while changed:
    changed = False
    for a in agents.values():
        if states[a["id"]][0] != "waiting" or a["bg_pending"] or now - a["last"] <= stale:
            continue
        if live_children(a["id"]):
            continue
        states[a["id"]] = ("dead", "no_write_for_%d_minutes_and_nothing_can_wake_it" % int((now - a["last"]) / 60))
        changed = True
# never dead while a child agent of its own is live: the report of the child wakes it
for a in agents.values():
    if states[a["id"]][0] == "dead" and live_children(a["id"]):
        states[a["id"]] = ("unknown", states[a["id"]][1] + ", but a child agent is still live")

if owner_token:
    mine = [a for a in agents.values() if a["has_token"]]
    if len(mine) != 1:
        print("ERROR: %d transcripts carry the token %s in a Bash call (one must): use the token agent-state.sh --token printed you, in your own call" % (
            len(mine), owner_token))
        sys.exit(2)
    me = mine[0]
    if me["type"] != owner_type:
        print("ERROR: the token is in the transcript of %s %s, not of a %s" % (me["type"], me["id"], owner_type))
        sys.exit(2)
    copies = [a for a in agents.values() if a["type"] == owner_type and owner_card in a["cards"]]
    if me not in copies:
        copies.append(me)
    # the card is held by the oldest live copy that never delivered a report
    holders = sorted((a for a in copies if (a is me and not a["reported_ever"])
                      or (a is not me and states[a["id"]][0] in ALIVE and not a["reported_ever"])),
                     key=lambda a: a["start"])
    holder = holders[0] if holders else me
    if holder is me:
        print("OWNER: %s holds %s card %s" % (me["id"], owner_type, owner_card))
        for a in holders[1:]:
            print("NEWER: %s %s (it stands down at its own check)" % (a["id"], states[a["id"]][0]))
        sys.exit(0)
    print("STAND DOWN: %s %s (%s, started %s, last write %ds ago) holds card %s: %s" % (
        owner_type, holder["id"], states[holder["id"]][0], hm(holder["start"]), int(now - holder["last"]), owner_card, holder["path"]))
    sys.exit(1)

rows = []
for a in agents.values():
    state, why = states[a["id"]]
    if a["bg_gone"] and state not in ("current", "handed-off"):
        why = (why + "; " if why else "") + "background task %s gone (no process holds its output)" % ",".join(a["bg_gone"])
    if state == "dead" and a["limit_reset"]:
        # the detail names the reset time (spaces become underscores below): `limit_reset=Oct_19_at_7am_(America/Chicago)`
        why = (why + "; " if why else "") + "limit_reset=" + a["limit_reset"]
    rows.append((a, state, why, len(live_children(a["id"]))))

if not show_all:
    newest = {}
    for r in rows:
        k = (r[0]["type"], r[0]["card"])
        if k not in newest or r[0]["start"] > newest[k][0]["start"]:
            newest[k] = r
    # an older copy that may still be alive is shown too: two of one role or
    # one card at once is exactly what must never be missed
    rows = [r for r in rows if newest[(r[0]["type"], r[0]["card"])] is r or r[1] in ("running", "unknown", "waiting")]

for a, state, why, live in sorted(rows, key=lambda r: r[0]["start"]):
    if filters and not filters & set(a["cards"]) and a["type"] not in filters:
        continue
    # start= (epoch seconds) and card_from= (prompt: the card is the first link of the prompt; call: it is
    # only the newest Trello or card-summary.sh call; -: none) come before cards= and the detail fields
    print("%s %s card=%s id=%s last=%ds children=%d reqs=%d ctx=%d start=%d card_from=%s %s%s%s" % (
        state, a["type"], a["card"], a["id"], int(now - a["last"]), live, len(a["reqids"]), a["ctx"],
        int(a["start"]), a["card_from"],
        ("cards=%s " % ",".join(a["cards"])) if len(a["cards"]) > 1 else "",
        (why.replace(" ", "_") + " ") if why else "", a["path"]))
'

now=${AGENT_STATE_NOW:-$(date +%s)}
export AGENT_STATE_CACHE_DEFAULT=$(kc paths.agent_state_cache)
export AGENT_STATE_SRC_VER=$(printf '%s' "$py" | cksum | tr -d ' ')
exec python3 -I -c "$py" "$dir" "$now" "${AGENT_STATE_HOURS:-24}" "${AGENT_STATE_GRACE:-120}" "${AGENT_STATE_QUIET:-900}" "${AGENT_STATE_BG_MAX:-14400}" "${AGENT_STATE_STALE:-1200}" "$all" \
  "${AGENT_STATE_LSOF:-lsof}" "$owner_card" "$owner_type" "$owner_token" ${filters[@]+"${filters[@]}"}
