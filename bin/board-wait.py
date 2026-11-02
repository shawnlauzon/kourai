"""The board watcher's wait (board-watcher.md, Waiting; rules.md, Waiting).

Run through board-wait.sh, in the foreground. It checks the board, the agents
and GitHub with no model, and returns as soon as there is something to act on,
printing one line per thing:

  Every line about a card carries its short link in square brackets.
  MOVED: "<card>" [<shortLink>] <from> → <to>   a move by anyone but an agent (the user, a
                                       person, or the main session moving a card
                                       out of QUESTIONS)
  CREATED: "<card>" [<sl>] (<list>)    a card made by anyone but an agent
  COMMENT (user|other): "<card>" [<sl>] (<list>): <text>   a comment by anyone but an agent, or the
                                       main session's USER REPLY:. (user): the user's own account (a comment
                                       that does not start with an agent phrase) or a USER REPLY: written by
                                       the Claude account; (other): any other person. Only (user) is an
                                       instruction or an answer (it ends a BLOCKED:, ship/hold)
  WRONG ACCOUNT: "<card>" [<sl>] (<list>): <text>   a comment by another account that starts with an agent
                                       phrase (agent-phrases.txt): an agent posted under the wrong Trello
                                       account; never a user instruction, never an answer to a question
  SERVER LOST: <test-server> [<sl>]: ...  a held test server's host is offline (server-probe.sh, slow check; settings section 44)
  STUCK: ... CI is stuck: <step>. Tried: <tried>  a queued CI job ci-unstick.sh could not free, or a deploy (report only)
  WAIT OVER: "<card>" [<sl>] (<list>): <ref> checks completed (<verdict>); post UNBLOCKED:|RESOLVED:  an Auto-check: wait is over
  CHECK WAIT?: ...  a legacy WAITS FOR: you naming a CI run whose checks completed (once, then at most every 2 hours)
  AGENT: dead <type> card=<c> id=<id>  an agent gone quiet (agent-state.sh); again every BOARD_WAIT_REARM
                                       seconds (default 600) while the card still has work for that type
                                       and no agent of the type is alive on it (the merger and the promoter:
                                       anywhere), so a line a dying watcher never acted on comes back. Never
                                       for an agent that died on a usage limit (RESUME: below)
  RESUME: usage limit over; restart: <type card=<c> id=<id>>, ...   agents that died on a usage limit
                                       ("You've hit your weekly limit · resets Oct 19 at 7am (America/Chicago)",
                                       agent-state.sh gives the dead row limit_reset=) whose reset time has
                                       passed, whose card still has work and that no live agent of their type
                                       has replaced; again every BOARD_WAIT_STUCK_REPEAT seconds while any
                                       is left. The limit is saved when first seen (agent-state.sh drops a row
                                       after 24 hours). No AGENT: dead line is printed for such an agent
  OLD WATCHER ACTED: id=<id> <tool>x<n>,…  <transcript>   a board watcher that handed off (agent-state.sh
                                       state handed-off) has used tools other than SendMessage, ToolSearch
                                       and SubagentHandback since (once per id and tool list): the board
                                       watcher tells the main session; nobody stops it (TaskStop would
                                       kill its children)
  START: <n> free card test server(s); TODO has <m> startable card(s) (<ids>, in List order); TODO has <r> returning card(s) (<ids>), no test server needed; BUILDING has <k> card(s) waiting for their AFTER run (<ids>)
                                       printed again every BOARD_WAIT_START_REPEAT seconds (default 300)
                                       while a server is free and a card could take it, not only once.
                                       A new 🚨 card takes a free server ahead of the normal cards waiting
                                       for AFTER; with no server free and none reserved for it, a part
                                       "TODO has <n> 🚨 card(s) (<ids>) and no free test server: pre-empt
                                       now" tells the board watcher to pre-empt on this pass
  STUCK: "<card>" [<sl>] (<list>): <why>   work that stopped: a card in BUILDING or TESTING with
                                       no live agent (not Blocked, not waiting for a server), a
                                       ready card in MERGING and no merger alive, an orange card
                                       in MERGING with no conflict fix alive (only the top card of
                                       the MERGING order: rules.md, List order), or a live agent
                                       whose transcript has been quiet for 15 minutes; again every
                                       BOARD_WAIT_STUCK_REPEAT seconds (default 600) while it lasts
  STUCK: ... [AGENTS] PR <repo>#<n> @ <head> has no VERIFIED: and no workflow verifier is alive; start the workflow verifier
                                       (both variants below are held while a usage limit on that agent type has not reset)
                                       an [AGENTS] card in MERGING (not Blocked, yellow, orange or person-owned) with
                                       a PR head that has no VERIFIED: / VERIFY SELF: / VERIFY FAILED: and no live
                                       workflow verifier on the card. A head GitHub reports as CONFLICTING gets
                                       "... has no VERIFIED:, conflicts with main and no merger is alive; start the
                                       merger (...)" instead, and nothing while a merger is alive (it marks the
                                       conflict). Again every BOARD_WAIT_STUCK_REPEAT seconds while it lasts
  STUCK: ... both uploads exist (<SMOKE state>) and no promoter is alive   the release status card
                                       ("🚀 RELEASE: …", top of RELEASING) of a release in progress (RELEASING holds
                                       other cards) whose release (since its newest PROMOTING:) has ANDROID UPLOADED:
                                       and IOS UPLOADED: while no promoter is alive: nobody finishes the release
  STUCK: ... the release has stalled: no promoter and no app builder is alive; start <who>   the same card
                                       (not Blocked) while neither a promoter nor an Android
                                       or iOS builder is alive: nobody works on the release. <who> is the promoter,
                                       or, at the app-build step (staging deployed with a client-build, a platform
                                       with no BUILT:, or with SMOKE PASSED and no UPLOADED:), the missing
                                       android / ios app builder
  RELEASE FIX READY: "<fix card>" [<sl>] is joinable (<MERGED | MERGING with MERGE READY:>) and the failed release "<status card>" [<sl>] waits for it: start the promoter
                                       the release status card is named `failed` (its cards stay in RELEASING, never
                                       stalled) and its newest RELEASE FIX: comment (since its newest PROMOTING:) names a
                                       card that is joinable (rules.md, Releasing: not Blocked, and in MERGED, or in
                                       MERGING with MERGE READY: as its newest status, no RELEASE FIX WAITS: newer than
                                       it, and the allow entry of settings section 39 applied); once per fix card and
                                       state (the card's list, in MERGING the date of its MERGE READY:)
  STUCK: ... the failed release's culprit search has no promoter alive and no RELEASE SEARCH ENDED: line; start the promoter
                                       the failed status card whose newest FULL SUITE FAILED: is a first run's (its newest
                                       PROMOTING: has no Added: line), a RELEASE FIX: follows it, no RELEASE SEARCH ENDED:
                                       follows it and no promoter is alive
  STUCK: ... every fix is joinable and no promoter is alive; start the promoter   the failed status card, not Blocked,
                                       whose every named fix card is joinable, while no promoter is alive (the safety net
                                       for a RELEASE FIX READY: line that was lost)
  CONTEXT: <type> card=<c> id=<id> ctx=<n>   an agent whose latest request passed the context
                                       ceiling (BOARD_WAIT_CONTEXT_CEILING tokens, default 200000),
                                       once per agent; the types named: card-manager, promoter,
                                       feature-tester, mobile-, server-, test- and workflow-builder
                                       (handed off), merger and workflow-verifier (not handed off)
  DISK LOW: <n> GB free (<p>% used); <k> removable worktrees (~<s> GB): run the DISK REMOVE: lines
  DISK LOW: <n> GB free (<p>% used); nothing removable (the rest is: <largest folders>)
                                       the Mac's free disk space (BOARD_WAIT_DISK_PATH, the home folder) is below
                                       BOARD_WAIT_DISK_LOW_GB (40), checked on the slow check. With candidates it
                                       repeats every BOARD_WAIT_DISK_REPEAT seconds (1800) while they last (at the critical level
                                       the repeat is the DISK REMOVE: lines only, no header); with none
                                       it prints once per episode, and again only after a fall of BOARD_WAIT_DISK_STEP_GB
                                       (5) since the last such line (rules.md, Settings: Disk space)
  DISK REMOVE: <size> GB: git -C <repo> worktree remove <path>   one removable card worktree (largest first, at
                                       most 20): a worktree <agent type>-<shortLink> of a card in none of WORKFLOW 🤖,
                                       BUILDING and TESTING (or an archived card), with no live agent, a clean tree and
                                       its HEAD on a remote branch. Printed after a DISK LOW:/DISK CRITICAL: line, on the
                                       critical level's 30-minute repeat (no header) and every hour (BOARD_WAIT_DISK_ROUTINE) when any exists. A removal that failed (the
                                       path was printed and is still a candidate at the next calculation) is not printed again
                                       until its HEAD changes or BOARD_WAIT_DISK_FAILED_TTL (86400 s) has passed
  DISK CRITICAL: <n> GB free (<p>% used); the main session must act; no new BEFORE runs   free space below
                                       BOARD_WAIT_DISK_FLOOR_GB (10): once per episode and again after a fall of the STEP since the
                                       last one; the folders of the nothing-removable line follow when no worktree can go. While the
                                       level is critical this script keeps the disk hold fresh (card-test-server.sh disk-hold set),
                                       so `assign` refuses a new BEFORE run, and START: leaves new non-🚨 cards out; the hold ends
                                       (disk-hold clear) when free space is at or above the floor
  DISK OK: <n> GB free                 free space is back at or above the low mark: the episode ends
  REVIEW: "<card>" [<sl>] <repo>#<n> APPROVED|CHANGES_REQUESTED   the user's review on GitHub (a card in REVIEW, or in MERGING with REVIEW: newest)
  VERIFY: "<card>" [<sl>] <repo>#<n> @ <head>  an [AGENTS] card in MERGING, or in WORKFLOW 🤖 whose
                                       newest AWAITING VERIFIED:/sent-back comment is an AWAITING one,
                                       whose PR head has no VERIFIED: or VERIFY SELF: and whose newest
                                       verdict for that head is not VERIFY FAILED: (once per head; again
                                       every BOARD_WAIT_REARM seconds while no workflow verifier is alive
                                       on the card, never on an orange card; held, first print included,
                                       while a usage limit on the workflow verifier has not reset: RESUME:
                                       names the restart). In MERGING a
                                       head an earlier VERIFIED: carries to (a conflict-only fix: verified-carry.sh
                                       CARRIED, every CONFLICT RESOLVED:/REFRESHED: since says no behavior change)
                                       raises none and is ready to merge, unless a NOT CARRIED: names that head
  SENT BACK IN MERGING: "<card>" [<sl>] <repo>#<n> @ <head>   an [AGENTS] card in MERGING whose newest
                                       VERIFIED:/VERIFY FAILED: for a PR head is the VERIFY FAILED: (once per head;
                                       no VERIFY: for that head): the board watcher moves it to the top of WORKFLOW 🤖
  VERIFY PLAN: "<card>" [<sl>] plan revision <n>   an [AGENTS] card in WORKFLOW 🤖 whose newest
                                       plan comment (PLAN: / PLAN AGREED: / PLAN CHANGES:) is a PLAN:
                                       at least BOARD_WAIT_PLAN_GRACE seconds old (default 600: the
                                       time for the normal PLAN READY: path), with no workflow
                                       verifier alive on the card (once per plan comment; again every
                                       BOARD_WAIT_REARM seconds while it stays unanswered with no verifier
                                       alive): start the workflow verifier on the plan (rules.md, Plan first). A plan
                                       comment newer than the card's newest AWAITING VERIFIED: also
                                       holds back VERIFY: for its PR heads (the plan is not agreed).
                                       Held while a usage limit on the workflow verifier has not reset
  VERIFIED CARD: "<card>" [<sl>] (WORKFLOW 🤖): <repo>#<n> @ <head>[, …]   an [AGENTS] card in
                                       WORKFLOW 🤖 whose every open PR has a VERIFIED: naming its
                                       current head (once per set of heads): the board watcher moves
                                       it to MERGING, or to REVIEW when the review policy says so
  DEADLINE: release gap over: <when the last release ended>   the gap between releases (rules.md, Settings)
                                       has passed (MERGED holds a card that is not Blocked and
                                       RELEASING is empty; once per release end): run the promoter
                                       start check
  DEADLINE: <what>                     a release due by age, the urgent fix
                                       deadline, workflow work waiting, a held
                                       TODO, the drift check, the token audit, the time optimization, the
                                       fraud check, the Sentry triage
  COMMENT?: board actions since <cursor> may have been missed   over 20 pages of
                                       actions since the cursor: read the activity
  READY FOR YOU: "<card>" [<sl>] (<list>): <text>   a card manager says the user's step can be done
                                       now (once; the main session prompts the user)
  BLOCKED: "<card>" [<sl>] (<list>) has the Blocked label   a card that just got the label
                                       (once each time; not a status card): read why and send SHOW BLOCKED:
  UNBLOCK?: "<blocked card>" [<sl>] waits for "<card>" [<sl>], which reached MERGED|DONE
                                       a Blocked card's newest WAITS FOR: names a
                                       card that just reached MERGED or DONE: by its card link
                                       when the text has one (a `#N` mentioned in passing does
                                       not count), else by its name, short link or PR number
  LABELS: write refused (HTTP <code>)  a label write was refused (a read-only or expired
                                       token); once, and again only after a write went through
  NOT URGENT: "<card>" [<sl>] (<list>): <why>
                                       a card without 🚨 that holds the release (an open
                                       RELEASE BLOCKER:), that the newest WAITS FOR: of 2 or more
                                       other cards names, or that the release status card's newest
                                       RELEASE FIX: names (once per card and reason; never an
                                       [AGENTS] card, a card with a member, a card with an
                                       URGENT ADDED: comment or one that lost its 🚨). The board watcher
                                       renames it 🚨, moves it to the top and posts URGENT ADDED:
  HOLD ENDED: "<card>" [<sl>]: <why>   a release hold ended (rules.md, Releasing): the card was archived or
                                       moved to MERGED or DONE, or got a RESOLVED: newer than its
                                       RELEASE BLOCKER:. After a RESOLVED: on a card with no PR it
                                       comes again on every slow check until the card is in DONE
                                       (or archived), and never for a card with a member after the first
  HOLDS KNOWN: <n> open                the sweep after a lost state file ended (once)
  SAFETY WAKE                          4 hours since it last returned with work

then exits 0. With nothing to act on by its limit it prints QUIET and exits 3:
call it again at once. Each kind of event is reported once (marks in the state
file), so a wait called again never repeats one; the urgent fix deadline comes
again every 2 hours until a REVERT: is on the card (on a 🚨 [AGENTS] card, or
the board watcher's `BLOCKED: urgent fix deadline passed:` question). Trello or GitHub failures are
noted on stderr and never become events.

Labels (the script owns them, no agent sets or removes one): on every poll it puts the
Actively worked label on each card with a live agent (agent-state.sh: running, waiting or
unknown) and takes it off every card without one; and it puts the Blocked label on a card
whose newest status comment is `WAITS FOR:`, `BLOCKED:`, `NEXT FOR YOU:` or `READY FOR YOU:`
and takes it off after `UNBLOCKED:` or `RESOLVED:`. The user's answer (a comment from the user's own account, or
the main session's `USER REPLY:`, also written `USER REPLY (<note>):`, written by the Claude account;
another person's comment is not an answer, a `USER REPLY:` from another account included) ends a `BLOCKED:`, a
`NEXT FOR YOU:` and a `READY FOR YOU:` at once; it never ends a `WAITS FOR:`, which clears only
with the board watcher's `UNBLOCKED:`. A line starting `UNBLOCKED:` or `RESOLVED:` inside a
`USER REPLY (<note>):` comment (the older form only) counts as that comment. A state file saved
under the older rules (no `block_rules` of 2) has its Blocked states dropped once, so every card's
comments are read again under these rules (6 cards per slow check). A card with no such comment keeps whatever label
it has. The purple No action required label goes on a Blocked card whose newest `WAITS FOR:` names another card or an outside event (never `WAITS FOR: you`
or a `BLOCKED:` question), and on a card whose newest status is `NEXT FOR YOU:` (the user's next
step waits on agent work first); it comes off with the Blocked label, when the wait becomes one
on the user, or at `READY FOR YOU:` (Blocked stays; the line below goes to the main session). Status cards (⛔) are left alone; the release status card (🚀 RELEASE:) gets the Blocked label like any card, never Actively worked.
The yellow-light Waiting for shared resource label is on exactly the cards queueing for a card test server: a want
(card-test-server.sh waiting) of a card in BUILDING, and a new startable TODO card that START: does not name; off every
other card, and not written at all in a poll where `card-test-server.sh list` or `waiting` failed. Nothing reads it back. Labels are written
with the Trello key and token of TRELLO_ENV_FILE; a refused write is noted on stderr, reported
once as a LABELS: line, and retried on the next call.

`board-wait.sh holds` (read-only, no Trello call, no wait) prints the open release holds from the state file:
`HOLD: "<card>" [<sl>] (<list>)` per hold, then `HOLDS UNKNOWN` while a lost state file's sweep is
still reading cards (or when the state file cannot be read), else `NO HOLDS` when there is none.
The sweep reads every open card outside DONE once (sharing the 6 card reads of a slow check with
bootstrap_blocks) and records each RELEASE BLOCKER: card as a hold; a state file that exists but has
no `holds` key starts with none and is complete.

State file (kept across calls): the Trello cursor, the marks, the clocks of the
periodic checks and of the last return. Each poll also writes the heartbeat
file /run-board reads. The key and token are never printed.

Every call ends within BOARD_WAIT_LIMIT plus one poll's reads, each read capped
at 30 seconds, and stops starting slow reads near its limit.

`board-wait.sh --worktrees` prints the DISK REMOVE: lines for the current candidates and nothing else (read only: no state, no
wake). Disk settings: BOARD_WAIT_DISK_PATH, BOARD_WAIT_DISK_LOW_GB, BOARD_WAIT_DISK_FLOOR_GB, BOARD_WAIT_DISK_REPEAT,
BOARD_WAIT_DISK_STEP_GB, BOARD_WAIT_DISK_ROUTINE, BOARD_WAIT_DU, BOARD_WAIT_DISK_FOLDERS, BOARD_WAIT_WORKTREE_REPOS,
BOARD_WAIT_DISK_FAILED_TTL (86400), BOARD_WAIT_DISK_FREE_GB (tests: a fixed free figure).

Settings: BOARD_WAIT_LIMIT (seconds, default 270: the whole call, the last poll's reads included, ends inside the 5-minute prompt cache), BOARD_WAIT_POLL (default 30),
BOARD_WAIT_SLOW (seconds between the GitHub and deadline checks, default 120),
BOARD_WAIT_SLOW_MARGIN (default 60), BOARD_WAIT_ACTIONS_PAGE (board actions per
read, default 300: Trello answered 429 to a 1000-action read, card xXtokNFg; it pages back to the cursor, up to 67 pages),
BOARD_WAIT_START_REPEAT, BOARD_WAIT_STUCK_REPEAT, BOARD_WAIT_STUCK_GRACE (seconds a
stuck card must stay stuck before it is printed, default 180), BOARD_WAIT_IDLE (seconds a
live agent may be quiet, default 900), BOARD_WAIT_CONTEXT_CEILING,
BOARD_WAIT_REARM (seconds before a wake line that starts an agent comes back, default 600),
BOARD_WAIT_SERVER_PROBE and BOARD_WAIT_CI_UNSTICK (the resource scripts, tests), BOARD_WAIT_CHECK_WAIT_REPEAT (7200),
BOARD_WAIT_STATE, BOARD_WAIT_HEARTBEAT, TRELLO_ENV_FILE, TRELLO_API_BASE,
BOARD_WAIT_AGENT_STATE, BOARD_WAIT_PAUSE_DIR, BOARD_WAIT_CARD_TEST_SERVER, BOARD_WAIT_RELEASE_GAP, BOARD_WAIT_GAP_RECHECK, BOARD_WAIT_USER_SETTINGS (tests; the settings file the joinable-fix check reads).
BOARD_WAIT_VERIFIED_CARRY (tests).

Non-agent TODO cards (rules.md, The board: nothing is done on a non-🚨 TODO card until it is
picked up): a TODO card whose name carries a title tag `[Webapp]`, `[REFERENCE]` or `[MILESTONE]`
(not a 🚨 card) is not startable, so it is never in a START: line and never holds the held-TODO
deadline. Any other non-agent card is startable: at pickup the board watcher sends it to QUESTIONS
(board-watcher.md step 11), so it leaves TODO. Nothing is kept for it outside Trello.
"""
import calendar
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zoneinfo

HOME = os.path.expanduser("~")
BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)
sys.dont_write_bytecode = True
import kourai_config  # noqa: E402

# Every identity, path and list below comes from the installation's config (docs/CONFIG.md); the BOARD_WAIT_* and
# RC_* variables further down still override single values, as the tests need.
try:
    CFG = kourai_config.load()
except kourai_config.ConfigError as e:
    sys.exit("board-wait.py: %s" % "; ".join(e.problems))


def cfg(key):
    return kourai_config.get(CFG, key)


def cfg_or(key, default):
    try:
        return kourai_config.get(CFG, key)
    except kourai_config.UnknownKey:
        return default


FILES = cfg("project.state_dir")
PROJECT_BIN = cfg("paths.project_bin")   # the project layer's own scripts (card-test-server.sh, server-probe.sh, ci-unstick.sh)
BOARD = cfg("board.id")
CLAUDE = cfg("board.members.agent")          # the agents' Trello account (every agent)
# Phrases only agents post (agent-phrases.txt, one prefix per line): a comment starting with one from any
# other account is an agent comment under the wrong account, never the user's
AGENT_PHRASES = tuple(l.rstrip("\n") for l in open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "agent-phrases.txt"))
                      if l.strip() and not l.startswith("#"))


def by_person(author, text):
    """True for a comment by a person: not the Claude account and not an agent phrase from another account."""
    return author != CLAUDE and not text.startswith(AGENT_PHRASES)


USER = cfg("board.members.user")             # the user's own Trello account


def is_user(author, text):
    """True for the user's words: a comment from the user's own account that does not start with an agent
    phrase, or the main session's USER REPLY: (posted under the Claude account). Another person's comment,
    a USER REPLY: from another account included, is never the user's answer."""
    if author == CLAUDE:
        return bool(USER_REPLY.match(text))
    return author == USER and not text.startswith(AGENT_PHRASES)
BLOCKED = cfg("board.labels.blocked")         # the Blocked label
YELLOW = cfg("board.labels.attended")          # Needs attended session
ORANGE = cfg("board.labels.conflict")          # Merge conflict
ACTIVE = cfg("board.labels.active")          # Actively worked
NOACTION = cfg("board.labels.no_action")        # No action required (purple)
WAITRES = cfg_or("board.labels.waiting_resource", "")         # Waiting for shared resource (a card test server queue)
WAITS_YOU = re.compile(r"WAITS FOR:\s*you\b")
# The main session's answer: "USER REPLY:", also with a note before the colon ("USER REPLY (2026-10-16):")
USER_REPLY = re.compile(r"USER REPLY\s*(\([^)\n]*\))?\s*:")
# The older form with a note before the colon: only in it does a line below clear the wait (a plain
# "USER REPLY:" never carries an UNBLOCKED:, so it cannot end a WAITS FOR: past the watcher's check)
USER_REPLY_NOTE = re.compile(r"USER REPLY\s*\([^)\n]*\)\s*:")
# A line of a USER REPLY (<note>): comment that clears the wait itself (the main session's older one-comment form)
CLEARS = re.compile(r"^\s*(UNBLOCKED|RESOLVED):", re.M)
# The version of the rules the saved Blocked states were learned under (2: the user's answer ends
# BLOCKED:, NEXT FOR YOU: and READY FOR YOU:, and USER REPLY (<note>): is read)
BLOCK_RULES = 2
# The Blocked states a user's answer ends at once: a question, and the user's step around agent work
ANSWERABLE = ("q", "next", "ready")
USER_LOGIN = cfg("github.user_login")                   # the user's GitHub login
# The app repo may have been renamed or moved. A card's PR line and its VERIFIED: comment may name it
# either way (GitHub redirects the old name), and they are still the same PR.
MOBILE_REPOS = tuple([cfg("repos.app.slug")] + list(cfg("repos.app.legacy_slugs")))
DAY, WEEK = 86400, 7 * 86400
FOUR_DAYS = 4 * DAY                      # the time optimization
PERIODIC = {"drift": ("drift check due", WEEK), "token": ("token audit due", WEEK),
            "time": ("time optimization due", FOUR_DAYS),
            "fraud": ("fraud check due", DAY), "sentry": ("Sentry triage due", DAY)}

env = os.environ.get
# 270, not 530: a wait that ends inside the 5-minute prompt cache of a background agent keeps the board
# watcher's cache warm (a longer quiet return writes its whole context to the cache again, 1.25x, instead of reading it, 0.1x)
LIMIT = float(env("BOARD_WAIT_LIMIT", "270"))
POLL = float(env("BOARD_WAIT_POLL", "30"))
SLOW = float(env("BOARD_WAIT_SLOW", "120"))
SLOW_MARGIN = float(env("BOARD_WAIT_SLOW_MARGIN", "60"))   # no slow reads this close to the limit
ACTIVE_DIR = env("BOARD_WAIT_ACTIVE_DIR", cfg("paths.active_card_dir"))   # active-card.sh writes the merger's cards here
STATE = env("BOARD_WAIT_STATE", cfg("paths.board_wait_state"))
HEARTBEAT = env("BOARD_WAIT_HEARTBEAT", cfg("paths.board_watcher_heartbeat"))
API = env("TRELLO_API_BASE", "https://api.trello.com/1")
AGENT_STATE = env("BOARD_WAIT_AGENT_STATE", os.path.join(BIN, "agent-state.sh"))
ACTION_PAGE = int(env("BOARD_WAIT_ACTIONS_PAGE", "300"))   # a 1000-action page got a 429 (card xXtokNFg)
ACTION_PAGES = 67   # the same 20000 actions as 20 pages of 1000
PAUSE_DIR = env("BOARD_WAIT_PAUSE_DIR", cfg("paths.pause_dir"))
CARD_TEST_SERVER = env("BOARD_WAIT_CARD_TEST_SERVER", os.path.join(PROJECT_BIN, "card-test-server.sh"))
REVIEW_POLICY = env("RC_REVIEW_POLICY", os.path.join(cfg("paths.hooks_dir"), cfg("install.version"), "review-policy.sh"))
REVIEW_POLICY_OVERRIDE = "RC_REVIEW_POLICY" in os.environ   # a test's stand-in script


def policy_command(script, ref):
    """The command that runs the review policy on `ref`. The installed gate runs through kourai-hook (it sets
    KOURAI_BIN, which review-policy.sh needs, and checks the copy's recorded hash); a stand-in named by
    RC_REVIEW_POLICY runs as a plain script."""
    if REVIEW_POLICY_OVERRIDE:
        return ["bash", script, "check", ref]
    return [os.path.join(BIN, "kourai-hook"), os.path.basename(script), "check", ref]


def parse_iso(text):
    """A Trello or GitHub ISO 8601 time as a UTC timestamp, None when it does not parse."""
    try:
        return datetime.datetime.fromisoformat((text or "").replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


RELEASE_HOLD_MAX_AGE = float(env("RC_RELEASE_HOLD_MAX_AGE", "900"))   # a hold decision older than this ends the hold
RELEASE_GAP = env("BOARD_WAIT_RELEASE_GAP", os.path.join(BIN, "release-gap.sh"))
VERIFIED_CARRY = env("BOARD_WAIT_VERIFIED_CARRY", os.path.join(BIN, "verified-carry.sh"))
# The file whose allow entries say whether the promoter may join an unmerged fix (settings section 39). A test hook:
# test-board-wait.sh points it at a fake file.
USER_SETTINGS = env("BOARD_WAIT_USER_SETTINGS", os.path.join(HOME, ".claude/settings.json"))
GAP_RECHECK = float(env("BOARD_WAIT_GAP_RECHECK", "300"))   # seconds between release-gap.sh runs
START_REPEAT = float(env("BOARD_WAIT_START_REPEAT", "300"))
STUCK_REPEAT = float(env("BOARD_WAIT_STUCK_REPEAT", "600"))
STUCK_GRACE = float(env("BOARD_WAIT_STUCK_GRACE", "180"))
# A wake line that starts an agent (VERIFY:, AGENT: dead, VERIFY PLAN:) is printed again after this many
# seconds while its work is still there and no agent of that type is alive (a watcher that died before it
# acted must not lose it for good: https://trello.com/c/NzbZtBDt)
REARM = float(env("BOARD_WAIT_REARM", "600"))
IDLE = float(env("BOARD_WAIT_IDLE", "900"))
SERVER_PROBE = env("BOARD_WAIT_SERVER_PROBE", os.path.join(PROJECT_BIN, "server-probe.sh"))   # held test servers: SERVER LOST: (settings section 44)
CI_UNSTICK_DIR = env("RC_CI_UNSTICK_DIR", cfg("paths.ci_unstick_dir"))   # ci-unstick.sh's per-run state files
CI_RERUN_GRACE = float(env("CI_RERUN_GRACE", "180"))   # as ci-wait.sh: a run re-run this recently still reads as running
CI_UNSTICK = env("BOARD_WAIT_CI_UNSTICK", os.path.join(PROJECT_BIN, "ci-unstick.sh"))         # CI jobs stuck in the queue (settings section 44)
RESOURCE_BUDGET = float(env("BOARD_WAIT_RESOURCE_BUDGET", "20"))                      # seconds for each of the two scripts
CHECK_WAIT_REPEAT = float(env("BOARD_WAIT_CHECK_WAIT_REPEAT", "7200"))                # CHECK WAIT?: again at most this often
CEILING = int(env("BOARD_WAIT_CONTEXT_CEILING", str(cfg("limits.context_ceiling_tokens"))))
# The Mac's free disk space (rules.md, Settings: Disk space)
DISK_PATH = env("BOARD_WAIT_DISK_PATH", HOME)
DISK_LOW = float(env("BOARD_WAIT_DISK_LOW_GB", "40"))
DISK_FLOOR = float(env("BOARD_WAIT_DISK_FLOOR_GB", "10"))
DISK_REPEAT = float(env("BOARD_WAIT_DISK_REPEAT", "1800"))
DISK_STEP = float(env("BOARD_WAIT_DISK_STEP_GB", "5"))
DISK_ROUTINE = float(env("BOARD_WAIT_DISK_ROUTINE", "3600"))
DISK_FAILED_TTL = float(env("BOARD_WAIT_DISK_FAILED_TTL", "86400"))    # a failed removal is offered again after this
DISK_FREE_OVERRIDE = env("BOARD_WAIT_DISK_FREE_GB")     # tests only
DU = env("BOARD_WAIT_DU", "du")
DU_EACH, DU_BUDGET = float(env("BOARD_WAIT_DU_EACH", "5")), float(env("BOARD_WAIT_DU_BUDGET", "20"))                         # seconds per folder, and for all folders of one calculation
MOBILE_REPO = cfg("repos.app.path")
MAIN_REPO = env("BOARD_WAIT_MAIN_REPO", MOBILE_REPO)           # the main checkout the slow check fast-forwards to origin/main
MAIN_FF = env("BOARD_WAIT_MAIN_FF", "1") != "0"                # 0 skips the fast-forward (tests)
MAIN_HOLD = env("BOARD_WAIT_MAIN_HOLD", os.path.join(FILES, "main-checkout-hold"))   # while it exists the checkout is not moved
WATCHER_RELOAD = env("BOARD_WAIT_WATCHER_RELOAD", os.path.join(BIN, "watcher-reload.sh"))
MAIN_CONFIRM = float(env("BOARD_WAIT_MAIN_CONFIRM", "120"))    # a refused fast-forward is reported when the same reason holds this long
MAIN_TRAILER = re.compile(r"^Main checkout: hold( .*)?$")
SERVER_REPO = cfg_or("repos.server.path", "")   # a project with one repo has no server
WORKTREE_REPOS = [r for r in env("BOARD_WAIT_WORKTREE_REPOS", f"{MOBILE_REPO}:{SERVER_REPO}").split(":") if r]
DISK_FOLDERS = [f for f in env("BOARD_WAIT_DISK_FOLDERS", ":".join(cfg("paths.disk_folders"))).split(":") if f]
# A card worktree folder: <agent type>-<shortLink>, the agent type from a fixed list (a folder that only
# looks like a card's, such as testhost-deploy-20261009, never matches)
WORKTREE_NAME = re.compile(r"^(" + "|".join(re.escape(r) for r in cfg("liveness.worktree_roles")) + r")-([A-Za-z0-9]{8})$")
KEEP_LISTS = ("WORKFLOW", "BUILDING", "TESTING")        # a card here still needs its worktrees
MAX_REMOVE_LINES = 20
CLEAN_OK = env("BOARD_WAIT_CLEAN_OK", os.path.join(FILES, "worktree-clean.ok"))   # the first removal run passed (board-watcher.md, step 16)
ALIVE = ("running", "waiting", "unknown")             # agent-state.sh states of an agent that may be working
CEILING_TYPES = tuple(cfg("limits.context_ceiling_roles"))
# A comment that says what a card in BUILDING waits for (the newest of these counts)
AWAITING = ("AWAITING VERIFIED:", "VERIFIED:", "VERIFY SELF:", "VERIFY WANTED:", "ATTENDED EDIT NEEDED:")
NOT_AWAITING = ("VERIFY FAILED:", "CHECK FAILED:", "CHANGES REQUESTED:", "REVERTED:", "UNBLOCKED:")
# The send-backs only: an UNBLOCKED: does not void a VERIFIED: or an AWAITING VERIFIED:
SEND_BACKS = ("VERIFY FAILED:", "CHECK FAILED:", "CHANGES REQUESTED:", "REVERTED:")
# The plan round (rules.md, Plan first). Kept apart from AWAITING / NOT_AWAITING on purpose: github()'s
# VERIFY: state reads only those, so a PLAN: on a card with a PR never makes a head VERIFY: by itself.
PLAN_PHRASES = ("PLAN:", "PLAN AGREED:", "PLAN CHANGES:")
PLAN_GRACE = float(env("BOARD_WAIT_PLAN_GRACE", "600"))
READY_PHRASES = ("MERGE READY:", "REFRESHED:", "CONFLICT RESOLVED:")
NOT_READY = ("MERGED:", "MERGE CONFLICT:", "CHECK FAILED:", "REVIEW:", "REFRESH NEEDED:", "BLOCKED:", "WAITS FOR:",
             "CHANGES REQUESTED:", "VERIFY FAILED:")


def newest_status_index(texts):
    """The index in `texts` (newest first) of the newest comment in READY_PHRASES + NOT_READY that still counts, or
    None. An `UNBLOCKED:` met on the way ends the wait before it: every `WAITS FOR:` / `BLOCKED:` older than it is
    skipped (the wait it answered), so a MERGE READY: under them is the newest status again. Anything newer than the
    UNBLOCKED: counts as before (a new WAITS FOR: after it blocks again). With no UNBLOCKED: the result is the
    first READY_PHRASES + NOT_READY comment, exactly as before."""
    unblocked = False
    for i, (t, _) in enumerate(texts):
        if t.startswith("UNBLOCKED:"):
            unblocked = True
        elif t.startswith(READY_PHRASES + NOT_READY):
            if unblocked and t.startswith(("WAITS FOR:", "BLOCKED:")):
                continue
            return i
    return None


def warn(msg):
    print(f"board-wait: {msg}", file=sys.stderr)


def load_env(path):
    out = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip().strip('"')
    return out


creds = load_env(env("TRELLO_ENV_FILE", cfg("paths.trello_env")))


def trello(path, _method="GET", _body=None, **params):
    """_body: fields sent form-encoded in the request body, for text too long for the URL (HTTP 414)."""
    params.update(key=creds["TRELLO_KEY"], token=creds["TRELLO_TOKEN"])
    url = f"{API}/{path}?" + urllib.parse.urlencode(params)
    data = urllib.parse.urlencode(_body).encode() if _body else None
    req = urllib.request.Request(url, method=_method, data=data, headers={"User-Agent": "board-wait"})
    with urllib.request.urlopen(req, timeout=20) as r:
        body = r.read()
    return json.loads(body) if body.strip() else None


def run(cmd):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as e:
        warn(f"{cmd[0]} failed: {e}")
        return None
    return p.stdout


def run_ok(cmd):
    """Like run, but None also when the command failed (a failed agent-state.sh
    must never look like 'no agent is alive')."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as e:
        warn(f"{cmd[0]} failed: {e}")
        return None
    if p.returncode != 0:
        warn(f"{cmd[0]} exited {p.returncode}")
        return None
    return p.stdout


def wait_names(waits, c):
    """True when a WAITS FOR: text names card c as what it waits for. When the text links one or more
    cards (trello.com/c/<shortLink>), only those links decide: a `#N` or a card name mentioned in
    passing ("... #239 fixed https://trello.com/c/3cj7QkHl") never counts. A text with no card link
    is matched by the card's name, short link or PR numbers, as before."""
    if not waits:
        return False
    links = set(re.findall(r"trello\.com/c/([A-Za-z0-9]{8})", waits))
    if links:
        return c["shortLink"] in links
    names = [c["name"], c["shortLink"]] + [f"#{n}" for _, n in open_prs(c.get("desc"))]
    return any(re.search(rf"(^|[^\w#]){re.escape(x)}(?!\w)", waits) for x in names if x)


def run_gap():
    """release-gap.sh's line. Exit 0 (GAP OVER) and 1 (GAP WAIT) are answers; any other exit
    (2 usage, 3 a failed Trello read) is no answer: noted on stderr with its first stderr line,
    so a gap check that never runs is never silent (it then waits for the next recheck)."""
    try:
        p = subprocess.run([RELEASE_GAP], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as e:
        warn(f"{RELEASE_GAP} failed: {e}")
        return None
    if p.returncode not in (0, 1):
        why = (p.stderr.strip().splitlines() or ["no message"])[0]
        warn(f"{RELEASE_GAP} exited {p.returncode}: {why}")
        return None
    return p.stdout


def agent_rows(out):
    """The lines of agent-state.sh as dicts: state, type, card, cards, id, last (seconds), children, ctx, start
    (epoch seconds; 0 when the line has none), card_from (prompt, call or -; "prompt" when the line has none), line.
    cards is every card the agent works on: its cards= list (a workflow builder given a batch of
    related cards, agent-state.sh), else its one card."""
    rows = []
    for line in (out or "").splitlines():
        f = line.split()
        if len(f) < 4:
            continue
        d = {"state": f[0], "type": f[1], "line": line, "card": "-", "id": "?", "last": 0, "children": 0, "ctx": 0,
             "start": 0, "card_from": "prompt"}
        for x in f[2:]:
            for k in ("card", "id", "last", "children", "ctx", "start", "card_from"):
                if x.startswith(k + "="):
                    v = x[len(k) + 1:]
                    if k in ("last", "children", "ctx", "start"):
                        # a signed number (agent-state prints last=-1s when a transcript write is newer than the clock);
                        # a negative or unreadable value counts as 0, so the numbers always compare
                        m = re.fullmatch(r"-?\d+", v.rstrip("s"))
                        d[k] = max(int(v.rstrip("s")), 0) if m else 0
                    else:
                        d[k] = v
        d["cards"] = [x[len("cards="):].split(",") for x in f[2:] if x.startswith("cards=")]
        d["cards"] = d["cards"][0] if d["cards"] else [d["card"]]
        rows.append(d)
    return rows


MONTHS = {m: i + 1 for i, m in enumerate(("jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"))}
LIMIT_RESET = re.compile(r"limit_reset=(\S*?\)|\S+)")
RESET_TIME = re.compile(r"(?:([A-Za-z]{3})[A-Za-z]* (\d{1,2}) at )?(\d{1,2})(?::(\d\d))?\s*([ap]m) \(([^)]+)\)", re.I)
LIMIT_FALLBACK = 3600       # an unreadable reset time: the death time plus an hour


def reset_epoch(detail, death):
    """When a usage limit is over: `detail` is the limit_reset= value of an agent-state.sh row (spaces written as
    underscores: `Oct_19_at_7am_(America/Chicago)`, `7am_(America/Chicago)`), `death` the epoch second the agent died.
    A date names that day (this year, the next when that is before the death); no date means the next time of day
    after the death, in the named zone. An unreadable value is death + an hour."""
    head, _, tail = detail.partition("(")
    m = RESET_TIME.fullmatch(head.replace("_", " ") + ("(" + tail if tail else ""))
    try:
        if not m:
            raise ValueError(detail)
        zone = zoneinfo.ZoneInfo(m.group(6))
        hour = int(m.group(3)) % 12 + (12 if m.group(5).lower() == "pm" else 0)
        minute = int(m.group(4) or 0)
        d = datetime.datetime.fromtimestamp(death, zone)
        if m.group(1):
            month = MONTHS[m.group(1).lower()]
            at = d.replace(month=month, day=int(m.group(2)), hour=hour, minute=minute, second=0, microsecond=0)
            if at.timestamp() < death:
                at = at.replace(year=at.year + 1)
        else:
            at = d.replace(hour=hour, minute=minute, second=0, microsecond=0)
            if at.timestamp() <= death:
                at += datetime.timedelta(days=1)
        return at.timestamp()
    except (ValueError, KeyError, OSError) as e:   # an unreadable reset: wait an hour from the death
        warn(f"usage limit reset {detail!r} not understood ({type(e).__name__}); using the death time + 1 hour")
        return death + LIMIT_FALLBACK


def hash_text(text):
    import hashlib
    return hashlib.sha1(text.encode()).hexdigest()[:10]


def gh_pr(repo, n, fields):
    out = run(["gh", "pr", "view", str(n), "--repo", repo, "--json", fields])
    try:
        return json.loads(out) if out else None
    except ValueError:
        warn(f"gh pr view {repo}#{n}: no JSON")
        return None


# An [AGENTS] card (rules.md, Card titles and labels): its name starts with
# [AGENTS], or with 🚨 or 🪲 (and any spaces) and then [AGENTS]. The merge gate
# uses the same test.
AGENTS_NAME = re.compile(r"^(?:(?:🚨|🪲)\s*)?\[AGENTS\]")


# The board watcher's question on a 🚨 [AGENTS] card past the urgent fix deadline
# (board-watcher.md step 8); it ends that card's deadline wakes.
AGENTS_DEADLINE_ASKED = "BLOCKED: urgent fix deadline passed:"


def is_agents(card):
    return bool(AGENTS_NAME.match(card["name"]))


# A title tag that marks a card no agent works on (rules.md, The board): never startable, never a wake.
# A 🚨 card is never left out this way: a non-agent 🚨 card goes to QUESTIONS (board-watcher.md step 11).
NON_AGENT_TAG = re.compile(r"\[(Webapp|REFERENCE|MILESTONE)\]", re.I)


def is_urgent(card):
    return card["name"].startswith("🚨")


def is_tagged(card):
    return not is_urgent(card) and bool(NON_AGENT_TAG.search(card["name"]))


# The release status card (rules.md, Releasing): one card at the top of RELEASING whose name starts
# `🚀 RELEASE:`. It is a status card (never taken, counted, checked, merged or released), but it carries
# the release's comments and the Blocked label of a manual step or the green* sign-off, so this script
# keeps its Blocked label like any card's and reads its comments for the release's steps.
RELEASE_CARD = "🚀 RELEASE:"
# The release comments that mark a step (the Releasing table); the release card's state follows the newest.
# Steps that show the release moved past a failure.
# The same answer pattern as card-summary.sh: the user's "ship" or "hold", not "shipping" or "holding off".
ANSWER = re.compile(r'^[\s"*_]*(ship|hold)([^a-z]|$)')
SUCCESS_STEPS = ("STAGING DEPLOYED", "STAGING UNCHANGED", "ANDROID BUILT", "IOS BUILT", "SMOKE PASSED", "ANDROID UPLOADED", "IOS UPLOADED", "BETA PROMOTED")
FAILURE_CLEARED_BY = (("FULL SUITE FAILED:", ()), ("STAGING DEPLOY FAILED:", ("STAGING DEPLOYED", "STAGING UNCHANGED")), ("ANDROID BUILD FAILED:", ("ANDROID BUILT",)),
                      ("IOS BUILD FAILED:", ("IOS BUILT",)), ("SMOKE FAILED", ("SMOKE PASSED",)),
                      ("RELEASE FIX VOID:", ()))
RELEASE_STEPS = ("PROMOTING:", "FULL SUITE", "GREEN*", "STAGING", "ANDROID BUILT", "IOS BUILT", "ANDROID UPLOADED", "IOS UPLOADED", "SMOKE", "BETA")


def is_release_card(card):
    return card["name"].startswith(RELEASE_CARD)


def is_status(card):
    """A status card: `⛔ BLOCKED:` (a held stage) or the release status card."""
    return card["name"].startswith("⛔") or is_release_card(card)


def release_failed(card):
    """The release status card of a failed release: `🚀 RELEASE: failed` (its cards stay in RELEASING)."""
    return is_release_card(card) and card["name"][len(RELEASE_CARD):].strip().startswith("failed")


def in_release(cards):
    """Cards of a release in progress: RELEASING holds a card that is not a status card."""
    return any(c["list"] == "RELEASING" and not is_status(c) for c in cards)


def card_created(card):
    # A Trello id starts with the creation time, in seconds, as 8 hex digits.
    try:
        return int(card["id"][:8], 16)
    except (ValueError, KeyError):
        return None


def parse_ts(date):
    """A Trello ISO date ("2026-10-19T20:40:34.942Z") as epoch seconds, or 0."""
    try:
        return calendar.timegm(time.strptime(date[:19], "%Y-%m-%dT%H:%M:%S"))
    except (ValueError, TypeError):
        return 0


# A PR line that is not open (rules.md: a reverted or included PR stays in the
# description). The same pattern as card-summary.sh and pr-ready.sh.
NOT_OPEN = r"\(closed|replaced by|\(reverted by|\(included in"


def repo_re(repo):
    """A regex for a repo name; the mobile repo matches under both of its names."""
    return "(?:" + "|".join(re.escape(r) for r in MOBILE_REPOS) + ")" if repo in MOBILE_REPOS else re.escape(repo)


def open_prs(desc):
    for line in (desc or "").splitlines():
        m = re.match(r"\*\*PR:\*\*\s+([\w.-]+/[\w.-]+)#(\d+)", line)
        if m and not re.search(NOT_OPEN, line):
            yield m.group(1), int(m.group(2))


def by_position(cards):
    """List order (rules.md, List order): 🚨 cards in list position, then the rest in list position."""
    return sorted(cards, key=lambda c: (not is_urgent(c), c.get("pos", 0)))


def building_order(cards):
    """The BUILDING cards' short links in List order, as the comma list for card-test-server.sh --order."""
    return ",".join(c["shortLink"] for c in by_position([c for c in cards if c["list"] == "BUILDING"]))


def merge_order(cards, marks=None):
    """The MERGING order (rules.md, List order): 🚨 cards, then [AGENTS] and docs cards (a name that starts
    with [AGENTS], 🪲 allowed in front), then the rest, each group in list position; a card whose comments
    carry DEPENDS ON: or WITH: comes after the MERGING cards they name. `marks` is Wait.merge_marks(): the
    short links of those cards per card. Returns the MERGING cards."""
    marks = marks or {}
    def tier(c):
        return 0 if is_urgent(c) else 1 if is_agents(c) else 2
    merging = sorted([c for c in cards if c["list"] == "MERGING"], key=lambda c: (tier(c), c.get("pos", 0)))
    ids = {c["shortLink"] for c in merging}
    out, placed = [], set()
    pending = list(merging)
    while pending:
        for c in pending:
            deps = {d for d in (marks.get(c["shortLink"]) or {}).get("deps", ()) if d in ids and d != c["shortLink"]}
            if deps <= placed:
                out.append(c)
                placed.add(c["shortLink"])
                pending.remove(c)
                break
        else:                       # a cycle: keep the rest in order
            out += pending
            break
    return out


def top_merging(cards, marks=None):
    """The first eligible card in merge_order(): not Blocked, yellow, person-owned, carried (an INCLUDED IN:
    comment) or a status card. None when MERGING has no eligible card."""
    marks = marks or {}
    for c in merge_order(cards, marks):
        if is_status(c) or c["idMembers"] or BLOCKED in c["idLabels"] or YELLOW in c["idLabels"]:
            continue
        if (marks.get(c["shortLink"]) or {}).get("carried"):
            continue
        return c
    return None


def list_kind(name):
    for word in ("WORKFLOW", "TODO", "BUILDING", "TESTING", "REVIEW", "MERGING", "MERGED", "RELEASING", "QUESTIONS",
                 "WAITING FOR CLARITY", "DONE", "VERIFY", "PROPOSED", "BRAINSTORM", "BUG REPORTS"):
        if word in name:
            return "QUESTIONS" if word == "WAITING FOR CLARITY" else word
    return name


class Wait:
    def __init__(self):
        now = time.time()
        loaded = True
        try:
            with open(STATE) as f:
                self.s = json.load(f)
        except (OSError, ValueError):
            # First run: watch from now; no periodic check is due yet.
            self.s = {}
            loaded = False
        if "holds" not in self.s:
            # Release holds (rules.md, Releasing): RELEASE BLOCKER: cards. A state file that exists but has no
            # `holds` key was written before the phrase existed, so the comment stream has seen none: no hold, and
            # complete. A missing or unreadable one lost holds it may have seen: incomplete until the sweep
            # (sweep_holds) has read every open card once.
            self.s["holds"] = {}
            self.s["holds_complete"] = loaded
        self.s.setdefault("holds_complete", True)
        self.s.setdefault("ended", {})       # shortLink -> {"printed": bool}: holds a RESOLVED: closed, until the card is in DONE
        self.s.setdefault("swept", [])       # shortLinks the sweep has read
        self.s.setdefault("dropped", [])     # shortLinks that lost their 🚨 (the user's removal sticks)
        self.s.setdefault("added", {})       # shortLink -> epoch of its URGENT ADDED: comment (0: none)
        self.s.setdefault("waittext", {})    # shortLink -> text of its newest WAITS FOR: while the wait stands
        self.s.setdefault("cursor", time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(now)))
        self.s.setdefault("marks", {})
        self.s.setdefault("periodic", {})
        for k in PERIODIC:   # a check added after the state file was written starts its week now
            self.s["periodic"].setdefault(k, now)
        self.s.setdefault("last_return", now)
        self.s.setdefault("last_slow", 0)
        self.s.setdefault("block", {})      # shortLink -> wait | you | next | ready | q | off | none, from the status comments
        if self.s.get("block_rules") != BLOCK_RULES:
            # States saved under older rules (a card answered in the older USER REPLY (<note>): form still
            # 'q'): dropped once, so bootstrap_blocks reads every card's comments again under these rules.
            # Until then sync_labels leaves a card with no state alone.
            self.s["block"] = {}
            self.s["block_rules"] = BLOCK_RULES
        self.s.setdefault("stuck", {})
        self.s.setdefault("ready", {})      # shortLink -> True when a card in MERGING is ready to merge
        self.s.setdefault("uploaded", {})   # shortLink -> SMOKE state ("no SMOKE comment", "SMOKE PASSED", ...) of a card in RELEASING with both uploads
        self.s.setdefault("reviewwait", {})  # shortLink -> True when a card in REVIEW, or in MERGING with REVIEW: newest, has every open PR passing the review policy
        self.s.setdefault("reviewchg", {})   # shortLink -> True when such a card has an open PR whose newest user review is CHANGES_REQUESTED, newer than the card's newest REVIEW: comment
        self.s.setdefault("reviewpol", {})   # "repo#n:head:review id:sha1(body):sha1(policy)" -> True/False, the review policy's answer (an ERROR is never stored)
        self.s.setdefault("builders", {})   # shortLink -> "android"/"ios"/"android and ios": the app builders a stalled release in RELEASING is missing
        # Stored work (read by has_work(): the re-armed wake lines and RESUME: never read Trello or GitHub on their own)
        self.s.setdefault("unverified", {})   # shortLink -> [{pr, head, conflicting}]: PR heads of an [AGENTS] card in MERGING or WORKFLOW 🤖 waiting for a verdict
        self.s.setdefault("planwait", {})     # shortLink -> plan revision: the newest plan comment is a PLAN: the verifier has not answered
        self.s.setdefault("workflowwork", []) # shortLinks of the cards the workflow-work DEADLINE: line names (rewritten at every slow check)
        self.s.setdefault("nolive", [])       # shortLinks of the BUILDING/TESTING cards stuck() finds without a live agent (rewritten at every stuck check)
        self.s.setdefault("limits", {})       # agent id -> {type, card, reset, seen}: an agent that died on a usage limit, until it is replaced
        self.bysl = {}
        self.t0 = time.time()               # this call's start (the disk check stops looking near the limit)
        self.s.setdefault("carry", {})      # "<sl>|<repo>#<n>|<A>|<head>|<newest resolution date>" -> {"rc", "line", "t"}: verified-carry.sh results
        self.events = []
        self.rows = None                    # agent-state.sh rows of this poll (None: it failed)
        self.lookup_failed = set()          # short links whose archived lookup failed in this process
        self.pending = {}                   # label writes sent in this call
        self.sent_release = None            # the (name, description) last written to the release status card in this call
        self.no_write = False
        self.slow = False
        self.texts_cache = {}
        self.dates_cache = {}
        self.reads = 0                      # card comment reads of this poll
        self.top_cache = None

    def save(self):
        tmp = STATE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.s, f)
        os.replace(tmp, STATE)

    def once(self, key, line):
        if key not in self.s["marks"]:
            self.s["marks"][key] = time.time()
            self.events.append(line)

    def once_until(self, key, line, alive, skip=False):
        """Like once(), but the line comes back (and the mark is renewed) when the mark is REARM seconds old, `skip`
        is false and alive() says no agent of the type is working on it: a line that went to a watcher that died
        before it acted is not lost for good. The work condition is the caller's: it calls this only while it holds."""
        now = time.time()
        t = self.s["marks"].get(key)
        if t is None:
            if skip:
                return          # held (a usage limit, an orange card): no line and no mark; it comes at its normal time once the hold ends
            self.s["marks"][key] = now
            self.events.append(line)
        elif now - t >= REARM and not skip and not alive():
            self.s["marks"][key] = now
            self.events.append(line)

    def limit_active(self, typ):
        """True while a usage limit that killed an agent of `typ` has not reset (self.s["limits"], saved by agents()):
        the next agent of that type would die on the same limit, so no wake line starts one until RESUME:. Keyed by
        type, not card: a limit that killed one verifier kills the next on any card."""
        now = time.time()
        return any(e["type"] == typ and e["reset"] > now for e in self.s["limits"].values())

    def alive_of(self, typ, card=None):
        """True when an agent of `typ` is alive on `card` (any of its cards=), or, with no card, anywhere on the board."""
        return any(r["type"] == typ and r["state"] in ALIVE and (card is None or card in r["cards"]) for r in self.rows or [])

    BOARD_WIDE = ("merger", "promoter")
    NOLIVE_TYPES = tuple(cfg("liveness.card_roles"))

    def has_work(self, typ, card, cards):
        """Does an agent of `typ` still have work for `card`, from stored state only (no read). The merger and the
        promoter are board-wide (a merger's card is only its newest Trello call): the card is ignored. Any other
        type, and any card that is Blocked, yellow, person-owned, a status card or gone: no work."""
        if typ == "merger":
            return any(self.s["ready"].values())
        if typ == "promoter":
            # While the release status card carries the Blocked label (the promoter's second death in a row, a manual
            # step, the green* sign-off), the 10-minute AGENT: dead repeat stops (rules.md, A transient failure). The
            # label lags the comment; the board watcher decides the start itself from the comments.
            if any(is_release_card(c) and BLOCKED in c["idLabels"] for c in cards):
                return False
            return in_release(cards)
        c = self.bysl.get(card)
        if c is None or is_status(c) or c["idMembers"] or BLOCKED in c["idLabels"] or YELLOW in c["idLabels"]:
            return False
        if typ == "workflow-verifier":
            if c["list"] == "MERGING":      # strictly top-down (rules.md, List order): only the top MERGING card
                top = self.top(cards)
                if top is not None and top["shortLink"] != card:
                    return False
            return ORANGE not in c["idLabels"] and (bool(self.s["unverified"].get(card)) or card in self.s["planwait"])
        if typ in self.NOLIVE_TYPES:
            return card in self.s["nolive"]
        if typ == "workflow-builder":
            return card in self.s["workflowwork"]
        if typ in ("android-builder", "ios-builder"):
            return typ.split("-")[0] in self.s["builders"].get(card, "")
        return False

    # --- every poll ------------------------------------------------------------
    def poll(self, slow):
        self.slow = slow
        try:
            lists = {l["id"]: l["name"] for l in trello(f"boards/{BOARD}/lists", filter="open", fields="name")}
            cards = trello(f"boards/{BOARD}/cards", filter="open", fields="name,idList,idLabels,idMembers,shortLink,desc,pos")
            acts = self.board_actions()
        except Exception as e:  # noqa: BLE001 (a network failure of any kind: noted, never an event)
            warn(f"Trello read failed: {type(e).__name__}: {e}")
            return
        for c in cards:
            c["list"] = list_kind(lists.get(c["idList"], ""))
        self.bysl = {c["shortLink"]: c for c in cards}
        self.texts_cache = {}
        self.reads = 0
        self.top_cache = None
        out = run_ok([AGENT_STATE])
        self.rows = None if out is None else agent_rows(out)
        self.user_events(acts)
        if slow:
            self.bootstrap_blocks(cards)
            self.sweep_holds(cards)
        self.sync_labels(cards)
        self.unblock(cards)
        self.agents(cards)
        self.context()
        if slow:
            self.disk(cards)
            self.update_release_hold(cards)
            self.sync_holds(cards)
            self.not_urgent(cards)
        self.start(cards)
        if slow:
            self.github(cards)
            self.deadlines(cards)
            self.release_card(cards)
            self.resources(cards)
            self.main_checkout()
        self.stuck(cards)

    def board_actions(self):
        """Every board action since the cursor. Trello returns the newest page
        first, so when a page is full, the next one is read with before=<the
        oldest id so far>, back to the cursor (at most ACTION_PAGES pages)."""
        acts, before = [], None
        for _ in range(ACTION_PAGES):
            params = dict(filter="commentCard,updateCard:idList,createCard", since=self.s["cursor"],
                          limit=ACTION_PAGE, fields="id,type,date,idMemberCreator,data")
            if before:
                params["before"] = before
            page = trello(f"boards/{BOARD}/actions", **params)
            acts += page
            if len(page) < ACTION_PAGE:
                return acts
            oldest = min(page, key=lambda a: a["date"])["id"]
            if oldest == before:
                break
            before = oldest
        warn(f"more than {ACTION_PAGES} pages of board actions since {self.s['cursor']}; older ones were not read")
        self.events.append(f"COMMENT?: board actions since {self.s['cursor']} may have been missed: read the board's activity")
        return acts

    def user_events(self, acts):
        newest = self.s["cursor"]
        for a in sorted(acts, key=lambda a: a["date"]):
            if a["date"] <= self.s["cursor"] and f"act:{a['id']}" in self.s["marks"]:
                continue
            newest = max(newest, a["date"])
            d = a.get("data") or {}
            c = d.get("card") or {}
            if a["type"] == "commentCard" and c.get("shortLink"):
                self.track_block(c["shortLink"], d.get("text") or "", is_user(a.get("idMemberCreator"), d.get("text") or ""))
            label = f'"{c.get("name", "?")}" [{c.get("shortLink", "?")}]'
            agent = a.get("idMemberCreator") == CLAUDE
            text = (d.get("text") or "").replace("\n", " ")
            if a["type"] == "commentCard" and c.get("shortLink") and text.startswith("URGENT ADDED:"):
                self.s["added"][c["shortLink"]] = parse_ts(a["date"])
            wrong = a["type"] == "commentCard" and not agent and not by_person(a.get("idMemberCreator"), d.get("text") or "") and not USER_REPLY.match(text)
            if wrong:
                self.once(f"act:{a['id']}", f'WRONG ACCOUNT: {label} ({(d.get("list") or {}).get("name", "?")}): {text[:200]}')
            elif a["type"] == "commentCard":
                if text.startswith("READY FOR YOU:"):
                    self.once(f"act:{a['id']}", f'READY FOR YOU: {label} ({(d.get("list") or {}).get("name", "?")}): {text[len("READY FOR YOU:"):].strip()[:200]}')
                elif not agent or USER_REPLY.match(text):
                    kind = "user" if is_user(a.get("idMemberCreator"), d.get("text") or "") else "other"
                    self.once(f"act:{a['id']}", f'COMMENT ({kind}): {label} ({(d.get("list") or {}).get("name", "?")}): {text[:200]}')
            elif a["type"] == "updateCard":
                before = (d.get("listBefore") or {}).get("name", "?")
                after = (d.get("listAfter") or {}).get("name", "?")
                if not agent or list_kind(before) == "QUESTIONS":
                    self.once(f"act:{a['id']}", f'MOVED: {label} {before} → {after}')
            elif a["type"] == "createCard" and not agent:
                self.once(f"act:{a['id']}", f'CREATED: {label} ({(d.get("list") or {}).get("name", "?")})')
        self.s["cursor"] = newest

    def unblock(self, cards):
        where = self.s.setdefault("lists", {})
        arrived = [c for c in cards if where.get(c["shortLink"]) not in (None, c["list"])
                   and c["list"] in ("MERGED", "DONE", "VERIFY")]
        blocked = [c for c in cards if BLOCKED in c["idLabels"] and not c["name"].startswith("⛔")]   # the release status card counts
        if arrived and blocked:
            for b in blocked:
                waits = self.waits_for(b)
                for c in arrived:
                    if wait_names(waits, c):
                        self.events.append(f'UNBLOCK?: "{b["name"]}" [{b["shortLink"]}] waits for "{c["name"]}" '
                                           f'[{c["shortLink"]}], which reached {c["list"]}')
        # A 🚨 card that lost its 🚨 (renamed) or left the board (archived) also clears a merger's
        # urgent-hold WAITS FOR:; neither is a move into MERGED or DONE, so name it here.
        seen = self.s.setdefault("urgent", {})
        now = {c["shortLink"]: c for c in cards}
        gone = [{"shortLink": sl, "name": nm} for sl, nm in seen.items()
                if sl not in now or not now[sl]["name"].startswith("🚨")]
        if gone and blocked:
            for b in blocked:
                waits = self.waits_for(b)
                for c in gone:
                    if wait_names(waits, c):
                        why = "was archived" if c["shortLink"] not in now else "lost its 🚨"
                        self.once(f"urgent-gone:{b['shortLink']}:{c['shortLink']}:{why}",
                                  f'UNBLOCK?: "{b["name"]}" [{b["shortLink"]}] waits for "{c["name"]}" [{c["shortLink"]}], which {why}')
        # A 🚨 the user removed sticks (NOT URGENT: stays silent for the card): the mark is kept in the state.
        dropped = self.s["dropped"]
        for sl in seen:
            if sl in now and not now[sl]["name"].startswith("🚨") and sl not in dropped:
                dropped.append(sl)
        self.s["dropped"] = [sl for sl in dropped if sl not in now or not now[sl]["name"].startswith("🚨")]
        self.s["urgent"] = {c["shortLink"]: c["name"] for c in cards if c["name"].startswith("🚨")}
        self.s["lists"] = {c["shortLink"]: c["list"] for c in cards}
        # BLOCKED: once each time a card gets the label; the mark goes when the label comes off
        for c in blocked:
            self.once(f"blocked:{c['shortLink']}", f'BLOCKED: "{c["name"]}" [{c["shortLink"]}] ({c["list"]}) has the Blocked label')
        on = {c["shortLink"] for c in blocked}
        for k in [k for k in self.s["marks"] if k.startswith("blocked:") and k[8:] not in on]:
            del self.s["marks"][k]

    def waits_for(self, card):
        """The text of the card's newest WAITS FOR: comment, or ""."""
        try:
            acts = trello(f"cards/{card['shortLink']}/actions", filter="commentCard", limit=50, fields="data,date")
        except Exception as e:  # noqa: BLE001 (noted; the watcher still checks Blocked cards each pass)
            warn(f"Trello read of {card['shortLink']} failed: {e}")
            return ""
        for a in sorted(acts, key=lambda a: a.get("date", ""), reverse=True):
            t = (a.get("data") or {}).get("text", "")
            if t.startswith("WAITS FOR:"):
                return t
        return ""

    def deadline_handled(self, card):
        """True when the urgent fix deadline has been acted on: a REVERT: comment
        is on the card, or, for a 🚨 [AGENTS] card (nothing to revert), the board
        watcher's `BLOCKED: urgent fix deadline passed: …` question. A failed read
        counts as True (noted): no wake now; the next slow check reads it again."""
        try:
            acts = trello(f"cards/{card['shortLink']}/actions", filter="commentCard", limit=1000, fields="data")
        except Exception as e:  # noqa: BLE001 (noted; read again on the next slow check)
            warn(f"Trello read of {card['shortLink']} failed: {e}")
            return True
        ends = ("REVERT:", AGENTS_DEADLINE_ASKED) if is_agents(card) else ("REVERT:",)
        return any((a.get("data") or {}).get("text", "").startswith(ends) for a in acts)

    def agents(self, cards):
        now = time.time()
        for r in self.rows or []:
            if r["state"] == "dead" and r["children"] == 0:
                lim = LIMIT_RESET.search(r["line"])
                if lim:
                    # A usage limit (agent-state.sh gives limit_reset=): no AGENT: dead (a restart now would die on
                    # the same limit); RESUME: names it once the limit is over (resume_line, from stuck()). The
                    # row leaves agent-state.sh's output after 24 hours, so it is saved here when first seen.
                    if r["id"] not in self.s["limits"]:
                        death = now - r["last"]
                        self.s["limits"][r["id"]] = {"type": r["type"], "card": r["card"], "seen": now,
                                                     "reset": reset_epoch(lim.group(1), death)}
                    continue
                key, line = f"dead:{r['id']}", f"AGENT: dead {r['type']} card={r['card']} id={r['id']}"
                if key not in self.s["marks"]:
                    self.once(key, line)        # the first line for an id is never conditional
                else:
                    # again every REARM seconds while the work is still there and no agent of that type is alive on it
                    board_wide = r["type"] in self.BOARD_WIDE
                    work = self.has_work(r["type"], r["card"], cards)
                    self.once_until(key, line, lambda: self.alive_of(r["type"], None if board_wide else r["card"]),
                                    skip=(not work) or self.limit_active(r["type"]))
            # a handed-off board watcher must only relay (rules.md, Liveness): it used other tools after its HANDOFF
            m = re.search(r"acted_after_handoff:(\S+)", r["line"])
            if r["state"] == "handed-off" and m:
                self.once(f"oldwatcher:{r['id']}:{m.group(1)}", f"OLD WATCHER ACTED: id={r['id']} {m.group(1)} {r['line'].split()[-1]}")

    def context(self):
        """An agent whose latest request passed the context ceiling (once per agent)."""
        for r in self.rows or []:
            if r["type"] in CEILING_TYPES and r["state"] in ALIVE and r["ctx"] > CEILING:
                self.once(f"ctx:{r['id']}", f"CONTEXT: {r['type']} card={r['card']} id={r['id']} ctx={r['ctx']}")

    # --- labels ------------------------------------------------------------------
    def set_label(self, c, label, want):
        has = label in c["idLabels"]
        key = (c["shortLink"], label)
        if want == has:
            self.pending.pop(key, None)
            return
        if self.no_write or self.pending.get(key) == want:
            return
        try:
            if want:
                trello(f"cards/{c['id']}/idLabels", "POST", value=label)
                c["idLabels"].append(label)
            else:
                trello(f"cards/{c['id']}/idLabels/{label}", "DELETE")
                c["idLabels"].remove(label)
            self.pending[key] = want
            for k in [k for k in self.s["marks"] if k.startswith("labels-refused:")]:
                del self.s["marks"][k]       # a write went through: the next refusal is news again
        except urllib.error.HTTPError as e:
            warn(f"label write on {c['shortLink']} refused: HTTP {e.code}")
            if e.code in (401, 403):
                # a read-only or expired token: one event line, and no more writes in this call.
                # Any other code (429, 5xx) is noted above and retried on the next call, no event.
                self.once(f"labels-refused:{e.code}", f"LABELS: write refused (HTTP {e.code}): the board's labels are not being kept; check the Trello token")
                self.no_write = True
        except Exception as e:  # noqa: BLE001 (noted; sent again on the next poll)
            warn(f"label write on {c['shortLink']} failed: {type(e).__name__}: {e}")

    def merger_cards(self):
        """The cards the live merger has in work: the short links in the file active-card.sh wrote, unless the
        file is older than the newest live merger (a merger killed mid-card leaves its file behind)."""
        mergers = [r for r in self.rows or [] if r["type"] == "merger" and r["state"] in ALIVE]
        if not mergers:
            return set()
        path = os.path.join(ACTIVE_DIR, "merger")
        try:
            if os.path.getmtime(path) < max(r["start"] for r in mergers):
                return set()
            with open(path) as f:
                return {x for x in f.read().split() if re.fullmatch(r"[A-Za-z0-9]{8}", x)}
        except OSError:      # no file: the merger has not said which card it is on, so no card is labelled
            return set()

    def sync_labels(self, cards):
        # Actively worked is on a card an agent works on right now, and on no other card (rules.md, Labels).
        # A merger and a promoter are floating roles: their card= is only their newest Trello call, often a queued
        # card, so it is never used. The merger's cards come from its file (active-card.sh); the promoter's covered
        # cards in RELEASING are green only while the release status card reads "running:" (release_card keeps it
        # true; it can lag by one slow check). A workflow builder or verifier whose card is only its newest call
        # (card_from=call: no card in its prompt) labels nothing.
        live = None
        if self.rows is not None:
            live = {c for r in self.rows if r["state"] in ALIVE and r["type"] not in ("merger", "promoter")
                    and r["card_from"] != "call" for c in r["cards"] if c != "-"}
            live |= self.merger_cards()
        rel = next((c for c in cards if is_release_card(c)), None)
        releasing = rel is not None and rel["name"].startswith(f"{RELEASE_CARD} running:")
        for c in cards:
            if c["name"].startswith("⛔"):
                continue
            if live is not None and c["list"] == "RELEASING" and releasing and not is_status(c):
                live.add(c["shortLink"])
            if live is not None and not is_release_card(c):     # the release status card is never "actively worked"
                self.set_label(c, ACTIVE, c["shortLink"] in live)
            st = self.s["block"].get(c["shortLink"])
            if st in ("wait", "you", "next", "ready", "q", "off"):
                self.set_label(c, BLOCKED, st != "off")
                self.set_label(c, NOACTION, st in ("wait", "next"))

    def track_block(self, sl, text, user):
        """One comment of the stream: the card's Blocked state follows WAITS FOR: / BLOCKED: /
        NEXT FOR YOU: / READY FOR YOU: (on) and UNBLOCKED: / RESOLVED: (off); the user's answer ends
        a BLOCKED:, a NEXT FOR YOU: and a READY FOR YOU:, never a WAITS FOR:."""
        b = self.s["block"]
        if text.startswith("RELEASE BLOCKER:"):
            self.s["holds"].setdefault(sl, {})
            self.s["ended"].pop(sl, None)
        elif text.startswith("RESOLVED:") and sl in self.s["holds"]:
            del self.s["holds"][sl]                  # RESOLVED: ends the hold (rules.md, Releasing)
            self.s["ended"][sl] = {"printed": False}
        if text.startswith("WAITS FOR:"):
            self.s["waittext"][sl] = text
        elif text.startswith(("UNBLOCKED:", "RESOLVED:")):
            self.s["waittext"].pop(sl, None)
        if user and USER_REPLY_NOTE.match(text) and CLEARS.search(text):
            b[sl] = "off"       # an UNBLOCKED: or RESOLVED: line inside the main session's older-form reply
        elif text.startswith("WAITS FOR:"):
            b[sl] = "you" if WAITS_YOU.match(text) else "wait"
        elif text.startswith("NEXT FOR YOU:"):
            b[sl] = "next"      # the user's next step waits on agent work first
        elif text.startswith("READY FOR YOU:"):
            b[sl] = "ready"     # that work is done: the user's step can be done now
        elif text.startswith("BLOCKED:"):
            b[sl] = "q"
        elif text.startswith(("UNBLOCKED:", "RESOLVED:")):
            b[sl] = "off"
        elif user and b.get(sl) in ANSWERABLE:
            b[sl] = "off"       # the user answered: a WAITS FOR: stays until UNBLOCKED:

    def merge_marks(self, cards):
        """Per MERGING card, from its comments (as merge_ready() reads them, never the description):
        `deps`, the short links of the MERGING cards its DEPENDS ON: (a PR, matched to the card whose
        description names it) and WITH: (the fixing card's link or its PR) comments name, and `carried`,
        an INCLUDED IN: comment. A comment read that fails marks nothing for that card."""
        merging = [c for c in cards if c["list"] == "MERGING"]
        by_pr = {}
        for c in merging:
            for repo, n in open_prs(c.get("desc")):
                by_pr[(repo, n)] = c["shortLink"]
        ids = {c["shortLink"] for c in merging}
        marks = {}
        for c in merging:
            texts = self.card_texts(c)
            if texts is None:
                continue
            deps = set()
            for t, _ in texts:
                if t.startswith(("DEPENDS ON:", "WITH:")):
                    deps.update(sl for sl in re.findall(r"trello\.com/c/(\w{8})", t) if sl in ids)
                    for repo, n in re.findall(r"([\w.-]+/[\w.-]+)#(\d+)", t):
                        if (repo, int(n)) in by_pr:
                            deps.add(by_pr[(repo, int(n))])
            deps.discard(c["shortLink"])
            marks[c["shortLink"]] = {"deps": deps, "carried": any(t.startswith("INCLUDED IN:") for t, _ in texts)}
        return marks

    def top(self, cards):
        """The top MERGING card (top_merging() on this poll's comments), computed once per poll."""
        if self.top_cache is None:
            self.top_cache = (top_merging(cards, self.merge_marks(cards)),)
        return self.top_cache[0]

    def card_texts(self, c):
        """The card's newest comments, newest first, as (text, is_user); None when the read fails."""
        sl = c["shortLink"]
        if sl not in self.texts_cache:
            self.reads += 1
            try:
                acts = trello(f"cards/{sl}/actions", filter="commentCard", limit=100, fields="data,date,idMemberCreator")
                acts = sorted(acts, key=lambda a: a.get("date", ""), reverse=True)
                self.texts_cache[sl] = [((a.get("data") or {}).get("text", ""), is_user(a.get("idMemberCreator", CLAUDE), (a.get("data") or {}).get("text", ""))) for a in acts]
                self.dates_cache[sl] = [a.get("date", "") for a in acts]      # aligned with the texts, newest first
            except Exception as e:  # noqa: BLE001 (noted; read again on the next slow check)
                warn(f"Trello read of {sl} failed: {e}")
                self.texts_cache[sl] = None
        return self.texts_cache[sl]

    def head_verdict(self, c, texts, repo, n, head, kinds=("VERIFIED", "VERIFY SELF", "VERIFY FAILED")):
        """The newest verdict comment naming this PR at this head: "verified" (VERIFIED:), "self" (VERIFY SELF:),
        "failed" (VERIFY FAILED:) or None; `kinds` limits which phrases count. `texts` is card_texts(c), newest first. A VERIFIED: and a VERIFY FAILED: with
        the same date count as failed (fail closed), as in merge-gate.sh."""
        dates = self.dates_cache.get(c["shortLink"]) or [""] * len(texts)
        pat = rf"({'|'.join(kinds)}): {repo_re(repo)}#{n} @ {re.escape(head)}"
        hits = [(i, re.match(pat, t).group(1)) for i, (t, _) in enumerate(texts) if re.match(pat, t)]
        if not hits:
            # No verdict at this head: an earlier VERIFIED: may carry to it (a conflict-only fix).
            return "carried" if self.carried(c, texts, repo, n, head) else None
        i, kind = hits[0]
        if kind == "VERIFIED" and any(k == "VERIFY FAILED" and dates[j] == dates[i] for j, k in hits):
            return "failed"
        return {"VERIFIED": "verified", "VERIFY SELF": "self", "VERIFY FAILED": "failed"}[kind]

    def carried(self, c, texts, repo, n, head):
        """A conflict-only fix keeps the PR's VERIFIED: (the user's decision, 2026-10-18, card mWg2nZnw), as merge-gate.sh
        decides it: the newest verdict for this PR is a VERIFIED: at a commit A, no send-back is newer than it, at least one
        CONFLICT RESOLVED:/REFRESHED: for this PR is newer and each says "no behavior change" on its first line, and
        verified-carry.sh <repo>#<n> <A> <head> says CARRIED (only merges of the base and empty commits since A). A comment
        starting `NOT CARRIED: <repo>#<n> @ <head>` (the merger's, after the gate refused the head) cancels it for that
        head: the head then has no verdict, so VERIFY: is raised for it. The script's result is cached per card, PR, A, head
        and newest resolution comment (an ERROR for one STUCK_REPEAT only), so an unchanged card runs no git fetch."""
        pr = rf"{repo_re(repo)}#{n}"
        if any(re.match(rf"NOT CARRIED: {pr} @ {re.escape(head)}(?![0-9a-f])", t) for t, _ in texts):
            return False
        dates = self.dates_cache.get(c["shortLink"]) or [""] * len(texts)
        a, a_date, resolved = None, None, []
        for i, (t, _) in enumerate(texts):
            m = re.match(rf"(VERIFIED|VERIFY FAILED): {pr} @ ([0-9a-f]{{7,40}})(?![0-9a-f])", t)
            if m:
                if m.group(1) == "VERIFIED":
                    a, a_date = m.group(2), dates[i]
                break
            if t.startswith(SEND_BACKS):
                return False
            if re.match(rf"(CONFLICT RESOLVED|REFRESHED): {pr}(?![0-9])", t):
                if "no behavior change" not in t.split("\n")[0]:
                    return False
                resolved.append(dates[i])
        if not a or not resolved:
            return False
        # A send-back with the same date as the VERIFIED: counts as newer (fail closed, as merge-gate.sh sorts it).
        if any(t.startswith(SEND_BACKS) and dates[j] == a_date for j, (t, _) in enumerate(texts)):
            return False
        key = f"{c['shortLink']}|{repo}#{n}|{a}|{head}|{resolved[0]}"
        hit = self.s["carry"].get(key)
        if hit and (hit["rc"] in (0, 1) or time.time() - hit["t"] < STUCK_REPEAT):
            return hit["rc"] == 0
        try:
            p = subprocess.run([VERIFIED_CARRY, f"{repo}#{n}", a, head], capture_output=True, text=True, timeout=60)
            rc, line = p.returncode, (p.stdout.strip().splitlines() or [""])[0]
        except (OSError, subprocess.TimeoutExpired) as e:
            rc, line = 2, f"ERROR: {e}"
        if rc not in (0, 1):
            warn(f"verified-carry.sh {repo}#{n} {a} {head}: {line}")
            rc = 2
        self.s["carry"][key] = {"rc": rc, "line": line, "t": time.time()}
        return rc == 0

    def bootstrap_blocks(self, cards):
        """A card the stream has not shown yet: read its comments once to learn its Blocked state
        (at most 6 per slow check; a card with no status comment at all is 'none': its label is left alone)."""
        todo = [c for c in cards if c["shortLink"] not in self.s["block"] and not c["name"].startswith("⛔")
                and c["list"] not in ("DONE", "VERIFY", "PROPOSED", "BUG REPORTS")]
        for c in todo[:6]:
            texts = self.card_texts(c)
            if texts is None:
                continue
            st, answered = "none", False
            for t, user in texts:                         # newest first
                if user and USER_REPLY_NOTE.match(t) and CLEARS.search(t):
                    st = "off"      # an UNBLOCKED: or RESOLVED: line inside the main session's older-form reply
                elif t.startswith("WAITS FOR:"):
                    st = "you" if WAITS_YOU.match(t) else "wait"    # an answer after it does not end it
                    self.s["waittext"][c["shortLink"]] = t
                elif t.startswith("NEXT FOR YOU:"):
                    st = "off" if answered else "next"
                elif t.startswith("READY FOR YOU:"):
                    st = "off" if answered else "ready"
                elif t.startswith("BLOCKED:"):
                    st = "off" if answered else "q"
                elif t.startswith(("UNBLOCKED:", "RESOLVED:")):
                    st = "off"
                elif user:
                    answered = True
                    continue
                else:
                    continue
                break
            self.s["block"][c["shortLink"]] = st

    def sweep_holds(self, cards):
        """After a lost state file: read every open card outside DONE once (a status card is skipped) and
        record each RELEASE BLOCKER: card as an open hold, or, when a RESOLVED: is newer and the card has no
        PR, as ended (sync_holds then prints it until the card is in DONE). Shares the 6 card reads of a slow
        check with bootstrap_blocks, which reads first. When every card is read, holds are complete and
        HOLDS KNOWN: <n> open is printed once."""
        if self.s["holds_complete"]:
            return
        todo = [c for c in cards if c["list"] not in ("DONE", "VERIFY") and not is_status(c) and c["shortLink"] not in self.s["swept"]]
        for c in todo:
            sl = c["shortLink"]
            if sl not in self.texts_cache and self.reads >= 6:
                break
            texts = self.card_texts(c)
            if texts is None:
                continue
            self.s["swept"].append(sl)
            blocker = next((i for i, (t, _) in enumerate(texts) if t.startswith("RELEASE BLOCKER:")), None)
            if blocker is None:
                continue
            resolved = next((i for i, (t, _) in enumerate(texts) if t.startswith("RESOLVED:")), None)
            if resolved is not None and resolved < blocker:          # newest first: a smaller index is newer
                if not list(open_prs(c.get("desc"))):
                    self.s["ended"][sl] = {"printed": False}
            else:
                self.s["holds"].setdefault(sl, {})
        if all(c["shortLink"] in self.s["swept"] for c in cards if c["list"] not in ("DONE", "VERIFY") and not is_status(c)):
            self.s["holds_complete"] = True
            self.s["swept"] = []
            self.events.append(f"HOLDS KNOWN: {len(self.s['holds'])} open")

    def sync_holds(self, cards):
        """Release holds (rules.md, Releasing), on a slow check: fill in each hold's name and list from the board
        read; end a hold whose card was archived or moved to MERGED or DONE (HOLD ENDED: once); print HOLD ENDED:
        for each hold a RESOLVED: closed, again on every slow check while the card (no PR, no member) is outside
        DONE, and drop it from the state once it is in DONE or archived."""
        by_sl = {c["shortLink"]: c for c in cards}
        for sl in list(self.s["holds"]):
            c = by_sl.get(sl)
            if c is None:
                name = self.s["holds"].pop(sl).get("name", "?")
                self.events.append(f'HOLD ENDED: "{name}" [{sl}]: archived')
            elif c["list"] in ("MERGED", "DONE", "VERIFY"):
                del self.s["holds"][sl]
                self.events.append(f'HOLD ENDED: "{c["name"]}" [{sl}]: moved to {c["list"]}')
            else:
                self.s["holds"][sl] = {"name": c["name"], "list": c["list"]}
        for sl in list(self.s["ended"]):
            c = by_sl.get(sl)
            e = self.s["ended"][sl]
            if c is None or c["list"] in ("DONE", "VERIFY"):
                if not e.get("printed"):
                    name = c["name"] if c else "?"
                    self.events.append(f'HOLD ENDED: "{name}" [{sl}]: RESOLVED:')
                del self.s["ended"][sl]
                continue
            if e.get("printed") and (c.get("idMembers") or list(open_prs(c.get("desc")))):
                del self.s["ended"][sl]          # a card with a member or a PR is not moved by an agent: no reprint
                continue
            self.events.append(f'HOLD ENDED: "{c["name"]}" [{sl}]: RESOLVED:')
            e["printed"] = True

    def release_fix_links(self, cards):
        """The shortLinks the release status card's RELEASE FIX: comments since its newest PROMOTING: name."""
        rel = next((c for c in cards if is_release_card(c)), None)
        texts = self.card_texts(rel) if rel else None
        links = set()
        for t, _ in texts or []:
            if t.startswith("PROMOTING:"):
                break
            if t.startswith("RELEASE FIX:"):
                links.update(re.findall(r"trello\.com/c/([A-Za-z0-9]{8})", t))
        return links

    def wait_text(self, b):
        """The text of a Blocked card's newest WAITS FOR: comment: the kept one, else from card_texts (cached and
        counted with the slow check's other card reads), kept for the next check; "" when none or the read failed."""
        sl = b["shortLink"]
        if self.s["waittext"].get(sl):
            return self.s["waittext"][sl]
        texts = self.card_texts(b)
        for t, _ in texts or []:                       # newest first
            if t.startswith("WAITS FOR:"):
                self.s["waittext"][sl] = t
                return t
        return ""

    def not_urgent(self, cards):
        """NOT URGENT: (rules.md, Card titles and labels): a card in TODO, WORKFLOW 🤖, BUILDING, TESTING, REVIEW
        or MERGING that is not 🚨 but holds the release (an open RELEASE BLOCKER:, unless its newest status is a
        WAITS FOR: you: a manual step), is named by the newest WAITS FOR: of 2 or more other cards, or is named by
        the release status card's newest RELEASE FIX:. Never a status card, an [AGENTS] card (only the user's
        word makes a workflow change urgent), a card with a member, a card that lost its 🚨 or one that has an
        URGENT ADDED: comment. Once per card and reason."""
        lists = ("TODO", "WORKFLOW", "BUILDING", "TESTING", "REVIEW", "MERGING")
        cand = [c for c in cards if c["list"] in lists and not c["name"].startswith("🚨") and not is_status(c)
                and not is_agents(c) and not c.get("idMembers") and c["shortLink"] not in self.s["dropped"]]
        if not cand:
            return
        block = self.s["block"]
        waiting = [c for c in cards if block.get(c["shortLink"]) == "wait" and c["list"] not in ("DONE", "VERIFY") and not c["name"].startswith("⛔")]
        texts = {}
        for b in waiting:
            texts[b["shortLink"]] = self.wait_text(b)
        fixes = self.release_fix_links(cards)
        for c in cand:
            sl = c["shortLink"]
            why = None
            n = sum(1 for b in waiting if b["shortLink"] != sl and wait_names(texts[b["shortLink"]], c))
            if sl in self.s["holds"] and block.get(sl) != "you":
                why = "it holds the release (RELEASE BLOCKER:)"
            elif sl in fixes:
                why = "the release status card's RELEASE FIX: names it"
            elif n >= 2:
                why = f"the newest WAITS FOR: of {n} other cards names it"
            if why is None:
                continue
            key = f"notu:{sl}:{why[:12]}"
            if key in self.s["marks"]:
                continue
            seen = self.card_texts(c)
            if seen is None:
                continue
            if any(t.startswith("URGENT ADDED:") for t, _ in seen):
                self.s["marks"][key] = time.time()       # added once already, and the user took it off: stays silent
                continue
            self.once(key, f'NOT URGENT: "{c["name"]}" [{sl}] ({c["list"]}): {why}')

    def urgent_since(self, c):
        """When a 🚨 card became urgent: its URGENT ADDED: comment's time, else its creation."""
        sl = c["shortLink"]
        if sl not in self.s["added"]:
            texts = self.card_texts(c)
            if texts is None:
                return card_created(c)
            dates = self.dates_cache.get(sl) or [""] * len(texts)
            self.s["added"][sl] = next((parse_ts(dates[i]) for i, (t, _) in enumerate(texts) if t.startswith("URGENT ADDED:")), 0)
        return max(card_created(c) or 0, self.s["added"][sl]) or None

    def startable(self, cards):
        """TODO cards an agent could take now: not Blocked, person-owned, [AGENTS], a status card or a non-agent
        title tag."""
        return [c for c in cards if c["list"] == "TODO" and BLOCKED not in c["idLabels"]
                and not c["idMembers"] and not is_agents(c) and not is_status(c)
                and not is_tagged(c)]

    def answered_waiting(self, cards):
        """Cards in QUESTIONS the user answered that wait for a card test server (board-watcher.md steps 5 and
        11): not Blocked, no member, not a status card, with an ANSWERED: comment newer than the card's newest
        BLOCKED: (a later ROUTED: or other status cannot hide it). A failed read leaves the card out."""
        out = []
        for c in cards:
            if c["list"] != "QUESTIONS" or BLOCKED in c["idLabels"] or c["idMembers"] or is_status(c):
                continue
            texts = self.card_texts(c)
            if not texts:
                continue
            a = next((i for i, (t, _) in enumerate(texts) if t.startswith("ANSWERED:")), None)
            b = next((i for i, (t, _) in enumerate(texts) if t.startswith("BLOCKED:")), None)
            if a is not None and (b is None or a < b):      # texts are newest first
                out.append(c)
        return out

    def is_returning(self, c):
        """A TODO card with a BEFORE: comment is back from REVIEW, MERGING, a pause or an unblock. Read once
        per card (a failed read counts as new, as before) and kept while the card stays in TODO."""
        ret = self.s.setdefault("returning", {})
        sl = c["shortLink"]
        if sl not in ret:
            texts = self.card_texts(c)
            if texts is None:
                return False
            if not any(t.startswith("BEFORE:") for t, _ in texts):
                ret[sl] = False
            else:
                bfv = self.back_from_verify(c, texts)
                if bfv is None:                  # the move read failed: not cached, read again on the next pass
                    return False
                ret[sl] = not bfv
        return ret[sl]

    RETURN_MARKERS = ("CHANGES REQUESTED:", "CHECK FAILED:", "CODE REVIEW NEEDED:", "REVERTED:", "PAUSED:", "UNBLOCKED:")

    def back_from_verify(self, c, texts):  # True / False, or None when the move read failed (never cached)
        """A card a tester moved VERIFY -> TODO (or one with a NOT VERIFIED: newer than every other returning marker)
        is a NEW card for pickup: its BEFORE run reproduces the tester's report (rules.md, VERIFY). Independent of the
        order of comments: the watcher's NOT VERIFIED: may not be posted yet when the card is first read."""
        dates = self.dates_cache.get(c["shortLink"]) or [""] * len(texts)
        marker = ""                              # the date of the newest other returning marker
        for (t, _), dt in zip(texts, dates):     # newest first
            if t.startswith("NOT VERIFIED:"):
                return True
            if t.startswith(self.RETURN_MARKERS):
                marker = dt
                break
        try:
            moves = trello(f"cards/{c['shortLink']}/actions", filter="updateCard:idList", limit=50, fields="data,date")
        except Exception as e:  # noqa: BLE001 (noted; the card counts as not from VERIFY, read again once it leaves TODO)
            warn(f"Trello move read of {c['shortLink']} failed: {e}")
            return None
        moves = sorted(moves, key=lambda a: a.get("date", ""), reverse=True)
        for a in moves:
            d = a.get("data") or {}
            if list_kind((d.get("listAfter") or {}).get("name", "")) == "TODO":
                # a CHANGES REQUESTED: and the like, newer than the move, is the card's own return
                return list_kind((d.get("listBefore") or {}).get("name", "")) == "VERIFY" and not (marker and marker > a.get("date", ""))
        return False

    def sync_queue_label(self, cards, queued):
        """Waiting for shared resource: on exactly the cards in `queued`, off every other card. A Blocked,
        person-owned or status card is never in the set (a status card is left alone)."""
        for c in cards:
            if is_status(c):
                continue
            want = c["shortLink"] in queued and BLOCKED not in c["idLabels"] and not c["idMembers"]
            self.set_label(c, WAITRES, want)

    def start(self, cards):
        out = run([CARD_TEST_SERVER, "list"]) or ""
        if not out.strip():
            return  # the list failed (noted by run): change nothing this poll
        free = [l for l in out.splitlines() if l.split()[1:2] == ["free"] and "reserved" not in l and "kept" not in l]
        # The promoter's borrow-promoter reserved a busy server for itself: its card must be paused
        # (board-watcher.md step 10). Told once per change, again every START_REPEAT seconds while no pause file exists.
        todo_pause = []
        for l in out.splitlines():
            w = l.split()
            if len(w) >= 5 and w[1] != "free" and w[2:5] == ["(reserved", "for", "promoter)"] \
                    and not os.path.exists(os.path.join(PAUSE_DIR, w[1])):
                todo_pause.append(f"{w[1]} on {w[0]}")
        if todo_pause:
            psig = "|".join(todo_pause)
            plast = self.s.get("promoter_pause") or {}
            pnow = time.time()
            if plast.get("sig") != psig or pnow - plast.get("at", 0) >= START_REPEAT:
                self.s["promoter_pause"] = {"sig": psig, "at": pnow}
                self.events.append("PAUSE FOR PROMOTER: " + "; ".join(todo_pause)
                                   + " (reserved for the promoter's culprit search: pause it, board-watcher.md step 10)")
        else:
            self.s.pop("promoter_pause", None)
        in_todo = {c["shortLink"] for c in cards if c["list"] == "TODO"}
        for k in [k for k in self.s.get("returning", {}) if k not in in_todo]:
            del self.s["returning"][k]       # the card left TODO: read it again if it comes back
        # exit 7 (the BUILDING order unreadable) is also a failed read: no label change, no wants this poll
        wout = run_ok([CARD_TEST_SERVER, "waiting", "--order", building_order(cards)])      # None: the read failed, which is not "nobody waits"
        want_lines = [l.split() for l in (wout or "").splitlines() if l.split()]
        wants = [w[0] for w in want_lines]
        urgent_wants = [w[0] for w in want_lines if w[1:2] == ["urgent"]]
        ready = by_position(self.startable(cards))     # List order: 🚨 first, then list position
        # A returning card (it has a BEFORE: comment) needs builders first, not a server: it is started
        # whether or not a server is free. Only a new card waits for a server.
        returning = [c for c in ready if self.is_returning(c)]
        new = [c for c in ready if c not in returning] if wout is not None else []     # a failed `waiting` read: no new card is named this poll
        # Answered cards waiting in QUESTIONS for a server rank with the new cards: 🚨 first, then the answered
        # normal cards, then the normal TODO cards (board-watcher.md step 11, item 2a).
        answered = by_position(self.answered_waiting(cards)) if wout is not None else []
        answered_ids = {c["shortLink"] for c in answered}
        new = (by_position([c for c in new + answered if is_urgent(c)])
               + [c for c in answered if not is_urgent(c)] + [c for c in new if not is_urgent(c)])
        # Free servers are kept for the cards waiting for their AFTER run (card-test-server.sh priority).
        # A free server reserved for a new card in TODO (the card paused for the promoter's culprit search,
        # card-test-server.sh release promoter) counts as free for that card alone: `assign` gives it to it.
        new_ids = {c["shortLink"] for c in new}
        kept_for_new = []
        for l in out.splitlines():
            w = l.split()
            if len(w) >= 5 and w[1] == "free" and w[2:4] == ["(reserved", "for"] \
                    and w[-1].rstrip(")") in new_ids:
                kept_for_new.append(w[-1].rstrip(")"))
        spare = len(free) - len(wants)
        # A 🚨 new card ranks ahead of every normal card waiting for its AFTER run (only a 🚨 card waiting for
        # its AFTER run is ahead of it), so a free server is not kept from it for the normal ones.
        urgent_new = [c for c in new if c["name"].startswith("🚨")]
        urgent_first = urgent_new if len(free) - len(urgent_wants) > 0 else []
        # The one decision of which new cards START: names; the label below and the START: part both use it.
        named_new = new if spare > 0 else [c for c in new if c in urgent_first or c["shortLink"] in kept_for_new]
        # The disk hold (rules.md, Settings: Disk space): while the disk is critical no new BEFORE run starts, so a
        # new non-🚨 card with no server reserved for it is not named (card-test-server.sh assign refuses it too).
        # It keeps the Waiting for shared resource label below, like any card queueing for a server.
        if (self.s.get("disk") or {}).get("level") == "critical":
            named_new = [c for c in named_new if is_urgent(c) or c["shortLink"] in kept_for_new]
        # The release UI hold (rules.md, Settings: Release UI run) holds no start: a run's first emulator use waits
        # (card-test-server.sh release-hold wait). Only the hold file and its lines are kept here.
        self.hold_sync()
        # The label "Waiting for shared resource" (rules.md, Labels): the want cards (in BUILDING) and the new
        # startable cards START: does not name. It is written before START: may return, and not at all when a
        # read failed. Nothing reads the label back.
        if wout is not None:
            in_building = {c["shortLink"] for c in cards if c["list"] == "BUILDING"}
            queued = set(wants) & in_building
            queued |= {c["shortLink"] for c in new} - {c["shortLink"] for c in named_new}
            self.sync_queue_label(cards, queued)
        # Every server busy and a 🚨 new card waiting with no server reserved for it: it pre-empts at once
        # (board-watcher.md step 10), on the pass it is seen.
        reserved_for = {m.group(1) for m in re.finditer(r"\(reserved for (\w+)\)", out)}
        preempt = [c for c in urgent_new if not free and c["shortLink"] not in reserved_for]
        # "pre-empt now" is printed once per 🚨 card and server state: when every server holds a 🚨 card,
        # a reservation or a borrowed holding, preempt exits 4 and the same line would come back every wake.
        state = "|".join(sorted(l for l in out.splitlines() if l.strip()))
        # Drop the records of a card that left TODO and of an earlier server state: a state that comes back
        # later for the same card is news again, and the records do not pile up in the state file.
        live = {f"preempt:{c['shortLink']}:{state}" for c in urgent_new}
        for k in [k for k in self.s["marks"] if k.startswith("preempt:") and k not in live]:
            del self.s["marks"][k]
        fresh = []
        for c in preempt:
            key = f"preempt:{c['shortLink']}:{state}"
            if key not in self.s["marks"]:
                self.s["marks"][key] = time.time()
                fresh.append(c)
        preempt = fresh
        parts = []
        if returning:
            parts.append(f"TODO has {len(returning)} returning card{'s' if len(returning) > 1 else ''} "
                         f"({', '.join(c['shortLink'] for c in returning)}), no test server needed")
        start_wants = list(wants)
        if free and start_wants:
            parts.append(f"BUILDING has {len(start_wants)} card{'s' if len(start_wants) > 1 else ''} waiting for their AFTER run ({', '.join(start_wants)})")
        named_todo = [c for c in named_new if c["shortLink"] not in answered_ids]
        named_ans = [c for c in named_new if c["shortLink"] in answered_ids]
        if named_todo:
            parts.insert(0, f"TODO has {len(named_todo)} startable card{'s' if len(named_todo) > 1 else ''} "
                            f"({', '.join(c['shortLink'] for c in named_todo)})"
                            + (f"; a server is kept for {', '.join(kept_for_new)}" if kept_for_new else ""))
        if named_ans:
            parts.insert(0, f"QUESTIONS has {len(named_ans)} answered card{'s' if len(named_ans) > 1 else ''} waiting for a server "
                            f"({', '.join(c['shortLink'] for c in named_ans)}): step 11 item 2a")
        pre_todo = [c for c in preempt if c["shortLink"] not in answered_ids]
        pre_ans = [c for c in preempt if c["shortLink"] in answered_ids]
        if pre_todo:
            parts.append(f"TODO has {len(pre_todo)} 🚨 card{'s' if len(pre_todo) > 1 else ''} "
                         f"({', '.join(c['shortLink'] for c in pre_todo)}) and no free test server: pre-empt now")
        if pre_ans:
            parts.append(f"QUESTIONS has {len(pre_ans)} answered 🚨 card{'s' if len(pre_ans) > 1 else ''} "
                         f"({', '.join(c['shortLink'] for c in pre_ans)}) and no free test server: pre-empt now")
        if not parts:
            self.s.pop("start", None)    # nothing to start now: the next time there is, it is news again
            return
        sig = f"{len(free)}|{'|'.join(parts)}"  # the kept-for names are in parts
        last = self.s.get("start") or {}
        now = time.time()
        # Printed at once when it changes, and again every START_REPEAT seconds while it holds (a watcher
        # that skipped "take a card" after a compaction is told again), never in a tight loop.
        if last.get("sig") != sig or now - last.get("at", 0) >= START_REPEAT:
            self.s["start"] = {"sig": sig, "at": now}
            self.events.append(f"START: {len(free)} free card test server{'s' if len(free) != 1 else ''}; " + "; ".join(parts))

    # --- the Mac's disk (rules.md, Settings: Disk space) ------------------------------
    def disk_free(self):
        """(free GB, percent used) of DISK_PATH, or None (noted on stderr) when it cannot be read."""
        try:
            u = shutil.disk_usage(DISK_PATH)
        except OSError as e:
            warn(f"disk read failed: {e}")
            return None
        free = float(DISK_FREE_OVERRIDE) if DISK_FREE_OVERRIDE else u.free / 1e9
        return free, (100.0 * (u.total - free * 1e9) / u.total if u.total else 0.0)

    def du_gb(self, path, budget):
        """Size in GB of a folder (du -sk), or None after the per-folder timeout or when the budget of this
        calculation is spent (printed as `?`). budget is a one-item list of seconds left."""
        if budget[0] <= 0:
            return None
        t0 = time.time()
        try:
            p = subprocess.run([DU, "-sk", path], capture_output=True, text=True, timeout=min(DU_EACH, budget[0]))
            kb = int(p.stdout.split()[0]) if p.returncode == 0 and p.stdout.split() else None
        except (OSError, subprocess.TimeoutExpired, ValueError):
            kb = None
        budget[0] -= time.time() - t0
        return None if kb is None else kb * 1024 / 1e9      # decimal GB, like the free space

    def git_ok(self, args):
        """Output of a git command, or None when it failed or timed out."""
        try:
            p = subprocess.run(["git"] + args, capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired):
            return None
        return p.stdout if p.returncode == 0 else None

    def card_archived(self, sl):
        """True when Trello knows the card and it is archived. Results are kept in the state file; a failed
        lookup, or a card that is not archived, is never a yes (nothing is removed on a doubt)."""
        cache = self.s["disk"].setdefault("archived", {})
        if sl in self.lookup_failed:
            return False                        # failed once in this process: not asked again for every worktree
        if sl not in cache:
            try:
                c = trello(f"cards/{sl}", fields="closed")
            except Exception as e:  # noqa: BLE001 (a failed lookup keeps the folder)
                warn(f"card lookup {sl} failed: {type(e).__name__}: {e}")
                self.lookup_failed.add(sl)      # in memory only: a new board-wait.sh process asks again
                return False
            cache[sl] = bool(isinstance(c, dict) and c.get("closed") is True)
        return cache[sl]

    def worktree_candidates(self, cards):
        """The card worktrees that may be removed, largest first: [(size GB or None, repo, path)]. All of these hold
        (rules.md, Test servers: remove your worktrees once the card leaves WORKFLOW 🤖, BUILDING and TESTING):
        the folder is <agent type>-<shortLink>; the card is found, open in a list other than those three, or
        archived; no live agent works on it (unreadable agent rows: unknown, None); `git status --porcelain` is empty;
        `git branch -r --contains HEAD` names a remote branch (attached or detached alike). Stops looking when
        less than SLOW_MARGIN is left before LIMIT. A path printed before and still a candidate is a failed
        removal: kept in the state file with its HEAD sha, not printed again until it is gone, its HEAD changes or
        DISK_FAILED_TTL passes."""
        d = self.s["disk"]
        failed = d.setdefault("failed", {})
        printed = d.setdefault("printed", {})
        if self.rows is None:
            return None                         # unknown: the agent rows could not be read
        live = {c for r in self.rows if r["state"] in ALIVE for c in r["cards"] if c != "-"}
        by_sl = {c["shortLink"]: c for c in cards}
        found = []
        for repo in WORKTREE_REPOS:
            root = os.path.join(repo, ".claude/worktrees")
            try:
                names = sorted(os.listdir(root))
            except OSError:
                continue
            for name in names:
                m = WORKTREE_NAME.match(name)
                path = os.path.join(root, name)
                if not m or not os.path.isdir(path):
                    continue
                if time.time() - self.t0 > LIMIT - SLOW_MARGIN:
                    return None                 # unknown: the scan was cut short, the rest waits for the next slow check
                sl = m.group(2)
                card = by_sl.get(sl)
                if card is not None:
                    if card["list"] in KEEP_LISTS:
                        continue
                elif not self.card_archived(sl):
                    continue
                if sl in live:
                    continue
                st = self.git_ok(["-C", path, "status", "--porcelain"])
                if st is None or st.strip():
                    continue
                br = self.git_ok(["-C", path, "branch", "-r", "--contains", "HEAD"])
                if br is None or not br.strip():
                    continue
                found.append((repo, path))
        # a failed removal: printed before and still here. Each entry holds the time and the HEAD sha it was
        # marked at; it ends when the folder is gone, when HEAD has changed (the worktree is a different state
        # now) or after DISK_FAILED_TTL seconds (the cause may be gone), and the path is offered again.
        now = time.time()
        for k in list(failed):
            e = failed[k]
            if not isinstance(e, dict):
                e = failed[k] = {"t": float(e) if isinstance(e, (int, float)) else now, "head": None}
            if not os.path.isdir(k) or now - e.get("t", now) >= DISK_FAILED_TTL:
                del failed[k]
            elif e.get("head") != (self.git_ok(["-C", k, "rev-parse", "HEAD"]) or "").strip():
                del failed[k]
        # (until the first removal run has passed attended, worktree-clean.ok, a printed path may only be waiting)
        if os.path.exists(CLEAN_OK):
            for repo, path in found:
                if path in printed and path not in failed:
                    failed[path] = {"t": now, "head": (self.git_ok(["-C", path, "rev-parse", "HEAD"]) or "").strip()}
        found = [(r, p) for r, p in found if p not in failed]
        d["printed"] = {}
        budget = [DU_BUDGET]
        sized = [(self.du_gb(p, budget), r, p) for r, p in found]
        sized.sort(key=lambda x: (x[0] is None, -(x[0] or 0)))
        return sized[:MAX_REMOVE_LINES]

    def remove_lines(self, cands, record=True):
        """The DISK REMOVE: lines. record=True notes each path as printed: call it only where the lines are
        emitted (a path noted but never printed would later count as a failed removal)."""
        if record:
            for size, repo, path in cands:
                self.s["disk"]["printed"][path] = time.time()
        return [f"DISK REMOVE: {'?' if size is None else format(size, '.1f')} GB: git -C {repo} worktree remove {path}"
                for size, repo, path in cands]

    def folder_list(self):
        """The five largest of the places the disk goes to, for the nothing-removable line."""
        budget = [DU_BUDGET]
        places = list(DISK_FOLDERS)
        for repo in WORKTREE_REPOS:
            places.append(os.path.join(repo, ".claude/worktrees"))
        sized = [(self.du_gb(p, budget), p) for p in places if os.path.exists(p)]
        sized.sort(key=lambda x: (x[0] is None, -(x[0] or 0)))
        return ", ".join(f"{p} {'?' if g is None else format(g, '.1f')} GB" for g, p in sized[:5]) or "nothing found"

    def set_hold(self, free, on):
        # run_ok warns when the command fails; the hold's maximum age bounds a failed clear
        run_ok([CARD_TEST_SERVER, "disk-hold", "set", f"{int(free)}"] if on else [CARD_TEST_SERVER, "disk-hold", "clear"])

    def disk(self, cards, manual=False):
        """The disk check, on the slow check only. Its own state key (stuck() drops entries not seen in the
        current poll, and fast polls sit between slow ones). With free space fine it does only the disk_usage
        call (plus the hourly routine); the candidates and sizes are worked out only when a line is due."""
        d = self.s.setdefault("disk", {})
        d.setdefault("level", "ok")
        d.setdefault("routine_at", time.time())
        now = time.time()
        if manual:
            cands = self.worktree_candidates(cards)
            return None if cands is None else self.remove_lines(cands)
        got = self.disk_free()
        if got is None:
            return                              # read again at the next slow check
        free, pct = got
        level = "critical" if free < DISK_FLOOR else "low" if free < DISK_LOW else "ok"
        prev = d["level"]
        d["level"] = level
        if level == "critical":
            self.set_hold(free, True)           # refreshed on every slow check: the file has a maximum age
        elif prev == "critical":
            self.set_hold(free, False)          # the hold ends at the floor, not at DISK OK:
        head = f"{free:.0f} GB free ({pct:.0f}% used)"
        routine_due = now - d["routine_at"] >= DISK_ROUTINE
        if level == "ok":
            if prev != "ok":
                self.events.append(f"DISK OK: {free:.0f} GB free")
                for key in ("since", "sent", "free_sent", "nothing_sent", "k"):   # since/nothing_sent: old state files
                    d.pop(key, None)
            if routine_due:
                d["routine_at"] = now
                cands = self.worktree_candidates(cards)
                if cands is None:
                    return                      # unknown: nothing changes, the next slow check tries again
                self.events += self.remove_lines(cands)
            return
        # free_sent is shared by DISK CRITICAL: and the nothing-removable DISK LOW: line: either one holds back the
        # other until free space falls by the STEP (the user was told already); it resets at DISK OK:
        fs = d.get("free_sent")
        step_due = fs is None or free <= fs - DISK_STEP
        crit_due = level == "critical" and step_due
        repeat_due = now - d.get("sent", 0) >= DISK_REPEAT
        # Work out the candidates only when a line could come out of it: a critical line, the hourly routine, the
        # repeat while the last calculation found candidates, or a fall of the STEP while it found none.
        k = d.get("k")
        if not (crit_due or routine_due or (k != 0 and repeat_due) or (k == 0 and step_due)):
            return
        cands = self.worktree_candidates(cards)
        if cands is None:
            return                              # unknown (rows unreadable, scan cut short): say and change nothing
        d["routine_at"] = now
        d["k"] = len(cands)
        lines = self.remove_lines(cands, record=False)
        if cands:
            total = sum(c[0] or 0 for c in cands)
            if crit_due:
                self.events.append(f"DISK CRITICAL: {head}; the main session must act; no new BEFORE runs")
                d["free_sent"] = free
                d["sent"] = now
                self.events += lines
                self.remove_lines(cands)
            elif repeat_due:
                if level == "low":              # the critical level said its line once: only the lines repeat
                    self.events.append(f"DISK LOW: {head}; {len(cands)} removable worktrees (~{total:.1f} GB): run the DISK REMOVE: lines")
                d["sent"] = now
                self.events += lines
                self.remove_lines(cands)
            elif routine_due:
                self.events += lines
                self.remove_lines(cands)
        else:
            if step_due:
                rest = self.folder_list()
                if level == "critical":
                    self.events.append(f"DISK CRITICAL: {head}; the main session must act; no new BEFORE runs; nothing removable (the rest is: {rest})")
                else:
                    self.events.append(f"DISK LOW: {head}; nothing removable (the rest is: {rest})")
                d["free_sent"] = free
                d["sent"] = now

    # --- the stuck-card check ------------------------------------------------------
    def stuck_line(self, key, line, grace=None, repeat=None):
        """Printed when the condition (this call) has held for the grace, and again every STUCK_REPEAT
        seconds while it lasts."""
        now = time.time()
        rec = self.s["stuck"].setdefault(key, {"since": now})
        rec["seen"] = now
        if now - rec["since"] >= (STUCK_GRACE if grace is None else grace) and now - rec.get("sent", 0) >= (STUCK_REPEAT if repeat is None else repeat):
            rec["sent"] = now
            self.events.append(line)

    def resume_line(self, cards):
        """RESUME: (a usage limit is over). self.s["limits"] holds each agent that died on a limit (agents()). An entry
        is dropped once a replacement of its type is alive (on its card; anywhere for the merger and the promoter), its
        work is gone (only after its reset), or its card left the board. While some entry's reset has passed, the line comes back (stuck_line
        semantics, no grace) until its agents are alive again, so what the watcher's cap of starts per pass left out
        is named again. An entry whose reset has not passed (a per-model limit while another model runs) is kept."""
        lim = self.s["limits"]
        for aid, e in list(lim.items()):
            wide = e["type"] in self.BOARD_WIDE
            gone = e["card"] != "-" and e["card"] not in self.bysl
            # no work drops an entry only after its reset: before it the type-keyed hold (limit_active) must stay
            nowork = e["reset"] <= time.time() and not self.has_work(e["type"], e["card"], cards)
            if gone or self.alive_of(e["type"], None if wide else e["card"]) or nowork:
                del lim[aid]
        ready = [(aid, e) for aid, e in lim.items() if e["reset"] <= time.time()]
        if ready:
            names = ", ".join(f"{e['type']} card={e['card']} id={aid}" for aid, e in ready)
            self.stuck_line("resume", f"RESUME: usage limit over; restart: {names}", grace=0)

    def stuck(self, cards):
        if self.rows is None:
            return
        now = time.time()
        live_cards = {c for r in self.rows if r["state"] in ALIVE for c in r["cards"] if c != "-"}
        merger_alive = any(r["type"] == "merger" and r["state"] in ALIVE for r in self.rows)
        promoter_alive = any(r["type"] == "promoter" and r["state"] in ALIVE for r in self.rows)
        builder_alive = any(r["type"] in ("android-builder", "ios-builder") and r["state"] in ALIVE for r in self.rows)
        wout = run_ok([CARD_TEST_SERVER, "waiting", "--order", building_order(cards)])
        wants = {l.split()[0] for l in (wout or "").splitlines() if l.split()}
        top = self.top(cards)      # a lower MERGING card's conflict fix is gated (rules.md, List order)
        names = {c["shortLink"]: c for c in cards}
        before = set(self.s["stuck"])
        nolive = []
        for c in cards:
            sl, tag = c["shortLink"], f'"{c["name"]}" [{c["shortLink"]}] ({c["list"]})'
            if is_status(c) or c["idMembers"] or BLOCKED in c["idLabels"] or YELLOW in c["idLabels"]:
                continue
            if c["list"] in ("BUILDING", "TESTING") and not is_agents(c) and sl not in live_cards and sl not in wants \
                    and wout is not None:     # a failed `waiting` call: no stuck line from an empty want list
                self.stuck_line(f"nolive:{sl}", f"STUCK: {tag}: no agent is working on it")
                nolive.append(sl)
            if c["list"] == "MERGING" and is_agents(c) and ORANGE not in c["idLabels"]:
                # An [AGENTS] card waits for VERIFIED: with no verifier alive (the orange card's wake is DEADLINE:
                # workflow work waiting). A conflicting PR needs the merger to mark it first (MERGE CONFLICT: and the
                # orange label, then the workflow builder's conflict fix, then a verifier on the fixed head).
                for u in self.s["unverified"].get(sl, []):
                    if u.get("conflicting"):
                        if not merger_alive and not self.limit_active("merger"):
                            self.stuck_line(f"noverifier:{sl}:{u['head']}", f"STUCK: {tag}: [AGENTS] PR {u['pr']} @ {u['head']} has no VERIFIED:, "
                                            "conflicts with main and no merger is alive; start the merger (it marks MERGE CONFLICT:, then the workflow "
                                            "builder fixes it, then a verifier runs on the fixed head)")
                    elif not self.limit_active("workflow-verifier") and top is not None and top["shortLink"] == sl and \
                            not any(r["type"] == "workflow-verifier" and r["state"] in ALIVE and sl in r["cards"] for r in self.rows):
                        self.stuck_line(f"noverifier:{sl}:{u['head']}", f"STUCK: {tag}: [AGENTS] PR {u['pr']} @ {u['head']} has no VERIFIED: "
                                        "and no workflow verifier is alive; start the workflow verifier")
            if c["list"] == "MERGING" and ORANGE in c["idLabels"] and not is_agents(c) and sl not in live_cards \
                    and top is not None and top["shortLink"] == sl:
                self.stuck_line(f"noconflictfix:{sl}", f"STUCK: {tag}: its merge conflict or refresh has no fix running")
            if c["list"] == "MERGING" and self.s["ready"].get(sl) and not merger_alive and ORANGE not in c["idLabels"]:
                self.stuck_line(f"nomerger:{sl}", f"STUCK: {tag}: ready to merge and no merger is alive")
        for c in cards:
            if c["list"] in ("MERGING", "REVIEW") and not is_status(c) and not c["idMembers"] \
                    and not (BLOCKED in c["idLabels"] or ORANGE in c["idLabels"] or YELLOW in c["idLabels"]):
                if self.s["reviewwait"].get(c["shortLink"]):
                    why = ("newest status is REVIEW: and the user approved every PR on GitHub, nothing has picked it up"
                           if c["list"] == "MERGING" else
                           "every PR passes the review policy (approved on GitHub or no review needed), nothing has picked it up")
                    self.stuck_line(f"reviewwait:{c['shortLink']}", f'STUCK: "{c["name"]}" [{c["shortLink"]}] ({c["list"]}): {why}')
                if self.s["reviewchg"].get(c["shortLink"]):
                    self.stuck_line(f"reviewchg:{c['shortLink']}", f'STUCK: "{c["name"]}" [{c["shortLink"]}] ({c["list"]}): '
                                    "the user requested changes on GitHub, nothing has picked it up")
        self.s["nolive"] = nolive              # read by has_work() (the re-armed AGENT: dead and RESUME:)
        self.resume_line(cards)
        # The release in progress (RELEASING holds cards besides the release status card): its status card carries the
        # steps. Blocked (a manual step, the green* sign-off) is waiting, not stalled.
        rel = next((c for c in cards if is_release_card(c)), None)
        if in_release(cards):
            if rel is None:
                self.stuck_line("norelcard", 'STUCK: RELEASING holds cards but no release status card ("🚀 RELEASE: …") is at its top; the promoter or the board watcher creates it')
            elif not rel["idMembers"] and BLOCKED not in rel["idLabels"] and YELLOW not in rel["idLabels"] \
                    and not release_failed(rel) \
                    and not (self.release_state(cards) or {}).get("state", "").startswith("waiting: release hold"):
                # A failed release keeps its cards in RELEASING and waits for its fix card (RELEASE FIX:): not stalled
                # (a joinable fix is the RELEASE FIX READY: line, release_fix() below).
                rsl, tag = rel["shortLink"], f'"{rel["name"]}" [{rel["shortLink"]}] (RELEASING)'
                if rsl in self.s["uploaded"] and not promoter_alive:
                    self.stuck_line(f"uploaded:{rsl}", f"STUCK: {tag}: both uploads exist ({self.s['uploaded'][rsl]}) and no promoter is alive")
                elif not promoter_alive and not builder_alive:
                    # Any other stalled release: its cards are still in RELEASING (a failed release sends them back
                    # to MERGED) and neither the promoter nor an app builder is alive. Which agent carries it on depends
                    # on the release's newest step (self.missing_builders).
                    who = self.s["builders"].get(rsl)
                    step = f"start the {who} app builder" if who else "start the promoter"
                    self.stuck_line(f"stalled:{rsl}", f"STUCK: {tag}: the release has stalled: no promoter and no app builder is alive; {step}")
        # A failed release (release_fix() stored what it read at the last slow check): the culprit search of a first run
        # with no promoter alive, and a fix that is joinable while no promoter is alive (a lost RELEASE FIX READY: line).
        if rel is not None and release_failed(rel) and in_release(cards) and not promoter_alive \
                and not rel["idMembers"] and BLOCKED not in rel["idLabels"] and YELLOW not in rel["idLabels"]:
            rc = self.s.get("relcheck", {}).get(rel["shortLink"]) or {}
            tag = f'"{rel["name"]}" [{rel["shortLink"]}] (RELEASING)'
            if rc.get("search"):
                self.stuck_line(f"relsearch:{rel['shortLink']}:{rc['search']}",
                                f"STUCK: {tag}: the failed release's culprit search has no promoter alive and no RELEASE SEARCH ENDED: line; start the promoter")
            if rc.get("ready"):
                self.stuck_line(f"relfixstuck:{rel['shortLink']}:{rc['ready']}",
                                f"STUCK: {tag}: every fix is joinable and no promoter is alive; start the promoter")
        # a live agent quiet for IDLE seconds with no live child and no background command
        for r in self.rows:
            if r["state"] in ALIVE and r["type"] != "board-watcher" and r["last"] >= IDLE and r["children"] == 0 \
                    and "background_task" not in r["line"]:
                c = names.get(r["card"])
                tag = f'"{c["name"]}" [{r["card"]}] ({c["list"]})' if c else f'"-" [{r["card"]}] (no card)'
                self.stuck_line(f"idle:{r['id']}", f"STUCK: {tag}: {r['type']} id={r['id']} has written nothing for {r['last'] // 60} minutes", grace=0)
        # a card that waits on another card or an outside event (purple label) is skipped until what it waits on is done
        if self.slow:
            done = {c["name"]: c for c in cards if c["list"] in ("MERGED", "DONE", "VERIFY")}
            for c in cards:
                if NOACTION in c["idLabels"] and BLOCKED in c["idLabels"] and not c["name"].startswith("⛔"):
                    waits = self.waits_for(c)
                    hit = [d for d in done.values() if wait_names(waits, d)]
                    if hit:
                        self.stuck_line(f"waitdone:{c['shortLink']}", f'STUCK: "{c["name"]}" [{c["shortLink"]}] ({c["list"]}): '
                                        f'what it waits for is done ("{hit[0]["name"]}" is in {hit[0]["list"]}) and nothing has picked it up')
        for k in before:
            if self.s["stuck"][k].get("seen", 0) < now - 1:
                self.s["stuck"].pop(k, None)    # the condition ended: the next time is news again

    # --- stuck system resources (slow check, no agent turn) ---------------------
    # --- the main checkout follows origin/main (slow check, no agent turn) ---------
    def main_git(self, *args):
        """CompletedProcess of `git -C <main checkout> ...`; None (noted) when it cannot run."""
        try:
            return subprocess.run(["git", "-C", MAIN_REPO, *args], capture_output=True, text=True, timeout=RESOURCE_BUDGET)
        except (OSError, subprocess.TimeoutExpired) as e:
            warn(f"git {args[0]} in the main checkout failed: {e}")
            return None

    def main_checkout(self):
        """Fast-forward the main checkout to origin/main (rules.md, Stuck resources): never a reset, rebase or stash.
        A hold file stops it (STUCK: ... held, once per new origin/main sha); a commit ahead of HEAD with the line
        `Main checkout: hold` writes the hold file before anything is merged (its sha goes into main_hold_done once its
        hold is written, so a cleared hold never comes back); a refused fast-forward is reported when the same reason
        holds on two checks MAIN_CONFIRM apart, then every REARM seconds. A failed fetch is noted and tried again."""
        if not MAIN_FF:
            return
        mc = self.s.setdefault("maincheckout", {})
        f = self.main_git("fetch", "-q", "origin", "main")
        if f is None or f.returncode != 0:
            warn(f"main checkout: fetch failed: {(f.stderr if f else '').strip()[:200]}")
            return
        head, org = self.main_git("rev-parse", "HEAD"), self.main_git("rev-parse", "origin/main")
        if not head or not org or head.returncode or org.returncode:
            warn("main checkout: cannot read HEAD or origin/main")
            return
        head, org = head.stdout.strip(), org.stdout.strip()
        anc = self.main_git("merge-base", "--is-ancestor", org, head)
        if head == org or (anc is not None and anc.returncode == 0):
            mc.pop("fail", None)
            return
        short, now = org[:7], time.time()
        if os.path.exists(MAIN_HOLD):
            if mc.get("announced") != org:
                mc["announced"] = org
                try:
                    reason = open(MAIN_HOLD).readline().strip() or "held"
                except OSError:
                    reason = "held"
                self.events.append(f"STUCK: main checkout held ({reason}): origin/main {short} not live")
            return
        log = self.main_git("log", "--reverse", "--format=%H%x00%B%x1e", "HEAD..origin/main")
        done = mc.setdefault("main_hold_done", [])
        if log is not None and log.returncode == 0:
            for rec in log.stdout.split("\x1e"):
                sha, _, body = rec.strip("\n").partition("\x00")
                if not sha or sha in done:
                    continue
                line = next((ln.strip() for ln in body.splitlines() if MAIN_TRAILER.match(ln.strip())), None)
                if line is None:
                    continue
                try:
                    os.makedirs(os.path.dirname(MAIN_HOLD), exist_ok=True)
                    with open(MAIN_HOLD, "w") as fh:
                        fh.write(f"held for {sha[:7]}: {line}\n")
                except OSError as e:
                    warn(f"main checkout: cannot write the hold file: {e}")
                    return
                done.append(sha)
                del done[:-50]
                mc["announced"] = org
                self.events.append(f"STUCK: main checkout held (held for {sha[:7]}: {line}): origin/main {short} not live")
                return
        br = self.main_git("symbolic-ref", "--short", "-q", "HEAD")
        branch = br.stdout.strip() if br is not None else ""
        if branch != "main":
            reason = f"the checkout is on {'branch ' + branch if branch else 'a detached HEAD'}, not main"
        else:
            m = self.main_git("merge", "--ff-only", "origin/main")
            if m is not None and m.returncode == 0:
                mc.pop("fail", None)
                mc.pop("announced", None)
                r = run_ok([WATCHER_RELOAD, "check"]) if os.path.exists(WATCHER_RELOAD) else None
                line = (r or "").strip().splitlines()[0] if r and r.strip() else ""
                if line.startswith(("INPLACE:", "RESTART:")):
                    self.events.append(f"MAIN CHECKOUT: fast-forwarded to {short}; watcher-reload: {line}")
                return
            if m is None:
                reason = "git did not run"
            else:
                out = (m.stderr or m.stdout).strip().splitlines() or ["merge failed"]
                # git names the files on the indented lines after its first line: keep the first 3
                reason = " ".join([out[0].rstrip(":") + ":"] + [ln.strip() for ln in out[1:] if ln.startswith(("\t", " "))][:3]).rstrip(":")
        fail = mc.get("fail")
        if not fail or fail.get("reason") != reason:
            fail = mc["fail"] = {"reason": reason, "since": now}
        if now - fail["since"] >= MAIN_CONFIRM and now - fail.get("printed", 0) >= REARM:
            fail["printed"] = now
            self.events.append(f"STUCK: main checkout cannot fast-forward to origin/main ({short}): {reason}; agents and hooks read stale files")

    def script_lines(self, script, *args, gate=None):
        """The stdout lines of a resource script run with a time budget; [] (noted) when it fails. `gate` names the
        env override that skips the settings test (tests); without it the script must be in the user's allow entry."""
        if gate is not None and not os.environ.get(gate):
            try:
                with open(USER_SETTINGS) as f:
                    if os.path.basename(script) not in f.read():
                        return []                       # settings section 44 not applied: nothing is run
            except OSError:
                return []
        try:
            p = subprocess.run([script, *args], capture_output=True, text=True, timeout=RESOURCE_BUDGET)
        except (OSError, subprocess.TimeoutExpired) as e:
            warn(f"{os.path.basename(script)} failed: {e}")
            return []
        if p.returncode != 0:
            warn(f"{os.path.basename(script)} exited {p.returncode}")
            return []
        return [ln for ln in p.stdout.splitlines() if ln.strip()]

    def card_of_branch(self, repo, branch):
        """The card a CI run belongs to: its branch card/<shortLink>-… , or merger/<pr>-… (the card whose description
        names <repo>#<pr>); None when neither."""
        m = re.match(r"card/([A-Za-z0-9]{8})-", branch or "")
        if m:
            return self.bysl.get(m.group(1))
        m = re.match(r"merger/(\d+)-", branch or "")
        if m:
            for c in self.bysl.values():
                if (repo, int(m.group(1))) in set(open_prs(c.get("desc"))):
                    return c
        return None

    def resources(self, cards):
        """Stuck resources (rules.md, Stuck resources): held test servers (SERVER LOST:, from server-probe.sh), CI jobs
        queued while the hosts have room (ci-unstick.sh recovers each once; what it cannot is one STUCK: line naming
        the card), and Blocked cards whose automatic wait is over (WAIT OVER:, CHECK WAIT?:)."""
        for ln in self.script_lines(SERVER_PROBE, "scan", gate="BOARD_WAIT_SERVER_PROBE"):
            if ln.startswith("SERVER LOST:"):
                self.events.append(ln)
        for ln in self.script_lines(CI_UNSTICK, "scan"):
            if ln.startswith(("CI STUCK:", "CI QUEUED STUCK:")):
                m = re.match(r"CI (?:QUEUED )?STUCK: (\S+) run (\d+) branch (\S*): (.*)$", ln)
                if not m:
                    self.events.append(f"STUCK: {ln}")
                    continue
                repo, run_id, branch, rest = m.groups()
                c = self.card_of_branch(repo, branch)
                tag = f'"{c["name"]}" [{c["shortLink"]}] ({c["list"]})' if c else f"{repo} run {run_id}"
                self.events.append(f"STUCK: {tag}: CI is stuck: {rest}")
            elif ln.startswith("CI UNSTICK FAILED:"):
                self.events.append(f"STUCK: CI recovery is blind: {ln[len('CI UNSTICK FAILED:'):].strip()}")
        self.waits_over(cards)

    def unstick_pending(self, repo, n=None, run_id=None):
        """True while ci-unstick.sh is recovering the PR's (or the run's) CI: a run it cancelled, or re-ran within the
        grace (ci-wait.sh reads the same state as RUNNING). Such a cancel is not the end of the wait."""
        slug = repo.replace("/", "_")
        try:
            names = [f for f in os.listdir(CI_UNSTICK_DIR) if f.startswith(slug + "-") and f.endswith(".state")]
        except OSError:
            return False
        head = None
        for f in names:
            st = {}
            try:
                for line in open(os.path.join(CI_UNSTICK_DIR, f)):
                    k, _, v = line.rstrip("\n").partition("=")
                    st[k] = v
            except OSError:
                continue
            if run_id is not None and str(st.get("run")) != str(run_id):
                continue
            if run_id is None and str(st.get("pr")) != str(n):
                continue
            if run_id is None and st.get("head_sha"):
                # A state of an older head of the PR is no recovery of the current checks (ci-unstick.sh
                # state-of-pr and ci-wait.sh match by head the same way). Read the head once per call;
                # an unreadable head keeps the match by PR number.
                if head is None:
                    try:
                        head = (json.loads(run(["gh", "pr", "view", str(n), "--repo", repo, "--json", "headRefOid"]) or "{}")
                                or {}).get("headRefOid") or ""
                    except ValueError:
                        head = ""
                if head and head != st.get("head_sha"):
                    continue
            if st.get("state") == "cancelled":
                return True
            if st.get("state") == "rerun" and time.time() - float(st.get("rerun_at") or 0) < CI_RERUN_GRACE:
                return True
        return False

    def checks_done(self, repo, n=None, run_id=None):
        """('GREEN'|'RED <names>', ...) when every check of the PR (or the run) has completed, any conclusion; None while
        something is pending, nothing is reported or the read failed."""
        if self.unstick_pending(repo, n=n, run_id=run_id):
            return None
        if run_id is not None:
            out = run(["gh", "run", "view", str(run_id), "--repo", repo, "--json", "status,conclusion,jobs"])
            try:
                r = json.loads(out) if out else None
            except ValueError:
                return None
            if not r or r.get("status") != "completed":
                return None
            if r.get("conclusion") == "success":
                return "GREEN"
            bad = [j["name"] for j in r.get("jobs", []) if j.get("conclusion") not in ("success", "skipped")]
            return "RED " + ", ".join(bad or [r.get("conclusion") or "unknown"])
        out = run(["gh", "pr", "checks", str(n), "--repo", repo, "--json", "name,bucket"])
        try:
            checks = json.loads(out) if out else None
        except ValueError:
            return None
        if not checks or any(c.get("bucket") == "pending" for c in checks):
            return None
        bad = [c["name"] for c in checks if c.get("bucket") in ("fail", "cancel")]
        return "RED " + ", ".join(bad) if bad else "GREEN"

    def waits_over(self, cards):
        """WAIT OVER: a Blocked card whose newest WAITS FOR: carries `Auto-check: ci <repo>#<n>` or `Auto-check: run
        <repo> <run id>` and whose checks all completed (any conclusion: the wait was for the end, not for green). Once
        per wait text and verdict. CHECK WAIT?: the same test for an older WAITS FOR: you that names a PR or run with
        the word CI and no Auto-check (a hint for the main session; the watcher posts nothing): once per wait text
        and verdict, then at most every CHECK_WAIT_REPEAT seconds while no newer WAITS FOR: comment."""
        now = time.time()
        for c in cards:
            if BLOCKED not in c["idLabels"] or c["name"].startswith("⛔") or c["list"] in ("DONE", "MERGED"):
                continue
            text = self.wait_text(c)
            if not text.startswith("WAITS FOR:"):
                continue
            tag = f'"{c["name"]}" [{c["shortLink"]}] ({c["list"]})'
            key = f"{c['shortLink']}:{hash_text(text)}"
            m = re.search(r"Auto-check:\s*ci\s+([\w.-]+/[\w.-]+)#(\d+)", text)
            r = re.search(r"Auto-check:\s*run\s+([\w.-]+/[\w.-]+)\s+(\d+)", text)
            if m or r:
                ref = f"{m.group(1)}#{m.group(2)}" if m else f"{r.group(1)} run {r.group(2)}"
                verdict = self.checks_done(m.group(1), n=m.group(2)) if m else self.checks_done(r.group(1), run_id=r.group(2))
                if verdict is not None:
                    # a release hold card (its comments include RELEASE BLOCKER:) ends with RESOLVED:, any other card with UNBLOCKED:
                    end = "RESOLVED:" if any(t.startswith("RELEASE BLOCKER:") for t, _ in (self.card_texts(c) or [])) else "UNBLOCKED:"
                    self.once(f"waitover:{key}:{verdict}", f"WAIT OVER: {tag}: {ref} checks completed ({verdict}); post {end}")
                continue
            if not re.search(r"\bCI\b", text):
                continue
            p = re.search(r"([\w.-]+/[\w.-]+)#(\d+)", text)
            u = re.search(r"github\.com/([\w.-]+/[\w.-]+)/actions/runs/(\d+)", text)
            if p:
                verdict, ref = self.checks_done(p.group(1), n=p.group(2)), f"{p.group(1)}#{p.group(2)}"
            elif u:
                verdict, ref = self.checks_done(u.group(1), run_id=u.group(2)), f"{u.group(1)} run {u.group(2)}"
            else:
                continue
            if verdict is None:
                continue
            mk = f"checkwait:{key}:{verdict}"
            t = self.s["marks"].get(mk)
            if t is None or now - t >= CHECK_WAIT_REPEAT:
                self.s["marks"][mk] = now
                self.events.append(f"CHECK WAIT?: {tag}: {ref} checks completed ({verdict}); its WAITS FOR: may be over, the main session confirms")

    # --- every BOARD_WAIT_SLOW seconds ------------------------------------------
    def github(self, cards):
        for c in cards:
            if c["list"] == "REVIEW" and YELLOW not in c["idLabels"]:
                self.review_list(c)
            elif c["list"] == "MERGING":
                self.review_wait(c)
            if c["list"] == "MERGING":
                self.s["ready"][c["shortLink"]] = self.merge_ready(c)
            if c["list"] == "RELEASING" and is_release_card(c) and BLOCKED not in c["idLabels"] and in_release(cards):
                self.missing_builders(c)
                up = self.both_uploaded(c)
                if up is None:
                    pass                                   # a failed read changes nothing
                elif up:
                    self.s["uploaded"][c["shortLink"]] = up
                else:
                    self.s["uploaded"].pop(c["shortLink"], None)
            if c["list"] == "RELEASING" and release_failed(c) and BLOCKED not in c["idLabels"] and in_release(cards):
                self.release_fix(c, cards)
            if c["list"] == "WORKFLOW" and is_agents(c) and BLOCKED not in c["idLabels"] \
                    and ORANGE not in c["idLabels"] and YELLOW not in c["idLabels"]:
                prs = list(open_prs(c.get("desc")))
                texts = self.card_texts(c) if prs else None
                if not prs:
                    self.s["unverified"].pop(c["shortLink"], None)
                if texts is not None:
                    # Waiting on the verifier: the newest AWAITING / sent-back comment is an AWAITING one. A head with
                    # no VERIFIED: or VERIFY SELF: is VERIFY: (once per head), as for a card in MERGING.
                    state = next((t for t, _ in texts if t.startswith(AWAITING + SEND_BACKS)), "")
                    # A plan comment newer than the card's newest AWAITING VERIFIED: (a design-change round, or a build the
                    # plan stopped after commits were pushed) means the plan is not agreed: no final verifier for a head yet.
                    plan_i = next((i for i, (t, _) in enumerate(texts) if t.startswith(PLAN_PHRASES)), None)
                    await_i = next((i for i, (t, _) in enumerate(texts) if t.startswith("AWAITING VERIFIED:")), None)
                    plan_newer = plan_i is not None and (await_i is None or plan_i < await_i)
                    unverified = []
                    if state.startswith(AWAITING) and not plan_newer:
                        for repo, n in prs:
                            head = (gh_pr(repo, n, "headRefOid") or {}).get("headRefOid")
                            if head and not any(re.match(rf"(VERIFIED|VERIFY SELF): {repo_re(repo)}#{n} @ {re.escape(head)}", t) for t, _ in texts):
                                self.once_until(f"verify:{c['shortLink']}:{repo}#{n}:{head}", f'VERIFY: "{c["name"]}" [{c["shortLink"]}] {repo}#{n} @ {head}',
                                                lambda: self.alive_of("workflow-verifier", c["shortLink"]),
                                                skip=self.limit_active("workflow-verifier"))
                                unverified.append({"pr": f"{repo}#{n}", "head": head, "conflicting": False})
                    if unverified:
                        self.s["unverified"][c["shortLink"]] = unverified
                    else:
                        self.s["unverified"].pop(c["shortLink"], None)
                    # Only a VERIFIED: newer than the newest send-back (VERIFY FAILED: and the like) counts.
                    cut = next((i for i, (t, _) in enumerate(texts) if t.startswith(SEND_BACKS)), len(texts))
                    heads = []
                    for repo, n in prs:
                        head = (gh_pr(repo, n, "headRefOid") or {}).get("headRefOid")
                        if not head or not any(re.match(rf"VERIFIED: {repo_re(repo)}#{n} @ {re.escape(head)}", t) for t, _ in texts[:cut]):
                            heads = []
                            break
                        heads.append(f"{repo}#{n} @ {head}")
                    if heads and not plan_newer:  # held back like VERIFY: while a plan comment is newer
                        self.once(f"verifiedcard:{c['shortLink']}:{'|'.join(heads)}",
                                  f'VERIFIED CARD: "{c["name"]}" [{c["shortLink"]}] (WORKFLOW 🤖): {", ".join(heads)}')
            if c["list"] == "WORKFLOW" and is_agents(c) and BLOCKED not in c["idLabels"] \
                    and ORANGE not in c["idLabels"] and YELLOW not in c["idLabels"]:
                self.plan_check(c)
            if c["list"] == "MERGING" and is_agents(c):
                prs = list(open_prs(c.get("desc")))
                if not prs:
                    self.s["unverified"].pop(c["shortLink"], None)
                    continue
                texts = self.card_texts(c)       # date-sorted, newest first; a failed read skips the card
                if texts is None:
                    continue
                unverified = []
                for repo, n in prs:
                    pr = gh_pr(repo, n, "headRefOid,mergeable") or {}
                    head = pr.get("headRefOid")
                    if not head:
                        continue
                    # The newest verdict for this head decides. VERIFIED: / VERIFY SELF: answer the verifier; so does a
                    # VERIFY FAILED: (the verifier is not started again on a failed head), which instead sends the card
                    # back: SENT BACK IN MERGING: once per head. A head an earlier VERIFIED: carries to (a conflict-only
                    # fix, "carried") needs no verifier; a NOT CARRIED: for the head cancels that, so VERIFY: once.
                    verdict = self.head_verdict(c, texts, repo, n, head)
                    if verdict is None:
                        # again every REARM seconds with no verifier alive, except on an orange card (its wake is
                        # DEADLINE: workflow work waiting: the head is about to change). Strictly top-down (rules.md,
                        # List order): a lower card gets no VERIFY: (first print included) and its mark is not used up.
                        top = self.top(cards)
                        self.once_until(f"verify:{c['shortLink']}:{repo}#{n}:{head}", f'VERIFY: "{c["name"]}" [{c["shortLink"]}] {repo}#{n} @ {head}',
                                        lambda: self.alive_of("workflow-verifier", c["shortLink"]),
                                        skip=ORANGE in c["idLabels"] or self.limit_active("workflow-verifier")
                                        or (top is not None and top["shortLink"] != c["shortLink"]))
                        # UNKNOWN (GitHub has not worked it out yet) counts as not conflicting
                        unverified.append({"pr": f"{repo}#{n}", "head": head, "conflicting": pr.get("mergeable") == "CONFLICTING"})
                    elif verdict == "failed":
                        self.once(f"sentback:{c['shortLink']}:{repo}#{n}:{head}",
                                  f'SENT BACK IN MERGING: "{c["name"]}" [{c["shortLink"]}] {repo}#{n} @ {head}')
                if unverified:
                    self.s["unverified"][c["shortLink"]] = unverified
                else:
                    self.s["unverified"].pop(c["shortLink"], None)
        in_review = {c["shortLink"] for c in cards if c["list"] in ("MERGING", "REVIEW")}
        for name in ("reviewwait", "reviewchg"):
            for k in [k for k in self.s[name] if k not in in_review]:
                del self.s[name][k]
        live_prs = {f"{repo}#{n}:" for c in cards if c["list"] in ("MERGING", "REVIEW") for repo, n in open_prs(c.get("desc"))}
        for k in [k for k in self.s["reviewpol"] if not any(k.startswith(p) for p in live_prs)]:
            del self.s["reviewpol"][k]
        for k in [k for k in self.s["ready"] if k not in {c["shortLink"] for c in cards if c["list"] == "MERGING"}]:
            del self.s["ready"][k]
        merging = {c["shortLink"] for c in cards if c["list"] == "MERGING"}
        for k in [k for k in self.s["carry"] if k.split("|")[0] not in merging]:
            del self.s["carry"][k]
        # stored verifier work goes with the card's place: an unverified head only counts in MERGING or WORKFLOW 🤖,
        # a plan only in WORKFLOW 🤖
        here = {c["shortLink"]: c["list"] for c in cards}
        for k in [k for k in self.s["unverified"] if here.get(k) not in ("MERGING", "WORKFLOW")]:
            del self.s["unverified"][k]
        for k in [k for k in self.s["planwait"] if here.get(k) != "WORKFLOW"]:
            del self.s["planwait"][k]
        active = {c["shortLink"] for c in cards if is_release_card(c) and in_release(cards)}
        for k in [k for k in self.s["builders"] if k not in active]:
            del self.s["builders"][k]
        for k in [k for k in self.s["uploaded"] if k not in active]:
            del self.s["uploaded"][k]

    def join_allowed(self):
        """Settings section 39 applied: the promoter's allow entry holds the range cherry-pick of an unmerged PR
        (the string only that entry has; the older entry's form is `cherry-pick -m 1 -x`). A missing file is 'no'."""
        try:
            with open(USER_SETTINGS) as f:
                return "cherry-pick -x <sha>" in f.read()
        except OSError:
            return False

    def fix_state(self, fix, waits):
        """The state token of a RELEASE FIX: card that the promoter could join now, or None. `MERGED` for a card
        in MERGED; `MERGING@<date of its MERGE READY:>` for a card in MERGING whose newest status comment is a
        MERGE READY: (READY_PHRASES + NOT_READY decide, so a newest REFRESHED:, CONFLICT RESOLVED:, REVIEW: or
        CHECK FAILED: is not joinable: it joins from MERGED), once the allow entry is applied, and with no
        RELEASE FIX WAITS: naming it newer than that MERGE READY:. A Blocked card is never joinable.
        `waits` maps a fix card's shortLink to the date of the newest RELEASE FIX WAITS: that names it."""
        if fix is None or BLOCKED in fix["idLabels"]:
            return None
        if fix["list"] == "MERGED":
            return "MERGED"
        if fix["list"] != "MERGING" or ORANGE in fix["idLabels"] or YELLOW in fix["idLabels"] or not self.join_allowed():
            return None
        texts = self.card_texts(fix)
        if texts is None:
            return None
        dates = self.dates_cache.get(fix["shortLink"]) or [""] * len(texts)
        i = newest_status_index(texts)
        if i is not None and texts[i][0].startswith("MERGE READY:") and waits.get(fix["shortLink"], "") < dates[i]:
            return f"MERGING@{dates[i]}"
        return None

    def release_fix(self, rel, cards):
        """A failed release (status card `🚀 RELEASE: failed`, its cards still in RELEASING) waits for the fix card its
        `RELEASE FIX: <card name and link>` comment (since its newest PROMOTING:) names. Once every named fix card is
        joinable (fix_state), one `RELEASE FIX READY:` line per fix card tells the board watcher to start the
        promoter, which adds the fix to the release branch and runs the release again. A later UNBLOCKED: or
        PROMOTING: on the status card, and a change of a fix card's state (MERGING to MERGED, a newer MERGE READY:),
        print them again. The same read stores what the stuck check needs (self.s["relcheck"][<status card>]):
        the culprit search's state and the fixes' tokens, so a lost line or a dead promoter shows as STUCK:."""
        texts = self.card_texts(rel)
        if texts is None:
            return
        dates = self.dates_cache.get(rel["shortLink"]) or [""] * len(texts)
        by_sl = {c["shortLink"]: c for c in cards}
        fixes = []                                          # the fix cards named since the newest PROMOTING:
        waits = {}                                          # fix shortLink -> date of the newest RELEASE FIX WAITS: naming it
        mark = None                                         # which UNBLOCKED:/PROMOTING: comment ends the wait (its place)
        failed_at = ended_at = fixed_at = None              # newest FULL SUITE FAILED:, RELEASE SEARCH ENDED:, RELEASE FIX: (dates)
        added = False                                       # the newest PROMOTING: has an Added: line (a run with a fix, not a first run)
        for i, (t, _) in enumerate(texts):                  # newest first
            if mark is None and t.startswith(("UNBLOCKED:", "PROMOTING:")):
                mark = dates[i]
            if t.startswith("PROMOTING:"):
                added = bool(re.search(r"^Added:", t, re.M))
                break
            if t.startswith("RELEASE FIX:"):
                m = re.search(r"trello\.com/c/([A-Za-z0-9]{8})", t)
                fixes.append(by_sl.get(m.group(1)) if m else None)
                fixed_at = fixed_at or dates[i]
            elif t.startswith("RELEASE FIX WAITS:"):
                m = re.search(r"trello\.com/c/([A-Za-z0-9]{8})", t)
                if m:
                    waits.setdefault(m.group(1), dates[i])
            elif t.startswith("RELEASE SEARCH ENDED:"):
                ended_at = ended_at or dates[i]
            elif t.startswith("FULL SUITE FAILED:"):
                failed_at = failed_at or dates[i]
        sl = rel["shortLink"]
        rc = self.s.setdefault("relcheck", {})
        # The culprit search of a first run: failed, a RELEASE FIX: after it, no RELEASE SEARCH ENDED: after it.
        search_open = bool(failed_at and not added and fixed_at and fixed_at >= failed_at and (not ended_at or ended_at < failed_at))
        states = [self.fix_state(f, waits) for f in fixes]
        ready = bool(fixes) and all(states)
        rc[sl] = {"search": failed_at if search_open else None,
                  "ready": f"{'+'.join(sorted(f['shortLink'] + '=' + st for f, st in zip(fixes, states)))}:{mark}" if ready else None}
        # Rerun only once every named fix card is joinable (a rerun with one fix missing is a known red run).
        if not ready:
            return
        for fix, st in zip(fixes, states):
            # The key holds the date of the newest UNBLOCKED:/PROMOTING: comment and the fix card's state, so a wait
            # that clears later (the user applies a settings section, the promoter posts UNBLOCKED:), the move from
            # MERGING to MERGED and a newer MERGE READY: each print the line again.
            self.once(f"relfix:{sl}:{'+'.join(sorted(f['shortLink'] for f in fixes))}:{fix['shortLink']}:{mark}:{st}",
                      f'RELEASE FIX READY: "{fix["name"]}" [{fix["shortLink"]}] is joinable ({"MERGED" if st == "MERGED" else "MERGING with MERGE READY:"}) '
                      f'and the failed release "{rel["name"]}" [{rel["shortLink"]}] waits for it: start the promoter')

    def missing_builders(self, c):
        """For the release status card: the app builders its release needs next, from the release's newest step
        (since its newest PROMOTING: comment). A platform needs its builder when staging is deployed with a
        client-build (not `client: unchanged`), the platform has no `UPLOADED:`, and
        either its `BUILT:` is missing or SMOKE PASSED is there (the upload follows). A `BUILD FAILED:` on
        either platform makes it a failed release, which is the promoter's: no builder is named. Any other step
        is the promoter's. Stored in self.s["builders"] as "android", "ios" or "android and ios"; absent otherwise."""
        texts = self.card_texts(c)
        if texts is None:
            return
        deployed = False
        seen = set()
        smoke = False
        for t, _ in texts:                                  # newest first
            if t.startswith("PROMOTING:"):
                break
            if t.startswith(("STAGING DEPLOYED:", "STAGING UNCHANGED")) and "client: unchanged" not in t:
                deployed = True
            for k in ("ANDROID", "IOS"):
                for w in ("BUILT", "UPLOADED", "BUILD FAILED"):
                    if t.startswith(f"{k} {w}:"):
                        seen.add((k, w))
            smoke = smoke or t.startswith("SMOKE PASSED")
        need = []
        failed = any(w == "BUILD FAILED" for _, w in seen)  # a failed release: the promoter's, never a builder's
        if deployed and not failed:
            for k in ("ANDROID", "IOS"):
                if (k, "UPLOADED") in seen:
                    continue
                if (k, "BUILT") not in seen or smoke:
                    need.append(k.lower())
        if need:
            self.s["builders"][c["shortLink"]] = " and ".join(need)
        else:
            self.s["builders"].pop(c["shortLink"], None)

    def both_uploaded(self, c):
        """For the release status card: since its newest PROMOTING: comment, both ANDROID UPLOADED: and
        IOS UPLOADED: exist. Returns what SMOKE shows ("no SMOKE comment", "SMOKE PASSED", "SMOKE FAILED"),
        "" when the uploads are not both there, None when the read failed. A release that stopped at this
        point (a promoter that ended, or was never started again) moves no further by itself."""
        texts = self.card_texts(c)
        if texts is None:
            return None
        android = ios = False
        smoke = "no SMOKE comment"
        for t, _ in texts:                                  # newest first
            if t.startswith("PROMOTING:"):
                break
            android = android or t.startswith("ANDROID UPLOADED:")
            ios = ios or t.startswith("IOS UPLOADED:")
            if smoke == "no SMOKE comment" and t.startswith(("SMOKE PASSED", "SMOKE FAILED")):
                smoke = t.split(":")[0].strip()
        return smoke if android and ios else ""

    def release_state(self, cards):
        """The release status card's state, from the card's release comments since its newest PROMOTING:, the
        cards RELEASING holds, its Blocked label and whether a promoter or an app builder is alive. None when the
        card, the agent rows or the card's comments cannot be read (nothing is decided then). Returned as a dict
        for release_card (the name and description) and update_release_hold (the hold)."""
        rel = next((c for c in cards if is_release_card(c)), None)
        if rel is None or self.rows is None:
            return None
        texts = self.card_texts(rel)
        if texts is None:
            return None
        covered = [c for c in cards if c["list"] == "RELEASING" and not is_status(c)]
        alive = any(r["type"] in ("promoter", "android-builder", "ios-builder") and r["state"] in ALIVE for r in self.rows)
        since = []                                          # this release's comments, newest first
        for t, user in texts:
            if t.startswith("PROMOTING:"):
                since.append((t, user))
                break
            since.append((t, user))
        started = bool(since) and since[-1][0].startswith("PROMOTING:")
        pair = since[-1][0].split(":", 1)[1].strip().splitlines()[0] if started else ""
        has = lambda *ph: any(t.startswith(ph) for t, _ in since)
        newest = next((t for t, _ in since if t.startswith(RELEASE_STEPS)), "")
        decision = next((t.strip().lstrip("\"*_ ").lower() for t, p in since if p and ANSWER.match(t.lower())), "")
        # A failure counts only when no later success step follows it (a non-code deploy or SMOKE failure is a
        # manual step; the release carries on once it is fixed). `since` is newest first.
        # A failure is cleared only by a success of the same step (one platform's success never hides the other's
        # failure); a failed full test is cleared by nothing.
        failure = ""
        done = []                                           # success steps newer than the comment being looked at
        for t, _ in since:
            if t.startswith(SUCCESS_STEPS):
                done.append(t)
                continue
            for fail, clears in FAILURE_CLEARED_BY:
                if t.startswith(fail) and not any(d.startswith(clears) for d in done):
                    failure = t
                    break
            if failure:
                break
        # Nothing in RELEASING yet: the promoter has posted PROMOTING: and not yet moved the first card (promoter.md
        # step 4); the release is over only once a closing step follows the pin.
        finished = has("BETA PROMOTED", "BETA PROMOTE FAILED") or any(t.startswith("STAGING") and "client: unchanged" in t for t, _ in since)
        if not covered:
            if started and (failure or decision.startswith("hold")):
                state = "failed"
            elif started and not finished:
                state = "running: full test" if alive else "stalled: no promoter (full test)"
            else:
                state = "released" if started else "idle"
        elif started and (failure or decision.startswith("hold")) and has("RELEASE FIX:"):
            # A failed release keeps its cards in RELEASING and waits for its fix card (promoter.md, Failed release,
            # step 4): the promoter's RELEASE FIX: comment marks it. Blocked (a WAITS FOR:) does not hide it.
            state = "failed"
        elif BLOCKED in rel["idLabels"]:
            gstar = newest.startswith("GREEN*") and not decision.startswith("ship")
            state = "waiting: sign-off" if gstar else "waiting: you (a manual step)"
        else:
            if not started or newest.startswith(("PROMOTING:", "FULL SUITE VOID")):
                step = "full test" if not has("FULL SUITE VOID") else "full test (rerun)"
            elif newest.startswith(("FULL SUITE GREEN", "GREEN*")):
                step = "staging deploy"
            elif newest.startswith("STAGING") and "client: unchanged" in newest:
                step = "finishing the release"
            elif newest.startswith("STAGING PUSH"):
                step = "staging deploy"
            elif newest.startswith(("STAGING", "ANDROID BUILT", "IOS BUILT")):
                step = "app builds"
            elif newest.startswith("SMOKE PASSED"):
                step = "uploads"
            elif newest.startswith(("ANDROID UPLOADED", "IOS UPLOADED")):
                step = "uploads"
            elif newest.startswith("BETA"):
                step = "finishing the release"
            else:
                step = "in progress"
            if newest.startswith("GREEN*") and decision.startswith("ship"):
                step = "staging deploy"
            if failure:
                step = "failing: the promoter files the 🚨 card"
            state = f"running: {step}" if alive else f"stalled: no promoter ({step})"
            if not alive and newest.startswith("FULL SUITE HELD:") and self.s.get("holds"):
                # FULL SUITE HELD: the promoter ended on purpose after a second host loss (promoter.md, step 8): the
                # release waits for its hold (rules.md, Releasing, the host form of kind 2), it has not stalled.
                hold = next(iter(self.s["holds"].values())).get("name", "?")
                state = f"waiting: release hold ({hold})"
        return {"rel": rel, "state": state, "pair": pair, "failure": failure, "newest": newest, "covered": covered}

    def update_release_hold(self, cards):
        """The release UI hold (rules.md, Settings: Release UI run): on only while the release's full test runs
        (state `running: full test` or `running: full test (rerun)`). Decided on slow checks and kept in the state
        file; start() reads it on every poll and does no Trello read. A read that failed keeps the earlier
        decision for at most RELEASE_HOLD_MAX_AGE seconds (see hold_on); a successful read that finds no release
        status card ends the hold."""
        h = self.s.setdefault("release_hold", {})
        if not any(is_release_card(c) for c in cards):
            h["on"] = False                                 # the board read worked and the card is gone
            h["decided_at"] = time.time()
            return
        info = self.release_state(cards)
        if info is None:
            return                                          # a failed read: keep the earlier decision (bounded)
        on = info["state"] in ("running: full test", "running: full test (rerun)")
        if on and not h.get("on"):
            h["episode"] = h.get("episode", 0) + 1
        h["on"] = on
        h["decided_at"] = time.time()
        h["card"] = info["rel"]["shortLink"]

    def hold_on(self):
        """Whether the release UI hold is on: decided on, and decided less than RELEASE_HOLD_MAX_AGE seconds ago
        (a read that keeps failing cannot hold the cards for ever)."""
        h = self.s.get("release_hold") or {}
        return bool(h.get("on")) and time.time() - h.get("decided_at", 0) < RELEASE_HOLD_MAX_AGE

    def hold_sync(self):
        """Per poll: keep the hold file fresh while the hold is on, remove it when it is over, and print
        RELEASE UI HOLD: / RELEASE UI HOLD ENDED: once per hold episode (never per pass)."""
        h = self.s.get("release_hold") or {}
        ep = h.get("episode", 0)
        if self.hold_on():
            run_ok([CARD_TEST_SERVER, "release-hold", "set", h.get("card") or "Release"])
            h["file"] = True
            self.once(f"ruh-{ep}-start", "RELEASE UI HOLD: the release's full test runs; card UI runs wait "
                      "before their first emulator use (API runs go on)")
        else:
            # The hold is over. When the 15-minute bound ended it, h["on"] is still True; clear it, so a hold that
            # resumes under the same state is a new episode (update_release_hold counts it) with its own lines.
            h["on"] = False
            if h.get("file"):
                run_ok([CARD_TEST_SERVER, "release-hold", "clear"])
                h["file"] = False
                if f"ruh-{ep}-start" in self.s["marks"]:
                    self.once(f"ruh-{ep}-end", "RELEASE UI HOLD ENDED: the release's full test is over; card UI runs go on")

    def release_card(self, cards):
        """Keep the release status card's name and description true (rules.md, The release status card). The
        state comes from release_state; nothing is written when the name and the description already say it. No
        agent keeps this card current."""
        if self.no_write:
            return
        info = self.release_state(cards)
        if info is None:
            return
        rel, state, pair, failure, newest, covered = (info[k] for k in ("rel", "state", "pair", "failure", "newest", "covered"))
        name = f"{RELEASE_CARD} {state}"
        lines = [f"**State:** {state}", f"**Pinned pair:** {pair or 'none yet'}"]
        if failure:
            lines.append(f"**Failure:** {failure.splitlines()[0][:200]}")
        if newest:
            lines.append(f"**Newest step:** {newest.splitlines()[0][:160]}")
        lines.append("**Covered cards:** " + ("; ".join(f"{c['name']} https://trello.com/c/{c['shortLink']}" for c in covered) or "none"))
        lines.append("")
        lines.append("Kept by board-wait.sh on every slow check. Agents only post the release comments; this name and description follow them.")
        if len(covered) > 15:
            lines[-3] = "**Covered cards:** " + "; ".join(f"{c['name']} https://trello.com/c/{c['shortLink']}" for c in covered[:15]) + f"; and {len(covered) - 15} more"
        desc = "\n".join(lines)
        if (rel["name"] == name and (rel.get("desc") or "") == desc) or self.sent_release == (name, desc):
            return
        try:
            trello(f"cards/{rel['id']}", "PUT", _body={"desc": desc}, name=name)
            self.sent_release = (name, desc)        # not sent again in this call; the card is read again on the next
        except urllib.error.HTTPError as e:
            warn(f"release card write refused: HTTP {e.code}")
            if e.code in (401, 403):
                self.no_write = True
        except Exception as e:  # noqa: BLE001 (noted; sent again on the next slow check)
            warn(f"release card write failed: {type(e).__name__}: {e}")

    def policy_pass(self, repo, n, pr, review_id):
        """True when review-policy.sh says NO REVIEW NEEDED or APPROVED for the PR, False on REVIEW NEEDED, None on
        an ERROR or a failed run. The answer is stored per head, newest review, PR body and policy file (the inputs the
        policy reads), so it runs again only when one changes; an ERROR is never stored."""
        script = REVIEW_POLICY
        try:
            with open(script, "rb") as f:
                sha = hashlib.sha1(f.read()).hexdigest()
        except OSError as e:
            warn(f"review policy {script} unreadable: {e}")
            return None
        key = f"{repo}#{n}:{pr.get('headRefOid')}:{review_id}:{hashlib.sha1((pr.get('body') or '').encode()).hexdigest()}:{sha}"
        if key in self.s["reviewpol"]:
            return self.s["reviewpol"][key]
        out = run(policy_command(script, f"{repo}#{n}"))
        line = (out or "").strip().splitlines()[:1]
        line = line[0] if line else ""
        if line.startswith(("NO REVIEW NEEDED:", "APPROVED:")):
            ok = True
        elif line.startswith("REVIEW NEEDED:"):
            ok = False
        else:
            warn(f"review policy on {repo}#{n}: {line or 'no output'}")
            return None
        self.s["reviewpol"] = {k: v for k, v in self.s["reviewpol"].items() if not k.startswith(f"{repo}#{n}:")}
        self.s["reviewpol"][key] = ok
        return ok

    def review_anchor(self, c):
        """The date of the card's newest comment with a line starting REVIEW: (None: the card has none, or the read failed)."""
        texts = self.card_texts(c)
        if texts is None:
            return None
        dates = self.dates_cache.get(c["shortLink"]) or []
        for i, (t, _) in enumerate(texts):
            if re.search(r"(?m)^REVIEW:", t):
                return parse_iso(dates[i]) if i < len(dates) else None
        return None

    def review_reads(self, c):
        """The user's newest review of each open PR of a card (REVIEW, or MERGING with REVIEW: newest): the
        REVIEW: event, once per review. Sets s["reviewchg"] for the card. Returns True when every open PR passes the
        review policy (approved on GitHub, also at an older head a merge of the base moved past, or no review
        needed), False when not, None when a GitHub read or the policy failed (the caller changes nothing)."""
        prs = list(open_prs(c.get("desc")))
        approved = bool(prs)
        chg = False
        anchor = None
        anchor_read = False
        for repo, n in prs:
            pr = gh_pr(repo, n, "headRefOid,reviews,body")
            if pr is None:
                return None
            # The states review-policy.sh counts: APPROVED, CHANGES_REQUESTED and DISMISSED
            mine = [r for r in pr.get("reviews", []) if (r.get("author") or {}).get("login") == USER_LOGIN
                    and r.get("state") in ("APPROVED", "CHANGES_REQUESTED", "DISMISSED")]
            newest = max(mine, key=lambda r: r.get("submittedAt", "")) if mine else None
            if newest and newest["state"] in ("APPROVED", "CHANGES_REQUESTED"):
                self.once(f"review:{repo}#{n}:{newest.get('id')}", f'REVIEW: "{c["name"]}" [{c["shortLink"]}] {repo}#{n} {newest["state"]}')
            if newest and newest["state"] == "CHANGES_REQUESTED":
                if not anchor_read:
                    anchor, anchor_read = self.review_anchor(c), True
                when = parse_iso(newest.get("submittedAt", ""))
                if anchor is None or (when is not None and when > anchor):
                    chg = True
            ok = self.policy_pass(repo, n, pr, newest.get("id") if newest else "")
            if ok is None:
                return None
            if not ok:
                approved = False
        self.s["reviewchg"][c["shortLink"]] = chg
        return approved

    def review_list(self, c):
        """A card in REVIEW: the REVIEW: event and the stored states read by stuck() (reviewwait, reviewchg)."""
        sl = c["shortLink"]
        if is_status(c) or c["name"].startswith("⛔") or c["idMembers"]:
            self.s["reviewwait"].pop(sl, None)
            self.s["reviewchg"].pop(sl, None)
            return
        texts = self.card_texts(c)
        if texts is None:
            return      # the comment read failed: keep reviewwait and reviewchg as they are, read again next time
        if any(t.startswith("INCLUDED IN:") for t, _ in texts):
            self.s["reviewwait"].pop(sl, None)
            self.s["reviewchg"].pop(sl, None)
            return
        approved = self.review_reads(c)
        if approved is not None:
            self.s["reviewwait"][sl] = approved

    def review_wait(self, c):
        """A card in MERGING whose newest status is REVIEW: (dragged in, or not moved back) waits on the user's GitHub
        approval like a card in REVIEW: the same event, and s["reviewwait"] (read by stuck()) for a missed one."""
        sl = c["shortLink"]
        if BLOCKED in c["idLabels"] or ORANGE in c["idLabels"] or YELLOW in c["idLabels"] or c["name"].startswith("⛔") or is_status(c):
            self.s["reviewwait"].pop(sl, None)
            self.s["reviewchg"].pop(sl, None)
            return
        texts = self.card_texts(c)
        if texts is None:
            return                                   # a failed read changes nothing
        i = newest_status_index(texts)
        newest = texts[i][0] if i is not None else ""
        if not newest.startswith("REVIEW:") or any(t.startswith("INCLUDED IN:") for t, _ in texts):
            self.s["reviewwait"].pop(sl, None)
            self.s["reviewchg"].pop(sl, None)
            return
        approved = self.review_reads(c)
        if approved is not None:
            self.s["reviewwait"][sl] = approved

    def merge_ready(self, c):
        """A card in MERGING that the merger could act on: its newest status comment is MERGE READY: or a
        resolution with no behavior change, nothing makes it wait (a DEPENDS ON: or WITH: comment, the
        Blocked, orange or yellow label), and an [AGENTS] card has a VERIFIED: for each PR."""
        if BLOCKED in c["idLabels"] or ORANGE in c["idLabels"] or YELLOW in c["idLabels"] or c["name"].startswith("⛔"):
            return False
        texts = self.card_texts(c)
        if texts is None:
            return self.s["ready"].get(c["shortLink"], False)   # a failed read changes nothing
        if any(t.startswith(("DEPENDS ON:", "WITH:", "INCLUDED IN:")) for t, _ in texts):
            return False
        i = newest_status_index(texts)
        newest = texts[i][0] if i is not None else ""
        if newest.startswith("CONFLICT RESOLVED:") and "no behavior change" not in newest:
            return False
        if newest.startswith("REFRESHED:") and "no behavior change" not in newest:
            return False
        if not newest.startswith(READY_PHRASES):
            return False
        if is_agents(c):
            for repo, n in open_prs(c.get("desc")):
                head = (gh_pr(repo, n, "headRefOid") or {}).get("headRefOid")
                # the newest VERIFIED: / VERIFY FAILED: naming this head decides; a VERIFY SELF: is no verdict; with
                # none, an earlier VERIFIED: carried through a conflict-only fix counts (carried())
                if not head or self.head_verdict(c, texts, repo, n, head, ("VERIFIED", "VERIFY FAILED")) not in ("verified", "carried"):
                    return False
        return True

    def deadlines(self, cards):
        now = time.time()
        for key, (what, every) in PERIODIC.items():
            if now - self.s["periodic"].get(key, now) >= every:
                self.s["periodic"][key] = now
                self.events.append(f"DEADLINE: {what}")
        for c in cards:
            made = card_created(c)
            if made and c["name"].startswith("🚨") and c["list"] in ("WORKFLOW", "TODO", "BUILDING") and now - made > DAY:
                made = self.urgent_since(c) or made     # a 🚨 added later counts from its URGENT ADDED: comment
            # The urgent fix deadline: rules.md's 24 hours, counted here from the card's
            # filing (or its URGENT ADDED: comment); the board watcher takes off the time in REVIEW, QUESTIONS and
            # Blocked on the user, so this first wake may come early. So it wakes
            # again every 2 hours while the card is in TODO or BUILDING with no REVERT:.
            # A 🚨 [AGENTS] card (a workflow change the user called urgent) has the same
            # deadline (rules.md, Card titles and labels), counted while it is in WORKFLOW 🤖
            # (or a stray in TODO or BUILDING); its PR reaching MERGING meets it.
            # It has nothing to revert: its wakes end on the board watcher's
            # `BLOCKED: urgent fix deadline passed: …` question (board-watcher.md step 8).
            if c["name"].startswith("🚨") and c["list"] in ("WORKFLOW", "TODO", "BUILDING") and made and now - made > DAY:
                key = f"urgent:{c['shortLink']}:{int((now - made - DAY) // 7200)}"
                if key not in self.s["marks"] and not self.deadline_handled(c):
                    self.once(key, f'DEADLINE: urgent fix deadline passed: "{c["name"]}" ({c["shortLink"]})')
            # A release due by age: a card in MERGED for more than a day (the promoter decides).
            if c["list"] == "MERGED" and BLOCKED not in c["idLabels"]:
                mark = f"merged:{c['shortLink']}"
                first = self.s["marks"].setdefault(f"seen-{mark}", now)
                if now - first > DAY:
                    self.once(mark, f'DEADLINE: release due by age: "{c["name"]}" ({c["shortLink"]})')
        # The gap between releases (rules.md, Settings): MERGED holds a card that is not Blocked and
        # RELEASING is empty, so a release may be due but held by the gap. release-gap.sh reads the
        # newest RELEASING -> DONE/MERGED move; once the gap has passed, one wake per release end
        # brings the board watcher back to the promoter start check (a quiet board has no other).
        if any(c["list"] == "MERGED" and BLOCKED not in c["idLabels"] for c in cards) \
                and not in_release(cards) \
                and now >= self.s["marks"].get("gap-check-after", 0):
            self.s["marks"]["gap-check-after"] = now + GAP_RECHECK
            line = (run_gap() or "").strip()
            m = re.match(r"GAP OVER: .*\(last end (\d{4}-\d\d-\d\d \d\d:\d\d UTC)\)", line)
            if m:
                self.once(f"gapover:{m.group(1)}", f"DEADLINE: release gap over: the last release ended {m.group(1)}")
        # Workflow work (board-watcher.md, the workflow builder): an [AGENTS] card in WORKFLOW 🤖
        # that is orphaned (no agent works on it, and no AWAITING VERIFIED: / VERIFIED: newer
        # than the last send-back: while it waits there for the verifier, it is no work for the
        # builder), an [AGENTS] conflict in MERGING, or a stray [AGENTS] card in TODO or BUILDING
        # (the board watcher moves it to WORKFLOW 🤖); none Blocked, and none a live workflow
        # builder works on (one builder per card or related batch, rules.md "Fresh context per
        # task": every card of a builder's batch is its, from the cards= of agent-state.sh; a
        # builder on another card holds back no card). Sent when it changes, and every 2 hours
        # while it waits.
        top = self.top(cards)
        wb_cards = {c for r in self.rows or [] if r["type"] == "workflow-builder" and r["state"] in ALIVE for c in r["cards"]}
        live_cards = {c for r in self.rows or [] if r["state"] in ALIVE for c in r["cards"]}
        work = [c for c in cards if is_agents(c) and BLOCKED not in c["idLabels"] and c["shortLink"] not in wb_cards
                and (c["list"] == "TODO" or (c["list"] in ("WORKFLOW", "BUILDING") and self.orphaned(c, live_cards))
                     or (c["list"] == "MERGING" and ORANGE in c["idLabels"]
                         and (top or {}).get("shortLink") == c["shortLink"]))]
        self.s["workflowwork"] = [c["shortLink"] for c in work]     # read by has_work(); empty when there is none
        if work:
            ids = ", ".join(c["shortLink"] for c in work)
            last = self.s["marks"].get("workflow-work", 0)
            if now - last >= 2 * 3600 or self.s["marks"].get("workflow-work-cards") != ids:
                self.s["marks"]["workflow-work"] = now
                self.s["marks"]["workflow-work-cards"] = ids
                self.events.append("DEADLINE: workflow work waiting: " + ids)
        free = [l for l in (run([CARD_TEST_SERVER, "list"]) or "").splitlines() if l.split()[1:2] == ["free"] and "kept" not in l]
        if (self.startable(cards) or self.answered_waiting(cards)) and not free:
            since = self.s["marks"].setdefault("todo-held-since", now)
            # Once per episode: until a server frees or TODO has nothing startable.
            if now - since >= 2 * 3600:
                self.once("todo-held", "DEADLINE: startable cards have waited 2 hours for a card test server")
        else:
            self.s["marks"].pop("todo-held-since", None)
            self.s["marks"].pop("todo-held", None)

    def plan_check(self, c):
        """VERIFY PLAN: (board-watcher.md, Workflow verifier): the card's newest plan comment is a PLAN:, at least
        PLAN_GRACE seconds old, and no workflow verifier is alive on the card (agent-state.sh gives a verifier the
        card of its prompt). Once per plan comment. A failed read changes nothing."""
        texts = self.card_texts(c)
        if texts is None or self.rows is None:
            return
        dates = self.dates_cache.get(c["shortLink"]) or []
        i = next((i for i, (t, _) in enumerate(texts) if t.startswith(PLAN_PHRASES)), None)
        if i is None or not texts[i][0].startswith("PLAN:") or i >= len(dates):
            self.s["planwait"].pop(c["shortLink"], None)     # a verdict (or no plan): the verifier has no plan to answer
            return
        try:
            age = time.time() - datetime.datetime.fromisoformat(dates[i].replace("Z", "+00:00")).timestamp()
        except ValueError:
            return
        if age < PLAN_GRACE:
            return
        m = re.match(r"PLAN: revision (\d+)", texts[i][0])
        self.s["planwait"][c["shortLink"]] = m.group(1) if m else "?"
        if self.alive_of("workflow-verifier", c["shortLink"]):
            return
        # again every REARM seconds while the plan stays unanswered and no verifier is alive
        self.once_until(f"verifyplan:{c['shortLink']}:{dates[i]}",
                        f'VERIFY PLAN: "{c["name"]}" [{c["shortLink"]}] plan revision {m.group(1) if m else "?"}',
                        lambda: self.alive_of("workflow-verifier", c["shortLink"]), skip=self.limit_active("workflow-verifier"))

    def orphaned(self, c, live_cards):
        """An [AGENTS] card in WORKFLOW 🤖 (or a stray in BUILDING) that no workflow builder is working on and that does not wait
        for the verifier (its newest AWAITING VERIFIED: / VERIFIED: / VERIFY SELF: comment is newer than
        any sent-back comment) or for its plan verdict (its newest plan comment is a PLAN: newer than any
        PLAN AGREED: / PLAN CHANGES: / send-back: rules.md, Plan first). A failed read counts as not orphaned: it is read again on the next check."""
        if YELLOW in c["idLabels"] or c["shortLink"] in live_cards:
            return False
        texts = self.card_texts(c)
        if texts is None:
            return False
        for t, _ in texts:
            if t.startswith(AWAITING):
                return False
            if t.startswith("PLAN:"):
                return False            # an unanswered plan waits for the verifier (VERIFY PLAN: wakes it)
            if t.startswith(("PLAN AGREED:", "PLAN CHANGES:")):
                return True             # a plan verdict is work for the builder
            if t.startswith(NOT_AWAITING):
                return True
        return True

    def worktrees_mode(self):
        """`board-wait.sh --worktrees`: the DISK REMOVE: lines for the current candidates, read only (no state
        written, no wake). Exit 1 when the board or the agents cannot be read."""
        try:
            lists = {l["id"]: l["name"] for l in trello(f"boards/{BOARD}/lists", filter="open", fields="name")}
            cards = trello(f"boards/{BOARD}/cards", filter="open", fields="name,idList,idLabels,idMembers,shortLink,desc")
        except Exception as e:  # noqa: BLE001
            warn(f"Trello read failed: {type(e).__name__}: {e}")
            return 1
        for c in cards:
            c["list"] = list_kind(lists.get(c["idList"], ""))
        out = run_ok([AGENT_STATE])
        if out is None:
            return 1
        self.rows = agent_rows(out)
        lines = self.disk(cards, manual=True)
        if lines is None:
            warn("worktree scan unknown: agent rows unreadable or the scan was cut short")
            return 1
        print("\n".join(lines))
        return 0

    def main(self):
        if sys.argv[1:] == ["--worktrees"]:
            return self.worktrees_mode()
        start = time.time()
        while True:
            with open(HEARTBEAT, "w") as f:
                f.write(f"{int(time.time())}\n")
            # Slow reads (GitHub, card comments) start only with time left before the limit.
            slow = time.time() - self.s["last_slow"] >= SLOW and time.time() - start < LIMIT - SLOW_MARGIN
            if slow:
                self.s["last_slow"] = time.time()
            self.poll(slow)
            if not self.events and time.time() - self.s["last_return"] >= 4 * 3600:
                self.events.append("SAFETY WAKE")
            if self.events:
                self.s["last_return"] = time.time()
                self.save()
                print("\n".join(self.events))
                return 0
            self.save()
            if time.time() - start + POLL > LIMIT:
                print("QUIET")
                return 3
            time.sleep(POLL)


def holds_mode():
    """board-wait.sh holds: the open release holds from the state file, no Trello call."""
    try:
        with open(STATE) as f:
            st = json.load(f)
    except (OSError, ValueError):
        print("HOLDS UNKNOWN")
        return 0
    holds = st.get("holds") or {}
    for sl, h in holds.items():
        print(f'HOLD: "{h.get("name", "?")}" [{sl}] ({h.get("list", "?")})')
    if not st.get("holds_complete", True):
        print("HOLDS UNKNOWN")
    elif not holds:
        print("NO HOLDS")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["holds"]:
        sys.exit(holds_mode())
    sys.exit(Wait().main())
