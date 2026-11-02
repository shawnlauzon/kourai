#!/usr/bin/env bash
# Tests .claude/bin/board-wait.sh (board-wait.py).
#
# Usage: .claude/bin/test-board-wait.sh
#
# Nothing real is touched: a local HTTP server on 127.0.0.1 stands in for
# Trello (it serves fixture files from a temporary folder), and gh,
# agent-state.sh and card-test-server.sh are fakes. aws, tailscale and ssh fail
# at once. About 30 seconds. Exits 0 when every case passes, 1 otherwise.
# shellcheck disable=SC2016 # the checks are single-quoted on purpose: ok() evals them
set -uo pipefail
export KOURAI_CONFIG=${KOURAI_CONFIG:-$(cd "$(dirname "$0")" && pwd)/fixtures/config.toml}
export KOURAI_BIN=${KOURAI_BIN:-$(cd "$(dirname "$0")/../bin" && pwd)}

root=$(cd "$(dirname "$0")/.." && pwd)
bin=$root/bin
tmp=$(mktemp -d)
server_pid=""
# shellcheck disable=SC2329 # called by the EXIT trap
cleanup() { if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null; wait "$server_pid" 2>/dev/null; fi; rm -rf "$tmp"; }
trap cleanup EXIT

mkdir -p "$tmp/nonet"
for c in aws tailscale ssh; do
  printf '#!/usr/bin/env bash\necho "test: %s is not allowed in tests" >&2\nexit 99\n' "$c" >"$tmp/nonet/$c"
  chmod +x "$tmp/nonet/$c"
done
export PATH="$tmp/nonet:$PATH"

failures=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; failures=$((failures + 1)); }
ok() { if eval "$2"; then pass "$1"; else fail "$1" "${3:-check failed: $2}"; fi; }
# gw, grn and gho read what writes, relname and holds_out print through a here-string, never a pipe
# into an early-exiting grep -q: under pipefail (and with SIGPIPE ignored, as in the agents' shells) the
# writer gets "Broken pipe" when grep stops at its first match, and the check comes out false although it matched.
gw() { local o; o=$(writes); grep "$@" <<<"$o"; }
grn() { local o; o=$(relname); grep "$@" <<<"$o"; }
gho() { local o; o=$(holds_out); grep "$@" <<<"$o"; }

# --- the fake Trello ---------------------------------------------------------------
www=$tmp/www && T=$www/1 && mkdir -p "$T/boards/AbCd1234" "$T/lists" "$T/cards"
port=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
# It serves <path> from $www, notes every per-card comment read in $tmp/reads.log, and notes every POST and DELETE in $tmp/writes.log; a request with before=<id> (a page of older board
# actions) gets <path>.before-<id> when that file exists; a board actions read of comments (filter with commentCard) with limit above 300 answers 429; release-gap.sh's move read (limit 1000) is not refused, as before (as the real board did, card xXtokNFg).
cat >"$tmp/fake-trello.py" <<'PY'
import http.server, os, sys, urllib.parse
root, port = sys.argv[1], int(sys.argv[2])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        f = os.path.join(root, u.path.lstrip("/"))
        before = urllib.parse.parse_qs(u.query).get("before", [""])[0]
        limit = int(urllib.parse.parse_qs(u.query).get("limit", ["0"])[0])
        if u.path.startswith("/1/boards/") and u.path.endswith("/actions") and limit > 300 and "commentCard" in urllib.parse.parse_qs(u.query).get("filter", [""])[0]:   # the real board's 429 (card xXtokNFg)
            self.send_error(429, "Too Many Requests"); return
        if before and os.path.isfile(f"{f}.before-{before}"):
            f = f"{f}.before-{before}"
        if os.path.isfile(f + ".moves-fail") and "updateCard" in urllib.parse.parse_qs(u.query).get("filter", [""])[0]:   # a failed move read
            self.send_error(500, "Server Error"); return
        if not os.path.isfile(f):
            self.send_error(404, "File not found"); return
        body = open(f, "rb").read()
        if u.path.startswith("/1/cards/") and u.path.endswith("/actions"):   # a per-card comment read: noted in reads.log
            with open(os.path.join(root, "..", "reads.log"), "a") as rl:
                rl.write(u.path.split("/")[3] + "\n")
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    def do_write(self):
        # a label write (POST .../idLabels value=<id>, DELETE .../idLabels/<id>): noted in <root>/../writes.log
        u = urllib.parse.urlparse(self.path)
        if os.path.exists(os.path.join(root, "..", "refuse-writes")):   # a read-only token
            body = b"{}"
            code = int(open(os.path.join(root, "..", "refuse-writes")).read().strip() or "403")
            self.send_response(code); self.send_header("Content-Length", str(len(body))); self.end_headers()
            self.wfile.write(body)
            return
        q = urllib.parse.parse_qs(u.query)
        value = q.get("value", [""])[0] or q.get("name", [""])[0]
        with open(os.path.join(root, "..", "writes.log"), "a") as f:
            f.write(f"{self.command} {u.path[len('/1'):]} {value}\n".rstrip() + "\n")
        body = b"{}"
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    do_POST = do_DELETE = do_PUT = do_write
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
python3 -I "$tmp/fake-trello.py" "$www" "$port" >/dev/null 2>&1 &
server_pid=$!
printf 'TRELLO_KEY=k\nTRELLO_TOKEN=t\n' >"$tmp/trello.env"
export TRELLO_ENV_FILE=$tmp/trello.env TRELLO_API_BASE=http://127.0.0.1:$port/1
up=false
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s "http://127.0.0.1:$port/" >/dev/null && { up=true; break; }; sleep 0.3; done
# release-gap.sh reads the fake Trello with the real curl: a curl that cannot reach it (a fake curl on
# PATH, a dead fake server) would fail the gap cases for a reason that is not board-wait's.
$up || { echo "test: curl cannot reach the fake Trello at 127.0.0.1:$port (a fake curl on PATH? the gap cases need the real one)" >&2; exit 1; }

CLAUDE=000000000000000000000002 USER=000000000000000000000001 BLOCKED=000000000000000000000022
lists() { # the board's lists
  cat >"$T/boards/AbCd1234/lists" <<'EOF'
[{"id":"lt","name":"TODO 📚"},{"id":"lw","name":"WORKFLOW 🤖"},{"id":"lb","name":"BUILDING"},{"id":"lr","name":"🙋‍♂️ REVIEW 👀"},
 {"id":"lm","name":"MERGING"},{"id":"ld","name":"MERGED"},{"id":"lx","name":"RELEASING 🚀"},{"id":"lz","name":"DONE! 🙌🏽"},{"id":"lv","name":"VERIFY 🔎"},{"id":"lq","name":"🙋‍♂️ QUESTIONS ❓"},{"id":"lp","name":"PROPOSED"}]
EOF
}
cards() { echo "$1" >"$T/boards/AbCd1234/cards"; }
actions() { echo "$1" >"$T/boards/AbCd1234/actions"; }
lists; cards '[]'; actions '[]'

# --- the other fakes -----------------------------------------------------------------
mkdir -p "$tmp/fakebin" "$tmp/gh"
cat >"$tmp/fakebin/gh" <<EOF
#!/usr/bin/env bash
# gh pr view <n> --repo <r> --json …: prints $tmp/gh/<r with / as _>-<n>.json
n=\$3 repo=""
for ((i = 1; i <= \$#; i++)); do [ "\${!i}" = --repo ] && { j=\$((i + 1)); repo=\${!j}; }; done
# gh pr checks <n> / gh run view <id>: prints $tmp/gh/checks-<r>-<n>.json / run-<r>-<id>.json (the WAIT OVER: cases)
case "\$1 \$2" in
  "pr checks") cat "$tmp/gh/checks-\${repo//\//_}-\$n.json" 2>/dev/null; exit 0 ;;
  "run view") cat "$tmp/gh/run-\${repo//\//_}-\$n.json" 2>/dev/null; exit 0 ;;
esac
cat "$tmp/gh/\${repo//\//_}-\$n.json"
EOF
# The resource scripts (settings section 44): fakes that print $tmp/server-probe.out / $tmp/ci-unstick.out; the env overrides also skip the settings test.
printf '#!/usr/bin/env bash\ncat %s/server-probe.out 2>/dev/null\nexit 0\n' "$tmp" >"$tmp/fakebin/server-probe"
printf '#!/usr/bin/env bash\ncat %s/ci-unstick.out 2>/dev/null\nexit 0\n' "$tmp" >"$tmp/fakebin/ci-unstick"
mkdir -p "$tmp/cistate"; export RC_CI_UNSTICK_DIR=$tmp/cistate
export BOARD_WAIT_SERVER_PROBE=$tmp/fakebin/server-probe BOARD_WAIT_CI_UNSTICK=$tmp/fakebin/ci-unstick
# The slow check fast-forwards the main checkout: never the real one. Section 13 turns it on against a fake repo.
export BOARD_WAIT_MAIN_FF=0 BOARD_WAIT_MAIN_HOLD=$tmp/main-hold
printf '#!/usr/bin/env bash\ncat %s/agents 2>/dev/null\n' "$tmp" >"$tmp/fakebin/agent-state"
printf '#!/usr/bin/env bash\nif [ "${1:-}" = release-hold ]; then if [ "${2:-}" = set ]; then echo "$3" >%s/hold-file; else rm -f %s/hold-file; fi; exit 0; fi\nif [ "${1:-}" = waiting ]; then echo "$*" >>%s/waiting-args; [ -e %s/waiting-fails ] && exit 1; cat %s/waiting 2>/dev/null; exit 0; fi\n[ -e %s/list-fails ] && exit 1\ncat %s/servers\n' "$tmp" "$tmp" "$tmp" "$tmp" "$tmp" "$tmp" "$tmp" >"$tmp/fakebin/card-test-server"
: >"$tmp/waiting"; : >"$tmp/agents"
# The review policy (RC_REVIEW_POLICY): prints $tmp/policy/<repo with / as _>-<n> when present, else REVIEW NEEDED; logs each call.
# Set before any case, so no case runs the real hook (it fetches into the real checkout).
mkdir -p "$tmp/policy"
cat >"$tmp/fakebin/review-policy" <<EOF
ref=\$2; repo=\${ref%#*}; n=\${ref##*#}
echo "\$ref" >>"$tmp/policy.log"
f="$tmp/policy/\${repo//\//_}-\$n"
if [ -f "\$f" ]; then cat "\$f"; else echo "REVIEW NEEDED: \$ref: fake"; fi
EOF
export RC_REVIEW_POLICY=$tmp/fakebin/review-policy
chmod +x "$tmp/fakebin/"*
export PATH="$tmp/fakebin:$PATH" BOARD_WAIT_AGENT_STATE=$tmp/fakebin/agent-state BOARD_WAIT_CARD_TEST_SERVER=$tmp/fakebin/card-test-server
printf 'test-server-1 Busy1111\ntest-server-2 Busy2222\ntest-server-3 Busy3333\n' >"$tmp/servers"

# Long grace and repeat times keep the stuck-card lines and START repeats out of the older cases; the
# cases for them set their own.
export BOARD_WAIT_STUCK_GRACE=100000 BOARD_WAIT_START_REPEAT=100000 BOARD_WAIT_STUCK_REPEAT=100000
export BOARD_WAIT_ACTIVE_DIR=$tmp/active ACTIVE_CARD_DIR=$tmp/active
# The disk check reads the real Mac unless told otherwise: sections 1-10 see plenty of free space and no worktrees.
export BOARD_WAIT_DISK_FREE_GB=100 BOARD_WAIT_WORKTREE_REPOS=$tmp/no-repos BOARD_WAIT_DISK_FOLDERS=$tmp/no-folders BOARD_WAIT_CLEAN_OK=$tmp/no-clean.ok
export BOARD_WAIT_STATE=$tmp/state.json BOARD_WAIT_HEARTBEAT=$tmp/heartbeat BOARD_WAIT_POLL=0.2 BOARD_WAIT_SLOW=0 BOARD_WAIT_SLOW_MARGIN=0
W=$bin/board-wait.sh
run() { local out=$1; shift; "$@" >"$out" 2>&1; echo $? >"$out.rc"; }
rc() { cat "$1.rc"; }
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000Z; }
now=$(date +%s)

# 1. First run: nothing to act on, QUIET within the limit, heartbeat and state written.
# A missing state file means the holds are not known; its sweep reads the board and says so once (HOLDS KNOWN:).
run "$tmp/o0" env BOARD_WAIT_LIMIT=2 "$W"
ok "holds: a first run with no state file ends its sweep with HOLDS KNOWN: 0 open, once" '[ "$(grep -c "^HOLDS KNOWN: 0 open$" "$tmp/o0")" = 1 ]' "rc=$(rc "$tmp/o0") $(cat "$tmp/o0")"
run "$tmp/o1" env BOARD_WAIT_LIMIT=1 "$W"
ok "quiet: nothing happens, QUIET (exit 3) within the limit" '[ "$(rc "$tmp/o1")" = 3 ] && grep -qx QUIET "$tmp/o1"' "rc=$(rc "$tmp/o1") $(cat "$tmp/o1")"
ok "quiet: heartbeat written" '[ -s "$tmp/heartbeat" ]'
ok "quiet: state file kept" 'python3 -I -c "import json,sys; json.load(open(sys.argv[1]))" "$tmp/state.json"'
ok "quiet: with plenty of free space (the disk settings pinned) no DISK line prints" '! grep -q "^DISK" "$tmp/o1"' "$(cat "$tmp/o1")"

# 2. A user comment after the cursor wakes it; a Claude comment doesn't.
later=$(iso $((now + 60)))
actions '[{"id":"a1","type":"commentCard","date":"'"$later"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"TEST PASSED: x","card":{"name":"Card A","shortLink":"CrdA1111"},"list":{"name":"BUILDING"}}},
          {"id":"a2","type":"commentCard","date":"'"$later"'","idMemberCreator":"'"$USER"'","data":{"text":"Please also check tablets","card":{"name":"Card A","shortLink":"CrdA1111"},"list":{"name":"BUILDING"}}}]'
run "$tmp/o2" env BOARD_WAIT_LIMIT=3 "$W"
ok "user: a user comment wakes it" '[ "$(rc "$tmp/o2")" = 0 ] && grep -qx "COMMENT (user): \"Card A\" \[CrdA1111\] (BUILDING): Please also check tablets" "$tmp/o2"' "rc=$(rc "$tmp/o2") $(cat "$tmp/o2")"
ok "user: the agent comment is not reported" '! grep -q "TEST PASSED" "$tmp/o2"'
run "$tmp/o3" env BOARD_WAIT_LIMIT=1 "$W"
ok "user: the same comment never wakes it twice" '[ "$(rc "$tmp/o3")" = 3 ]' "rc=$(rc "$tmp/o3") $(cat "$tmp/o3")"

# 3. The main session's USER REPLY (posted as Claude) and a user's move both count.
later2=$(iso $((now + 120)))
actions '[{"id":"a3","type":"commentCard","date":"'"$later2"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"USER REPLY: ship it","card":{"name":"Card B","shortLink":"CrdB1111"},"list":{"name":"MERGING"}}},
          {"id":"a4","type":"updateCard","date":"'"$later2"'","idMemberCreator":"'"$USER"'","data":{"card":{"name":"Card C","shortLink":"CrdC1111"},"listBefore":{"name":"🙋‍♂️ REVIEW 👀"},"listAfter":{"name":"TODO 📚"}}}]'
run "$tmp/o4" env BOARD_WAIT_LIMIT=3 "$W"
ok "user: USER REPLY wakes it" 'grep -qx "COMMENT (user): \"Card B\" \[CrdB1111\] (MERGING): USER REPLY: ship it" "$tmp/o4"' "$(cat "$tmp/o4")"
ok "user: a user move wakes it" 'grep -qx "MOVED: \"Card C\" \[CrdC1111\] 🙋‍♂️ REVIEW 👀 → TODO 📚" "$tmp/o4"' "$(cat "$tmp/o4")"
actions '[]'

# 3a. An agent phrase from another account (the user's) is a wrong-account agent comment: one WRONG ACCOUNT:
# line, no COMMENT: line, nothing again; a plain comment still gives COMMENT:, a Claude comment nothing.
lw=$(iso $((now + 200)))
actions '[{"id":"w1","type":"commentCard","date":"'"$lw"'","idMemberCreator":"'"$USER"'","data":{"text":"FULL SUITE FAILED: main @ a, development @ b: x","card":{"name":"Card W","shortLink":"CrdW1111"},"list":{"name":"RELEASING"}}},
          {"id":"w2","type":"commentCard","date":"'"$lw"'","idMemberCreator":"'"$USER"'","data":{"text":"Looks fine to me","card":{"name":"Card W","shortLink":"CrdW1111"},"list":{"name":"RELEASING"}}},
          {"id":"w3","type":"commentCard","date":"'"$lw"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"TEST PASSED: w","card":{"name":"Card W","shortLink":"CrdW1111"},"list":{"name":"RELEASING"}}}]'
run "$tmp/ow1" env BOARD_WAIT_LIMIT=3 "$W"
ok "wrong account: a non-Claude FULL SUITE FAILED: gives one WRONG ACCOUNT: line and no COMMENT: line" 'grep -qx "WRONG ACCOUNT: \"Card W\" \[CrdW1111\] (RELEASING): FULL SUITE FAILED: main @ a, development @ b: x" "$tmp/ow1" && ! grep -q "COMMENT:.*FULL SUITE" "$tmp/ow1"' "$(cat "$tmp/ow1")"
ok "wrong account: a plain user comment still gives COMMENT: and a Claude comment nothing" 'grep -qx "COMMENT (user): \"Card W\" \[CrdW1111\] (RELEASING): Looks fine to me" "$tmp/ow1" && ! grep -q "TEST PASSED" "$tmp/ow1"' "$(cat "$tmp/ow1")"
run "$tmp/ow2" env BOARD_WAIT_LIMIT=1 "$W"
ok "wrong account: the next poll prints nothing again" '[ "$(rc "$tmp/ow2")" = 3 ] && ! grep -q "WRONG ACCOUNT" "$tmp/ow2"' "$(cat "$tmp/ow2")"
actions '[]'

# 3b. More actions since the cursor than one page holds: it pages back to the cursor.
p0=$(iso $((now + 300))) p1=$(iso $((now + 301))) p2=$(iso $((now + 302)))
actions '[{"id":"a12","type":"commentCard","date":"'"$p2"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"TEST PASSED: y","card":{"name":"Card D","shortLink":"CrdD1111"},"list":{"name":"BUILDING"}}},
          {"id":"a11","type":"commentCard","date":"'"$p1"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"TEST PASSED: z","card":{"name":"Card D","shortLink":"CrdD1111"},"list":{"name":"BUILDING"}}}]'
echo '[{"id":"a10","type":"commentCard","date":"'"$p0"'","idMemberCreator":"'"$USER"'","data":{"text":"An older comment","card":{"name":"Card D","shortLink":"CrdD1111"},"list":{"name":"BUILDING"}}}]' >"$T/boards/AbCd1234/actions.before-a11"
run "$tmp/o4b" env BOARD_WAIT_LIMIT=3 BOARD_WAIT_ACTIONS_PAGE=2 "$W"
ok "user: a comment on an older page of actions is still reported" 'grep -qx "COMMENT (user): \"Card D\" \[CrdD1111\] (BUILDING): An older comment" "$tmp/o4b"' "rc=$(rc "$tmp/o4b") $(cat "$tmp/o4b")"
actions '[]'; rm -f "$T/boards/AbCd1234/actions.before-a11"

# 3c. The default page (300) is never exceeded: 650 actions since the cursor come in three pages of at most 300, the oldest only on page 3.
python3 -I - "$T/boards/AbCd1234" "$CLAUDE" "$((now + 400))" "$USER" <<'PY'
import json, sys, datetime as d
root, claude, base, user = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
def iso(t): return d.datetime.fromtimestamp(t, d.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
acts = [{"id": f"b{n:04d}", "type": "commentCard", "date": iso(base + n), "idMemberCreator": claude,
         "data": {"text": "TEST PASSED: q", "card": {"name": "Card E", "shortLink": "CrdE1111"}, "list": {"name": "BUILDING"}}}
        for n in range(650, 0, -1)]
acts[-1] = dict(acts[-1], idMemberCreator=user, data={"text": "The oldest page comment", "card": {"name": "Card E", "shortLink": "CrdE1111"}, "list": {"name": "BUILDING"}})
pages = [acts[:300], acts[300:600], acts[600:]]
json.dump(pages[0], open(f"{root}/actions", "w"))
json.dump(pages[1], open(f"{root}/actions.before-{pages[0][-1]['id']}", "w"))
json.dump(pages[2], open(f"{root}/actions.before-{pages[1][-1]['id']}", "w"))
PY
run "$tmp/o4c" env BOARD_WAIT_LIMIT=3 "$W"
ok "default page: a comment on page 3 of 3 (300 actions per page, no 429) is still reported" 'grep -q "The oldest page comment" "$tmp/o4c"' "rc=$(rc "$tmp/o4c") $(cat "$tmp/o4c")"
actions '[]'; rm -f "$T"/boards/AbCd1234/actions.before-b*

# 4. A free server with a startable card in TODO; a Blocked, [AGENTS] (also 🚨 [AGENTS] or 🪲 [AGENTS])
#    or person-owned card is not startable.
cards '[{"id":"c1","name":"Blocked one","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"BloC1111"},
        {"id":"c2","name":"[AGENTS] a workflow card","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"AgnT1111"},
        {"id":"x2b","name":"🚨 [AGENTS] an urgent workflow card","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"AgnU1111"},
        {"id":"x2c","name":"🪲 [AGENTS] a workflow bug","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"AgnG1111"},
        {"id":"c3","name":"Someone owns it","idList":"lt","idLabels":[],"idMembers":["m1"],"shortLink":"OwnD1111"}]'
printf 'test-server-1 free\ntest-server-2 Busy2222\ntest-server-3 Busy3333\n' >"$tmp/servers"
echo "running workflow-builder card=- id=w1 last=3s children=0 - /x" >"$tmp/agents"
run "$tmp/o5a" env BOARD_WAIT_LIMIT=1 "$W"
ok "blocked: a card with the Blocked label wakes it once" 'grep -qx "BLOCKED: \"Blocked one\" \[BloC1111\] (TODO) has the Blocked label" "$tmp/o5a"' "$(cat "$tmp/o5a")"
run "$tmp/o5" env BOARD_WAIT_LIMIT=1 "$W"
ok "start: no startable card, no wake" '[ "$(rc "$tmp/o5")" = 3 ]' "rc=$(rc "$tmp/o5") $(cat "$tmp/o5")"
# A label taken off and put on again sends a new BLOCKED: line; a status card (⛔) sends none.
cards '[{"id":"c1","name":"Blocked one","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"BloC1111"}]'
run "$tmp/o5b" env BOARD_WAIT_LIMIT=1 "$W"
cards '[{"id":"c1","name":"Blocked one","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"BloC1111"}]'
run "$tmp/o5c" env BOARD_WAIT_LIMIT=1 "$W"
ok "blocked: a label removed and put on again sends the line again" 'grep -qx "BLOCKED: \"Blocked one\" \[BloC1111\] (TODO) has the Blocked label" "$tmp/o5c"' "$(cat "$tmp/o5c")"
cards '[{"id":"c8","name":"⛔ A status card","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"StaT1111"}]'
run "$tmp/o5d" env BOARD_WAIT_LIMIT=1 "$W"
ok "blocked: a status card with the label sends no line" '! grep -q "StaT1111" "$tmp/o5d"' "$(cat "$tmp/o5d")"
cards '[{"id":"c4","name":"Ready card","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"ReDy1111"}]'
run "$tmp/o6" env BOARD_WAIT_LIMIT=2 "$W"
ok "start: a free server and a startable card wake it" 'grep -qx "START: 1 free card test server; TODO has 1 startable card (ReDy1111)" "$tmp/o6"' "$(cat "$tmp/o6")"
run "$tmp/o7" env BOARD_WAIT_LIMIT=1 "$W"
ok "start: not again while nothing changed" '[ "$(rc "$tmp/o7")" = 3 ]' "rc=$(rc "$tmp/o7") $(cat "$tmp/o7")"
printf 'test-server-1 Busy1111\ntest-server-2 Busy2222\ntest-server-3 Busy3333\n' >"$tmp/servers"
run "$tmp/o7b" env BOARD_WAIT_LIMIT=1 "$W"
printf 'test-server-1 free\ntest-server-2 Busy2222\ntest-server-3 Busy3333\n' >"$tmp/servers"
run "$tmp/o7c" env BOARD_WAIT_LIMIT=2 "$W"
ok "start: after the server was taken and freed again, it is news again" 'grep -q "^START: " "$tmp/o7c"' "$(cat "$tmp/o7c")"
printf 'test-server-1 Busy1111\ntest-server-2 Busy2222\ntest-server-3 Busy3333\n' >"$tmp/servers"
cards '[]'

# 5. An agent gone quiet (dead), once.
echo "dead card-manager card=QuiT1111 id=cm9 last=1200s children=0 interrupted /x" >"$tmp/agents"
run "$tmp/o8" env BOARD_WAIT_LIMIT=2 "$W"
ok "agents: a dead agent wakes it" 'grep -qx "AGENT: dead card-manager card=QuiT1111 id=cm9" "$tmp/o8"' "$(cat "$tmp/o8")"
run "$tmp/o9" env BOARD_WAIT_LIMIT=1 "$W"
ok "agents: once per agent" '[ "$(rc "$tmp/o9")" = 3 ]' "rc=$(rc "$tmp/o9") $(cat "$tmp/o9")"
# 5b. A handed-off board watcher that used tools other than relaying: OLD WATCHER ACTED:, once per id and tool list.
echo "handed-off board-watcher card=- id=bw1 last=60s children=2 reqs=9 ctx=1 handed_off_at_15:00:_acted_after_handoff:Agentx2,trelloWriteCardx1 /w/bw1.jsonl" >"$tmp/agents"
echo "handed-off board-watcher card=- id=bw2 last=60s children=0 reqs=9 ctx=1 handed_off_at_15:00 /w/bw2.jsonl" >>"$tmp/agents"
run "$tmp/o9b" env BOARD_WAIT_LIMIT=2 "$W"
ok "agents: a handed-off watcher that acted wakes it with its tools" 'grep -qx "OLD WATCHER ACTED: id=bw1 Agentx2,trelloWriteCardx1 /w/bw1.jsonl" "$tmp/o9b"' "$(cat "$tmp/o9b")"
ok "agents: a handed-off watcher that only relayed is not reported" '! grep -q "bw2" "$tmp/o9b"' "$(cat "$tmp/o9b")"
run "$tmp/o9c" env BOARD_WAIT_LIMIT=1 "$W"
ok "agents: OLD WATCHER ACTED: once per id and tool list" '! grep -q "OLD WATCHER" "$tmp/o9c"' "rc=$(rc "$tmp/o9c") $(cat "$tmp/o9c")"
: >"$tmp/agents"

mkdir -p "$T/cards/RevW1111" && echo '[]' >"$T/cards/RevW1111/actions"
# 6. GitHub: an approval or changes requested on a REVIEW card's PR.
cards '[{"id":"c5","name":"Needs review (#12)","idList":"lr","idLabels":[],"idMembers":[],"shortLink":"RevW1111",
         "desc":"**PR:** example-user/example-app-old#12, https://github.com/example-user/example-app-old/pull/12 (app)"}]'
echo '{"headRefOid":"h1","reviews":[{"id":"r1","author":{"login":"example-user"},"state":"APPROVED","submittedAt":"2026-10-15T10:00:00Z"}]}' >"$tmp/gh/example-user_example-app-old-12.json"
run "$tmp/o10" env BOARD_WAIT_LIMIT=2 "$W"
ok "github: the user's approval wakes it" 'grep -qx "REVIEW: \"Needs review (#12)\" \[RevW1111\] example-user/example-app-old#12 APPROVED" "$tmp/o10"' "$(cat "$tmp/o10")"
run "$tmp/o11" env BOARD_WAIT_LIMIT=1 "$W"
ok "github: once per review" '[ "$(rc "$tmp/o11")" = 3 ]' "rc=$(rc "$tmp/o11") $(cat "$tmp/o11")"
# A reverted or included PR stays in the description (rules.md) but is not open: no wake for it.
cards '[{"id":"c5b","name":"Old PRs (#13)","idList":"lr","idLabels":[],"idMembers":[],"shortLink":"OldP1111",
         "desc":"**PR:** example-user/example-app-old#13, https://github.com/example-user/example-app-old/pull/13 (app) (reverted by example-user/example-app-old#15)\n**PR:** example-user/example-app-old#14, https://github.com/example-user/example-app-old/pull/14 (app) (included in example-user/example-app-old#16)"}]'
for n in 13 14; do
  echo '{"headRefOid":"h'"$n"'","reviews":[{"id":"r'"$n"'","author":{"login":"example-user"},"state":"APPROVED","submittedAt":"2026-10-15T10:00:00Z"}]}' >"$tmp/gh/example-user_example-app-old-$n.json"
done
run "$tmp/o11b" env BOARD_WAIT_LIMIT=1 "$W"
ok "github: a reverted or included PR is not read as open" '[ "$(rc "$tmp/o11b")" = 3 ]' "rc=$(rc "$tmp/o11b") $(cat "$tmp/o11b")"
cards '[]'

# 7. An [AGENTS] card in MERGING with no VERIFIED: for its head, once per head; VERIFY SELF: counts.
cards '[{"id":"c6","name":"[AGENTS] Fix a rule (#30)","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"VeRi1111",
         "desc":"**PR:** example-user/example-app-old#30, https://github.com/example-user/example-app-old/pull/30 (rule)"}]'
echo '{"headRefOid":"aaaa1111","reviews":[]}' >"$tmp/gh/example-user_example-app-old-30.json"
echo '[]' >"$T/cards/VeRi1111-actions"
mkdir -p "$T/cards/VeRi1111" && echo '[]' >"$T/cards/VeRi1111/actions"
run "$tmp/o12" env BOARD_WAIT_LIMIT=2 "$W"
ok "verify: no VERIFIED: for the head wakes it" 'grep -qx "VERIFY: \"\[AGENTS\] Fix a rule (#30)\" \[VeRi1111\] example-user/example-app-old#30 @ aaaa1111" "$tmp/o12"' "$(cat "$tmp/o12")"
run "$tmp/o13" env BOARD_WAIT_LIMIT=1 "$W"
ok "verify: once per head" '[ "$(rc "$tmp/o13")" = 3 ]' "rc=$(rc "$tmp/o13") $(cat "$tmp/o13")"
echo '{"headRefOid":"bbbb2222","reviews":[]}' >"$tmp/gh/example-user_example-app-old-30.json"
echo '[{"id":"v1","date":"2026-10-15T10:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"VERIFY SELF: example-user/example-app-old#30 @ bbbb2222"}}]' >"$T/cards/VeRi1111/actions"
run "$tmp/o14" env BOARD_WAIT_LIMIT=1 "$W"
ok "verify: a VERIFY SELF: for the new head counts as handled" '[ "$(rc "$tmp/o14")" = 3 ]' "rc=$(rc "$tmp/o14") $(cat "$tmp/o14")"
# A 🚨 [AGENTS] card is an [AGENTS] card too (rules.md, Card titles and labels).
cards '[{"id":"c6u","name":"🚨 [AGENTS] Fix a gate (#31)","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"VeRu1111",
         "desc":"**PR:** example-user/example-app-old#31, https://github.com/example-user/example-app-old/pull/31 (gate)"}]'
echo '{"headRefOid":"cccc3333","reviews":[]}' >"$tmp/gh/example-user_example-app-old-31.json"
mkdir -p "$T/cards/VeRu1111" && echo '[]' >"$T/cards/VeRu1111/actions"
run "$tmp/o14u" env BOARD_WAIT_LIMIT=2 "$W"
ok "verify: a 🚨 [AGENTS] card with no VERIFIED: for its head wakes it" 'grep -qx "VERIFY: \"🚨 \[AGENTS\] Fix a gate (#31)\" \[VeRu1111\] example-user/example-app-old#31 @ cccc3333" "$tmp/o14u"' "rc=$(rc "$tmp/o14u") $(cat "$tmp/o14u")"
# The mobile repo moved to RunnerCityOrg: a PR line and a VERIFIED: comment may name it either way.
cards '[{"id":"c6v","name":"[AGENTS] Moved repo (#32)","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"VeRv1111",
         "desc":"**PR:** example-org/example-app#32, https://github.com/example-org/example-app/pull/32 (x)"}]'
echo '{"headRefOid":"dddd4444","reviews":[]}' >"$tmp/gh/example-org_example-app-32.json"
mkdir -p "$T/cards/VeRv1111" && echo '[{"id":"v2","date":"2026-10-15T10:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"VERIFIED: example-user/example-app-old#32 @ dddd4444"}}]' >"$T/cards/VeRv1111/actions"
run "$tmp/o14v" env BOARD_WAIT_LIMIT=1 "$W"
ok "verify: an old-name VERIFIED: counts for a PR line with the new mobile repo name" '[ "$(rc "$tmp/o14v")" = 3 ]' "rc=$(rc "$tmp/o14v") $(cat "$tmp/o14v")"
echo '[{"id":"v3","date":"2026-10-15T10:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"VERIFIED: example-user/example-app-old#33 @ dddd4444"}}]' >"$T/cards/VeRv1111/actions"
run "$tmp/o14w" env BOARD_WAIT_LIMIT=2 "$W"
ok "verify: a VERIFIED: for another PR still wakes it" 'grep -q "^VERIFY: .*VeRv1111.* example-org/example-app#32 @ dddd4444" "$tmp/o14w"' "rc=$(rc "$tmp/o14w") $(cat "$tmp/o14w")"
# The newest verdict for a head decides: a VERIFY FAILED: after a VERIFIED: sends an [AGENTS] card in MERGING back
# (once per head) and the verifier is not started again on that head; a VERIFIED: after the VERIFY FAILED: ends it.
cards '[{"id":"c6w","name":"[AGENTS] Sent back (#34)","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"VeRw1111",
         "desc":"**PR:** example-org/example-app#34, https://github.com/example-org/example-app/pull/34 (x)"}]'
echo '{"headRefOid":"eeee5555","reviews":[]}' >"$tmp/gh/example-org_example-app-34.json"
mkdir -p "$T/cards/VeRw1111" && echo '[{"id":"v5","date":"2026-10-15T11:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"VERIFY FAILED: example-org/example-app#34 @ eeee5555: a gap"}},{"id":"v4","date":"2026-10-15T10:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"VERIFIED: example-org/example-app#34 @ eeee5555"}}]' >"$T/cards/VeRw1111/actions"
run "$tmp/o14x" env BOARD_WAIT_LIMIT=2 "$W"
ok "sent back: a VERIFY FAILED: newer than the VERIFIED: for the head prints SENT BACK IN MERGING: once" '[ "$(grep -c "^SENT BACK IN MERGING: \"\[AGENTS\] Sent back (#34)\" \[VeRw1111\] example-org/example-app#34 @ eeee5555$" "$tmp/o14x")" = 1 ]' "$(cat "$tmp/o14x")"
ok "sent back: no VERIFY: is started again on the failed head" '! grep -q "^VERIFY: " "$tmp/o14x"' "$(cat "$tmp/o14x")"
run "$tmp/o14y" env BOARD_WAIT_LIMIT=1 "$W"
ok "sent back: not printed again for the same head" '[ "$(rc "$tmp/o14y")" = 3 ]' "rc=$(rc "$tmp/o14y") $(cat "$tmp/o14y")"
echo '[{"id":"v6","date":"2026-10-15T12:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"VERIFIED: example-org/example-app#34 @ eeee5555"}},{"id":"v5","date":"2026-10-15T11:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"VERIFY FAILED: example-org/example-app#34 @ eeee5555: a gap"}}]' >"$T/cards/VeRw1111/actions"
echo '{"headRefOid":"ffff6666","reviews":[]}' >"$tmp/gh/example-org_example-app-34.json"
echo '[{"id":"v6","date":"2026-10-15T12:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"VERIFIED: example-org/example-app#34 @ eeee5555"}},{"id":"v5","date":"2026-10-15T11:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"VERIFY FAILED: example-org/example-app#34 @ ffff6666: a gap"}}]' >"$T/cards/VeRw1111/actions"
run "$tmp/o14z" env BOARD_WAIT_LIMIT=2 "$W"
ok "sent back: a VERIFIED: for the old head and a VERIFY FAILED: for the new head still sends the card back" 'grep -q "^SENT BACK IN MERGING: .*#34 @ ffff6666$" "$tmp/o14z"' "$(cat "$tmp/o14z")"
echo '{"headRefOid":"eeee5555","reviews":[]}' >"$tmp/gh/example-org_example-app-34.json"
echo '[{"id":"v6","date":"2026-10-15T12:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"VERIFIED: example-org/example-app#34 @ eeee5555"}},{"id":"v5","date":"2026-10-15T11:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"VERIFY FAILED: example-org/example-app#34 @ eeee5555: a gap"}}]' >"$T/cards/VeRw1111/actions"
run "$tmp/o14zz" env BOARD_WAIT_LIMIT=1 "$W"
ok "sent back: a VERIFIED: newer than the VERIFY FAILED: ends it (no SENT BACK, no VERIFY:)" '! grep -q "^SENT BACK\|^VERIFY: " "$tmp/o14zz"' "rc=$(rc "$tmp/o14zz") $(cat "$tmp/o14zz")"
cards '[]'

# 8. Deadlines: the weekly and daily checks fire once when due; the safety wake after 4 hours.
python3 -I - "$tmp/state.json" <<'PY'
import json, sys, time
s = json.load(open(sys.argv[1]))
s["periodic"]["fraud"] = time.time() - 2 * 86400
s["last_return"] = time.time()
json.dump(s, open(sys.argv[1], "w"))
PY
run "$tmp/o15" env BOARD_WAIT_LIMIT=2 "$W"
ok "deadline: the daily fraud check, once" 'grep -qx "DEADLINE: fraud check due" "$tmp/o15" && ! grep -q "token audit" "$tmp/o15"' "$(cat "$tmp/o15")"
run "$tmp/o16" env BOARD_WAIT_LIMIT=1 "$W"
ok "deadline: not again the same day" '[ "$(rc "$tmp/o16")" = 3 ]' "rc=$(rc "$tmp/o16") $(cat "$tmp/o16")"
# The time optimization every 4 days: a state file written before it existed starts its 4 days, then it fires once.
python3 -I - "$tmp/state.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); s["periodic"].pop("time", None)
json.dump(s, open(sys.argv[1], "w"))
PY
run "$tmp/o16a" env BOARD_WAIT_LIMIT=1 "$W"
ok "deadline: an old state file gets the time optimization 4 days, not a wake" '! grep -q "time optimization" "$tmp/o16a" && python3 -I -c "import json,sys; sys.exit(0 if \"time\" in json.load(open(sys.argv[1]))[\"periodic\"] else 1)" "$tmp/state.json"' "$(cat "$tmp/o16a")"
python3 -I - "$tmp/state.json" <<'PY'
import json, sys, time
s = json.load(open(sys.argv[1])); s["periodic"]["time"] = time.time() - 5 * 86400; s["last_return"] = time.time()
json.dump(s, open(sys.argv[1], "w"))
PY
run "$tmp/o16b" env BOARD_WAIT_LIMIT=2 "$W"
ok "deadline: the time optimization every 4 days, once" 'grep -qx "DEADLINE: time optimization due" "$tmp/o16b" && ! grep -q "token audit" "$tmp/o16b"' "$(cat "$tmp/o16b")"
run "$tmp/o16c" env BOARD_WAIT_LIMIT=1 "$W"
ok "deadline: not again the same 4 days" '! grep -q "time optimization" "$tmp/o16c"' "$(cat "$tmp/o16c")"
python3 -I - "$tmp/state.json" <<'PY'
import json, sys, time
s = json.load(open(sys.argv[1])); s["last_return"] = time.time() - 4 * 3600 - 60
json.dump(s, open(sys.argv[1], "w"))
PY
run "$tmp/o17" env BOARD_WAIT_LIMIT=2 "$W"
ok "safety: 4 hours with no wake is a SAFETY WAKE" 'grep -qx "SAFETY WAKE" "$tmp/o17"' "$(cat "$tmp/o17")"

# 9. The 🚨 fix deadline: a 🚨 card in TODO filed more than 24 hours ago, once.
old_id=$(printf '%08x' $((now - 25 * 3600)))0000000000000000
mkdir -p "$T/cards/UrgT1111" && echo '[]' >"$T/cards/UrgT1111/actions"
cards '[{"id":"'"$old_id"'","name":"🚨 Full suite failed: login","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"UrgT1111"}]'
run "$tmp/o18" env BOARD_WAIT_LIMIT=2 "$W"
ok "deadline: a 🚨 card past 24 hours" 'grep -qx "DEADLINE: urgent fix deadline passed: \"🚨 Full suite failed: login\" (UrgT1111)" "$tmp/o18"' "$(cat "$tmp/o18")"
run "$tmp/o18x" env BOARD_WAIT_LIMIT=1 "$W"
ok "deadline: not again within 2 hours" '[ "$(rc "$tmp/o18x")" = 3 ]' "rc=$(rc "$tmp/o18x") $(cat "$tmp/o18x")"
# The watcher takes off time in REVIEW and QUESTIONS, so the first wake may come
# early: while no REVERT: is on the card, it wakes again every 2 hours.
old_id=$(printf '%08x' $((now - 27 * 3600 - 1800)))0000000000000000
cards '[{"id":"'"$old_id"'","name":"🚨 Full suite failed: login","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"UrgT1111"}]'
run "$tmp/o18y" env BOARD_WAIT_LIMIT=2 "$W"
ok "deadline: the 🚨 card wakes it again 2 hours later" 'grep -qx "DEADLINE: urgent fix deadline passed: \"🚨 Full suite failed: login\" (UrgT1111)" "$tmp/o18y"' "rc=$(rc "$tmp/o18y") $(cat "$tmp/o18y")"
echo '[{"id":"rv1","date":"2026-10-15T10:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"REVERT: Some card https://trello.com/c/SoMe1111: example-user/example-app-old#9 @ abc"}}]' >"$T/cards/UrgT1111/actions"
old_id=$(printf '%08x' $((now - 29 * 3600 - 1800)))0000000000000000
cards '[{"id":"'"$old_id"'","name":"🚨 Full suite failed: login","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"UrgT1111"}]'
run "$tmp/o18z" env BOARD_WAIT_LIMIT=1 "$W"
ok "deadline: no more wakes once a REVERT: is on the card" '[ "$(rc "$tmp/o18z")" = 3 ]' "rc=$(rc "$tmp/o18z") $(cat "$tmp/o18z")"
# A 🚨 [AGENTS] card (a workflow change the user called urgent) has the urgent fix deadline too;
# once it is in MERGING, none.
mkdir -p "$T/cards/UrgA1111" && echo '[]' >"$T/cards/UrgA1111/actions"
cards '[{"id":"'"$old_id"'","name":"🚨 [AGENTS] An urgent rule","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"UrgA1111"}]'
run "$tmp/o18a" env BOARD_WAIT_LIMIT=1 "$W"
ok "deadline: a 🚨 [AGENTS] card past 24 hours" 'grep -qx "DEADLINE: urgent fix deadline passed: \"🚨 \[AGENTS\] An urgent rule\" (UrgA1111)" "$tmp/o18a"' "rc=$(rc "$tmp/o18a") $(cat "$tmp/o18a")"
# The same in its own list, WORKFLOW 🤖, where a 🚨 [AGENTS] card waits from approval until VERIFIED:.
mkdir -p "$T/cards/UrgW1111" && echo '[]' >"$T/cards/UrgW1111/actions"
cards '[{"id":"'"$old_id"'","name":"🚨 [AGENTS] An urgent rule in WORKFLOW","idList":"lw","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"UrgW1111"}]'
run "$tmp/o18w" env BOARD_WAIT_LIMIT=1 "$W"
ok "deadline: a 🚨 [AGENTS] card in WORKFLOW 🤖 past 24 hours" 'grep -qx "DEADLINE: urgent fix deadline passed: \"🚨 \[AGENTS\] An urgent rule in WORKFLOW\" (UrgW1111)" "$tmp/o18w"' "rc=$(rc "$tmp/o18w") $(cat "$tmp/o18w")"
# It has nothing to revert: the board watcher's BLOCKED: question ends its wakes (2 hours later: none).
echo '[{"id":"bq1","date":"2026-10-15T10:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"BLOCKED: urgent fix deadline passed: its PR waits for VERIFIED:. Keep it urgent, or drop the 🚨?\nFrom: BUILDING"}}]' >"$T/cards/UrgA1111/actions"
later_id=$(printf '%08x' $((now - 31 * 3600 - 1800)))0000000000000000
cards '[{"id":"'"$later_id"'","name":"🚨 [AGENTS] An urgent rule","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"UrgA1111"}]'
run "$tmp/o18q" env BOARD_WAIT_LIMIT=1 "$W"
ok "deadline: no more wakes for a 🚨 [AGENTS] card once its BLOCKED: question is on it" '! grep -q "urgent fix deadline" "$tmp/o18q"' "rc=$(rc "$tmp/o18q") $(cat "$tmp/o18q")"
mkdir -p "$T/cards/UrgM1111" && echo '[]' >"$T/cards/UrgM1111/actions"
cards '[{"id":"'"$old_id"'","name":"🚨 [AGENTS] An urgent rule, PR open","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"UrgM1111"}]'
run "$tmp/o18m" env BOARD_WAIT_LIMIT=1 "$W"
ok "deadline: none for a 🚨 [AGENTS] card in MERGING" '! grep -q "urgent fix deadline" "$tmp/o18m"' "rc=$(rc "$tmp/o18m") $(cat "$tmp/o18m")"
cards '[]'

# 9b. A card reaching MERGED or DONE while a card is Blocked: its blocker may have cleared.
mkdir -p "$T/cards/WaiT1111" "$T/cards/NotM1111"
echo '[{"date":"2026-10-15T09:00:00.000Z","data":{"text":"WAITS FOR: The other card (#40), for its new endpoint"}}]' >"$T/cards/WaiT1111/actions"
echo '[{"date":"2026-10-15T09:00:00.000Z","data":{"text":"WAITS FOR: you: apply the settings section. Check: test -f x"}}]' >"$T/cards/NotM1111/actions"
cards '[{"id":"c7","name":"Waits on another","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"WaiT1111"},
        {"id":"c9","name":"Waits on the user","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"NotM1111"},
        {"id":"c8","name":"The other card (#40)","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"OthR1111"}]'
run "$tmp/o18b" env BOARD_WAIT_LIMIT=1 "$W"
cards '[{"id":"c7","name":"Waits on another","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"WaiT1111"},
        {"id":"c9","name":"Waits on the user","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"NotM1111"},
        {"id":"c8","name":"The other card (#40)","idList":"ld","idLabels":[],"idMembers":[],"shortLink":"OthR1111"}]'
run "$tmp/o18c" env BOARD_WAIT_LIMIT=2 "$W"
ok "blocker: the card a WAITS FOR: names reaching MERGED wakes it" 'grep -qx "UNBLOCK?: \"Waits on another\" \[WaiT1111\] waits for \"The other card (#40)\" \[OthR1111\], which reached MERGED" "$tmp/o18c"' "$(cat "$tmp/o18c")"
ok "blocker: a card waiting on something else is not named" '! grep -q "Waits on the user" "$tmp/o18c"' "$(cat "$tmp/o18c")"
echo '[{"date":"2026-10-15T09:00:00.000Z","data":{"text":"WAITS FOR: 🚨 The other card (#40) https://trello.com/c/OthR1111: merging now would conflict with example-org/example-app#40"}}]' >"$T/cards/WaiT1111/actions"
# a 🚨 card named by a WAITS FOR: that is renamed without its 🚨, then one that is archived
cards '[{"id":"c7","name":"Waits on another","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"WaiT1111"},
        {"id":"c8","name":"🚨 The other card (#40)","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"OthR1111"}]'
run "$tmp/o18u1" env BOARD_WAIT_LIMIT=1 "$W"
cards '[{"id":"c7","name":"Waits on another","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"WaiT1111"},
        {"id":"c8","name":"The other card (#40)","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"OthR1111"}]'
run "$tmp/o18u2" env BOARD_WAIT_LIMIT=2 "$W"
ok "blocker: a 🚨 card renamed without its 🚨 wakes a WAITS FOR: that names it" 'grep -q "UNBLOCK?: .*\[OthR1111\], which lost its 🚨" "$tmp/o18u2"' "$(cat "$tmp/o18u2")"
cards '[{"id":"c7","name":"Waits on another","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"WaiT1111"},
        {"id":"c8","name":"🚨 The other card (#40)","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"OthR1111"}]'
run "$tmp/o18u3" env BOARD_WAIT_LIMIT=1 "$W"
cards '[{"id":"c7","name":"Waits on another","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"WaiT1111"}]'
run "$tmp/o18u4" env BOARD_WAIT_LIMIT=2 "$W"
ok "blocker: an archived 🚨 card wakes a WAITS FOR: that names it" 'grep -q "UNBLOCK?: .*\[OthR1111\], which was archived" "$tmp/o18u4"' "$(cat "$tmp/o18u4")"
cards '[]'

# 9c. A WAITS FOR: that links a card waits for that card only; a `#N` mentioned in passing, of a card now in DONE,
# does not clear it (2026-10-17: "... #239 fixed https://trello.com/c/3cj7QkHl" was taken as done).
mkdir -p "$T/cards/Lnk11111"
echo '[{"date":"2026-10-15T09:00:00.000Z","data":{"text":"WAITS FOR: [test helpers] the teardown fix, after #239 fixed https://trello.com/c/OpnL1111"}}]' >"$T/cards/Lnk11111/actions"
cards '[{"id":"d1","name":"Waits on the open card","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"Lnk11111"},
        {"id":"d2","name":"Fixed the teardown (#239)","desc":"**PR:** example-org/example-app#239 (the fix)","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"DonL1111"},
        {"id":"d3","name":"The open card (#275)","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"OpnL1111"}]'
run "$tmp/o18d" env BOARD_WAIT_LIMIT=1 "$W"
cards '[{"id":"d1","name":"Waits on the open card","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"Lnk11111"},
        {"id":"d2","name":"Fixed the teardown (#239)","desc":"**PR:** example-org/example-app#239 (the fix)","idList":"ld","idLabels":[],"idMembers":[],"shortLink":"DonL1111"},
        {"id":"d3","name":"The open card (#275)","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"OpnL1111"}]'
run "$tmp/o18e" env BOARD_WAIT_LIMIT=2 "$W"
ok "blocker: a #N mentioned in passing, of a card now in DONE, does not wake a WAITS FOR: that links another card" '! grep -q "UNBLOCK?: .*Lnk11111" "$tmp/o18e"' "$(cat "$tmp/o18e")"
cards '[{"id":"d1","name":"Waits on the open card","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"Lnk11111"},
        {"id":"d2","name":"Fixed the teardown (#239)","desc":"**PR:** example-org/example-app#239 (the fix)","idList":"ld","idLabels":[],"idMembers":[],"shortLink":"DonL1111"},
        {"id":"d3","name":"The open card (#275)","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"OpnL1111"}]'
run "$tmp/o18f" env BOARD_WAIT_LIMIT=1 "$W"
cards '[{"id":"d1","name":"Waits on the open card","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"Lnk11111"},
        {"id":"d2","name":"Fixed the teardown (#239)","desc":"**PR:** example-org/example-app#239 (the fix)","idList":"ld","idLabels":[],"idMembers":[],"shortLink":"DonL1111"},
        {"id":"d3","name":"The open card (#275)","idList":"ld","idLabels":[],"idMembers":[],"shortLink":"OpnL1111"}]'
run "$tmp/o18g" env BOARD_WAIT_LIMIT=2 "$W"
ok "blocker: the linked card reaching DONE does wake it" 'grep -q "UNBLOCK?: .*\[Lnk11111\] waits for \"The open card (#275)\"" "$tmp/o18g"' "$(cat "$tmp/o18g")"
cards '[]'

# 9c. The other deadlines. mark <key> <seconds ago>: sets a mark in the state file.
mark() {
  python3 -I - "$tmp/state.json" "$1" "$2" <<'PY'
import json, sys, time
s = json.load(open(sys.argv[1])); s["marks"][sys.argv[2]] = time.time() - float(sys.argv[3])
json.dump(s, open(sys.argv[1], "w"))
PY
}
# A release due by age: a card in MERGED, not Blocked, for more than a day.
cards '[{"id":"c10","name":"Merged long ago","idList":"ld","idLabels":[],"idMembers":[],"shortLink":"RelS1111"}]'
run "$tmp/o20" env BOARD_WAIT_LIMIT=1 "$W"
ok "deadline: a card new in MERGED is no release due" '[ "$(rc "$tmp/o20")" = 3 ]' "rc=$(rc "$tmp/o20") $(cat "$tmp/o20")"
mark seen-merged:RelS1111 $((86400 + 60))
run "$tmp/o21" env BOARD_WAIT_LIMIT=2 "$W"
ok "deadline: a card in MERGED for over a day is a release due by age" 'grep -qx "DEADLINE: release due by age: \"Merged long ago\" (RelS1111)" "$tmp/o21"' "rc=$(rc "$tmp/o21") $(cat "$tmp/o21")"
run "$tmp/o22" env BOARD_WAIT_LIMIT=1 "$W"
ok "deadline: the release due by age, once" '[ "$(rc "$tmp/o22")" = 3 ]' "rc=$(rc "$tmp/o22") $(cat "$tmp/o22")"
# The gap between releases: the newest move out of RELEASING ended the last release (release-gap.sh
# reads the same fake board). 7h59m ago: nothing; 8h01m ago: one wake; then none for that release end.
gapmove() { # gapmove <minutes ago>: a move RELEASING -> DONE by the Claude account
  python3 -I - "$1" "$CLAUDE" <<'PY' >"$T/boards/AbCd1234/actions"
import json, sys, time
d = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(time.time() - int(sys.argv[1]) * 60))
print(json.dumps([{"id": "a1", "type": "updateCard", "date": d, "idMemberCreator": sys.argv[2],
  "data": {"card": {"shortLink": "OldR1111", "name": "Released"}, "listBefore": {"id": "lx", "name": "RELEASING 🚀"}, "listAfter": {"id": "lz", "name": "DONE! 🙌🏽"}}}]))
PY
}
gapclear() { python3 -I -c "import json,sys; p=sys.argv[1]; s=json.load(open(p)); s['marks'].pop('gap-check-after',None); json.dump(s,open(p,'w'))" "$tmp/state.json"; }
gapclear; gapmove 479
run "$tmp/o22a" env BOARD_WAIT_LIMIT=2 "$W"
ok "gap: 7h59m after a release end, no wake" '! grep -q "release gap over" "$tmp/o22a"' "$(cat "$tmp/o22a")"
gapclear; gapmove 481
run "$tmp/o22b" env BOARD_WAIT_LIMIT=2 "$W"
ok "gap: 8h01m after a release end, one wake" '[ "$(grep -c "^DEADLINE: release gap over: the last release ended " "$tmp/o22b")" = 1 ]' "$(cat "$tmp/o22b")"
gapclear
run "$tmp/o22c" env BOARD_WAIT_LIMIT=2 "$W"
ok "gap: not again for the same release end" '! grep -q "release gap over" "$tmp/o22c"' "$(cat "$tmp/o22c")"
# A release-gap.sh that fails (exit 3: its Trello read failed) is no wake, and says why on stderr.
printf '#!/usr/bin/env bash\necho "release-gap: Trello request failed" >&2\nexit 3\n' >"$tmp/gap-fails" && chmod +x "$tmp/gap-fails"
gapclear
run "$tmp/o22d" env BOARD_WAIT_LIMIT=1 BOARD_WAIT_RELEASE_GAP="$tmp/gap-fails" "$W"
ok "gap: a failed release-gap.sh is no wake" '[ "$(rc "$tmp/o22d")" = 3 ] && ! grep -q "release gap over" "$tmp/o22d"' "rc=$(rc "$tmp/o22d") $(cat "$tmp/o22d")"
ok "gap: a failed release-gap.sh is noted on stderr" 'grep -qx "board-wait: $tmp/gap-fails exited 3: release-gap: Trello request failed" "$tmp/o22d"' "$(cat "$tmp/o22d")"
actions '[]'
cards '[]'
# Workflow work waiting: an [AGENTS] card in TODO and no workflow builder alive on it; again every 2 hours.
: >"$tmp/agents"
cards '[{"id":"c11u","name":"🚨 [AGENTS] An urgent rule to fix","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"AgnV1111"}]'
run "$tmp/o23u" env BOARD_WAIT_LIMIT=2 "$W"
ok "deadline: a 🚨 [AGENTS] card in TODO is workflow work" 'grep -qx "DEADLINE: workflow work waiting: AgnV1111" "$tmp/o23u"' "rc=$(rc "$tmp/o23u") $(cat "$tmp/o23u")"
cards '[{"id":"c11","name":"[AGENTS] A rule to fix","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"AgnW1111"}]'
run "$tmp/o23" env BOARD_WAIT_LIMIT=2 "$W"
ok "deadline: workflow work waiting with no workflow builder" 'grep -qx "DEADLINE: workflow work waiting: AgnW1111" "$tmp/o23"' "rc=$(rc "$tmp/o23") $(cat "$tmp/o23")"
run "$tmp/o24" env BOARD_WAIT_LIMIT=1 "$W"
ok "deadline: workflow work not again within 2 hours" '[ "$(rc "$tmp/o24")" = 3 ]' "rc=$(rc "$tmp/o24") $(cat "$tmp/o24")"
mark workflow-work $((2 * 3600 + 60))
run "$tmp/o25" env BOARD_WAIT_LIMIT=2 "$W"
ok "deadline: workflow work again after 2 hours" 'grep -qx "DEADLINE: workflow work waiting: AgnW1111" "$tmp/o25"' "rc=$(rc "$tmp/o25") $(cat "$tmp/o25")"
echo "running workflow-builder card=AgnW1111 id=w2 last=3s children=0 - /x" >"$tmp/agents"
mark workflow-work $((2 * 3600 + 60))
run "$tmp/o26" env BOARD_WAIT_LIMIT=1 "$W"
ok "deadline: no workflow work wake while a workflow builder works on that card" '[ "$(rc "$tmp/o26")" = 3 ]' "rc=$(rc "$tmp/o26") $(cat "$tmp/o26")"
# One workflow builder per card: a builder alive on another card holds back no card.
echo "running workflow-builder card=OthR1111 id=w3 last=3s children=0 - /x" >"$tmp/agents"
mark workflow-work $((2 * 3600 + 60))
run "$tmp/o26o" env BOARD_WAIT_LIMIT=2 "$W"
ok "deadline: workflow work waiting while a workflow builder works on another card" 'grep -qx "DEADLINE: workflow work waiting: AgnW1111" "$tmp/o26o"' "rc=$(rc "$tmp/o26o") $(cat "$tmp/o26o")"
: >"$tmp/agents"
# board-watcher.md counts more workflow work: an [AGENTS] conflict in MERGING and an
# orphaned [AGENTS] card in BUILDING (one that still has the Actively worked label;
# without it, the card waits in BUILDING for the verifier's VERIFIED:, which is no
# work for the workflow builder). New work is sent at once, not after 2 hours.
ORANGE=000000000000000000000024 ACTIVE=000000000000000000000021 NOACTION=000000000000000000000023
cards '[{"id":"c11","name":"[AGENTS] A rule to fix","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"AgnW1111"},
        {"id":"c13","name":"[AGENTS] A conflict","idList":"lm","idLabels":["'"$ORANGE"'"],"idMembers":[],"shortLink":"AgnC1111"},
        {"id":"c14","name":"[AGENTS] Left in BUILDING","idList":"lb","idLabels":["'"$ACTIVE"'"],"idMembers":[],"shortLink":"AgnB1111"},
        {"id":"c16","name":"[AGENTS] A hooks card waiting for VERIFIED:","idList":"lb","idLabels":[],"idMembers":[],"shortLink":"AgnH1111"},
        {"id":"c15","name":"[AGENTS] Merging, no conflict","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"AgnM1111"}]'
mkdir -p "$T/cards/AgnB1111" "$T/cards/AgnH1111" "$T/cards/AgnW1111" "$T/cards/AgnC1111" "$T/cards/AgnM1111"
echo '[]' >"$T/cards/AgnB1111/actions"
echo '[{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"AWAITING VERIFIED: example-user/example-app-old#50 @ abc"}}]' >"$T/cards/AgnH1111/actions"
for k in AgnW1111 AgnC1111 AgnM1111; do echo '[]' >"$T/cards/$k/actions"; done
mark workflow-work 60
run "$tmp/o26b" env BOARD_WAIT_LIMIT=2 "$W"
ok "deadline: an [AGENTS] conflict in MERGING and an orphan in BUILDING (no workflow builder on it, not awaiting VERIFIED:) are workflow work, sent at once; one awaiting VERIFIED: is not" 'grep -qx "DEADLINE: workflow work waiting: AgnW1111, AgnC1111, AgnB1111" "$tmp/o26b"' "rc=$(rc "$tmp/o26b") $(cat "$tmp/o26b")"
run "$tmp/o26c" env BOARD_WAIT_LIMIT=1 "$W"
ok "deadline: the same workflow work not again within 2 hours" '[ "$(rc "$tmp/o26c")" = 3 ]' "rc=$(rc "$tmp/o26c") $(cat "$tmp/o26c")"
# A batch: one live workflow builder works on two related cards (cards= of agent-state.sh). Neither
# its second card in BUILDING (Actively worked, no AWAITING VERIFIED:) nor its first is workflow work;
# the other cards still are, and are sent at once because the work changed.
echo "running workflow-builder card=AgnW1111 id=w4 last=3s children=0 reqs=1 ctx=1 cards=AgnW1111,AgnB1111 - /x" >"$tmp/agents"
run "$tmp/o26d" env BOARD_WAIT_LIMIT=2 "$W"
ok "deadline: every card of a live workflow builder's batch is its, not orphaned workflow work" 'grep -qx "DEADLINE: workflow work waiting: AgnC1111" "$tmp/o26d"' "rc=$(rc "$tmp/o26d") $(cat "$tmp/o26d")"
: >"$tmp/agents"
cards '[]'
# WORKFLOW 🤖 (the card "[AGENTS] Give workflow cards their own WORKFLOW 🤖 list"): an [AGENTS] card moved
# into it is workflow work; one that waits for the verifier (AWAITING VERIFIED:) or is Blocked is not; a
# sent-back one (VERIFY FAILED: newer) is; an app card in TODO is no workflow work and still startable.
: >"$tmp/agents"
cards '[{"id":"w1","name":"[AGENTS] Newly approved","idList":"lw","idLabels":[],"idMembers":[],"shortLink":"WfNew111"},
        {"id":"w2","name":"[AGENTS] Waiting for the verifier","idList":"lw","idLabels":[],"idMembers":[],"shortLink":"WfAwa111"},
        {"id":"w3","name":"[AGENTS] Sent back","idList":"lw","idLabels":[],"idMembers":[],"shortLink":"WfBak111"},
        {"id":"w4","name":"[AGENTS] Blocked one","idList":"lw","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"WfBlk111"},
        {"id":"w5","name":"An app card","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"AppC1111"}]'
for k in WfNew111 WfAwa111 WfBak111 WfBlk111 AppC1111; do mkdir -p "$T/cards/$k"; echo '[]' >"$T/cards/$k/actions"; done
echo '[{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"AWAITING VERIFIED: example-user/example-app-old#60 @ abc"}}]' >"$T/cards/WfAwa111/actions"
echo '[{"date":"2026-10-15T10:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"VERIFY FAILED: example-user/example-app-old#61 @ def: a gap"}},
      {"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"AWAITING VERIFIED: example-user/example-app-old#61 @ def"}}]' >"$T/cards/WfBak111/actions"
mark workflow-work 60
run "$tmp/o26w" env BOARD_WAIT_LIMIT=2 "$W"
ok "workflow: new and sent-back [AGENTS] cards in WORKFLOW 🤖 are workflow work; one awaiting VERIFIED: or Blocked is not" 'grep -qx "DEADLINE: workflow work waiting: WfNew111, WfBak111" "$tmp/o26w"' "rc=$(rc "$tmp/o26w") $(cat "$tmp/o26w")"
ok "workflow: an app card in TODO is no workflow work" '! grep -q "AppC1111" <(grep "workflow work" "$tmp/o26w")' "$(cat "$tmp/o26w")"
printf 'test-server-1 free\ntest-server-2 Busy2222\ntest-server-3 Busy3333\n' >"$tmp/servers"
run "$tmp/o26x" env BOARD_WAIT_LIMIT=2 "$W"
ok "workflow: an app card in TODO is still startable, a card in WORKFLOW 🤖 is not" 'grep -q "^START: .*TODO has 1 startable card (AppC1111)" "$tmp/o26x"' "rc=$(rc "$tmp/o26x") $(cat "$tmp/o26x")"
printf 'test-server-1 Busy1111\ntest-server-2 Busy2222\ntest-server-3 Busy3333\n' >"$tmp/servers"
# One workflow builder per card, in WORKFLOW 🤖: a live builder whose batch (cards=) holds both the new and
# the sent-back card holds back both, its second card too; a builder on another card holds back neither.
echo "running workflow-builder card=WfNew111 id=w9 last=3s children=0 reqs=1 ctx=1 cards=WfNew111,WfBak111 - /x" >"$tmp/agents"
mark workflow-work $((2 * 3600 + 60))
run "$tmp/o26q" env BOARD_WAIT_LIMIT=1 "$W"
ok "workflow: every card in WORKFLOW 🤖 of a live builder's batch is its, not workflow work" '! grep -q "workflow work waiting" "$tmp/o26q"' "rc=$(rc "$tmp/o26q") $(cat "$tmp/o26q")"
echo "running workflow-builder card=OthR1111 id=w9 last=3s children=0 reqs=1 ctx=1 - /x" >"$tmp/agents"
mark workflow-work $((2 * 3600 + 60))
run "$tmp/o26r" env BOARD_WAIT_LIMIT=2 "$W"
ok "workflow: a builder on another card holds back no card in WORKFLOW 🤖" 'grep -qx "DEADLINE: workflow work waiting: WfNew111, WfBak111" "$tmp/o26r"' "rc=$(rc "$tmp/o26r") $(cat "$tmp/o26r")"
: >"$tmp/agents"
# VERIFIED: for every open PR's current head: one wake per set of heads, so the board watcher moves the card on.
cards '[{"id":"w6","name":"[AGENTS] Verified one (#62)","idList":"lw","idLabels":[],"idMembers":[],"shortLink":"WfVer111",
         "desc":"**PR:** example-org/example-app#62, https://github.com/example-org/example-app/pull/62 (x)"},
        {"id":"w7","name":"[AGENTS] Built, not verified (#63)","idList":"lw","idLabels":[],"idMembers":[],"shortLink":"WfNov111",
         "desc":"**PR:** example-org/example-app#63, https://github.com/example-org/example-app/pull/63 (y)"},
        {"id":"w7b","name":"[AGENTS] Verified then sent back (#65)","idList":"lw","idLabels":[],"idMembers":[],"shortLink":"WfBck111",
         "desc":"**PR:** example-org/example-app#65, https://github.com/example-org/example-app/pull/65 (v)"},
        {"id":"w7c","name":"[AGENTS] Verified then unblocked (#66)","idList":"lw","idLabels":[],"idMembers":[],"shortLink":"WfUnb111",
         "desc":"**PR:** example-org/example-app#66, https://github.com/example-org/example-app/pull/66 (u)"}]'
echo '{"headRefOid":"8888bbbb","reviews":[]}' >"$tmp/gh/example-org_example-app-66.json"
echo '{"headRefOid":"eeee5555","reviews":[]}' >"$tmp/gh/example-org_example-app-62.json"
echo '{"headRefOid":"ffff6666","reviews":[]}' >"$tmp/gh/example-org_example-app-63.json"
echo '{"headRefOid":"7777aaaa","reviews":[]}' >"$tmp/gh/example-org_example-app-65.json"
mkdir -p "$T/cards/WfVer111" "$T/cards/WfNov111" "$T/cards/WfBck111" "$T/cards/WfUnb111"
echo '[{"date":"2026-10-15T12:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"UNBLOCKED: answered"}},{"date":"2026-10-15T11:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"VERIFIED: example-org/example-app#66 @ 8888bbbb"}}]' >"$T/cards/WfUnb111/actions"
echo '[{"date":"2026-10-15T12:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"VERIFY FAILED: example-org/example-app#65 @ 7777aaaa: x"}},{"date":"2026-10-15T11:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"VERIFIED: example-org/example-app#65 @ 7777aaaa"}}]' >"$T/cards/WfBck111/actions"
echo '[{"date":"2026-10-15T11:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"VERIFIED: example-org/example-app#62 @ eeee5555"}}]' >"$T/cards/WfVer111/actions"
echo '[{"date":"2026-10-15T11:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"VERIFIED: example-org/example-app#63 @ 0000aaaa"}}]' >"$T/cards/WfNov111/actions"
run "$tmp/o26y" env BOARD_WAIT_LIMIT=2 "$W"
ok "workflow: every PR verified at its head in WORKFLOW 🤖 wakes the watcher to move the card; a stale VERIFIED: does not, and neither does one older than a VERIFY FAILED:" 'grep -qx "VERIFIED CARD: \"\[AGENTS\] Verified one (#62)\" \[WfVer111\] (WORKFLOW 🤖): example-org/example-app#62 @ eeee5555" "$tmp/o26y" && ! grep -q "WfNov111" <(grep "VERIFIED CARD" "$tmp/o26y") && ! grep -q "WfBck111" <(grep "VERIFIED CARD" "$tmp/o26y")' "rc=$(rc "$tmp/o26y") $(cat "$tmp/o26y")"
run "$tmp/o26z" env BOARD_WAIT_LIMIT=1 "$W"
ok "workflow: an UNBLOCKED: newer than a VERIFIED: does not void it (only a send-back does)" 'grep -q "VERIFIED CARD: .*\[WfUnb111\] (WORKFLOW 🤖): example-org/example-app#66 @ 8888bbbb" "$tmp/o26y"' "$(cat "$tmp/o26y")"
ok "workflow: the verified card is reported once per set of heads" '! grep -q "VERIFIED CARD" "$tmp/o26z"' "rc=$(rc "$tmp/o26z") $(cat "$tmp/o26z")"
# A card in WORKFLOW 🤖 whose newest comment is AWAITING VERIFIED: and with no VERIFIED: for its head: VERIFY: once, again after a new head.
cards '[{"id":"w8","name":"[AGENTS] Awaiting (#64)","idList":"lw","idLabels":[],"idMembers":[],"shortLink":"WfAwt1111",
         "desc":"**PR:** example-org/example-app#64, https://github.com/example-org/example-app/pull/64 (z)"}]'
echo '{"headRefOid":"aaaa1111","reviews":[]}' >"$tmp/gh/example-org_example-app-64.json"
mkdir -p "$T/cards/WfAwt1111"
echo '[{"date":"2026-10-15T11:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"AWAITING VERIFIED: example-org/example-app#64 @ aaaa1111"}}]' >"$T/cards/WfAwt1111/actions"
run "$tmp/o26p" env BOARD_WAIT_LIMIT=2 "$W"
ok "workflow: an awaiting card in WORKFLOW 🤖 with no VERIFIED: for its head wakes the watcher with VERIFY:" 'grep -qx "VERIFY: \"\[AGENTS\] Awaiting (#64)\" \[WfAwt1111\] example-org/example-app#64 @ aaaa1111" "$tmp/o26p"' "rc=$(rc "$tmp/o26p") $(cat "$tmp/o26p")"
run "$tmp/o26q" env BOARD_WAIT_LIMIT=1 "$W"
ok "workflow: the same head is reported once" '! grep -q "WfAwt1111" "$tmp/o26q"' "$(cat "$tmp/o26q")"
echo '{"headRefOid":"bbbb2222","reviews":[]}' >"$tmp/gh/example-org_example-app-64.json"
run "$tmp/o26r" env BOARD_WAIT_LIMIT=2 "$W"
ok "workflow: a new head is reported again" 'grep -qx "VERIFY: \"\[AGENTS\] Awaiting (#64)\" \[WfAwt1111\] example-org/example-app#64 @ bbbb2222" "$tmp/o26r"' "rc=$(rc "$tmp/o26r") $(cat "$tmp/o26r")"
# The plan round (https://trello.com/c/5UYHCtaZ, rules.md Plan first). Plan comments are read apart from AWAITING VERIFIED:.
ago() { python3 -I -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=$1)).strftime('%Y-%m-%dT%H:%M:%S.000Z'))"; }
cm() { printf '{"date":"%s","idMemberCreator":"%s","data":{"text":"%s"}}' "$(ago "$1")" "$CLAUDE" "$2"; }
cards '[{"id":"p1","name":"[AGENTS] Plan old","idList":"lw","idLabels":[],"idMembers":[],"shortLink":"PlnA1111"},
        {"id":"p2","name":"[AGENTS] Plan fresh","idList":"lw","idLabels":[],"idMembers":[],"shortLink":"PlnB1111"},
        {"id":"p3","name":"[AGENTS] Plan changes","idList":"lw","idLabels":[],"idMembers":[],"shortLink":"PlnC1111"},
        {"id":"p4","name":"[AGENTS] Plan agreed","idList":"lw","idLabels":[],"idMembers":[],"shortLink":"PlnD1111"},
        {"id":"p5","name":"[AGENTS] Plan after agreed","idList":"lw","idLabels":[],"idMembers":[],"shortLink":"PlnE1111"},
        {"id":"p6","name":"[AGENTS] Plan blocked","idList":"lw","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"PlnF1111"},
        {"id":"p7","name":"[AGENTS] Plan with PR (#70)","idList":"lw","idLabels":[],"idMembers":[],"shortLink":"PlnG1111",
         "desc":"**PR:** example-org/example-app#70, https://github.com/example-org/example-app/pull/70 (a)"},
        {"id":"p8","name":"[AGENTS] Agreed plan, built (#71)","idList":"lw","idLabels":[],"idMembers":[],"shortLink":"PlnH1111",
         "desc":"**PR:** example-org/example-app#71, https://github.com/example-org/example-app/pull/71 (b)"},
        {"id":"p9","name":"[AGENTS] Plan with verified PR (#72)","idList":"lw","idLabels":[],"idMembers":[],"shortLink":"PlnI1111",
         "desc":"**PR:** example-org/example-app#72, https://github.com/example-org/example-app/pull/72 (c)"}]'
for k in PlnA1111 PlnB1111 PlnC1111 PlnD1111 PlnE1111 PlnF1111 PlnG1111 PlnH1111 PlnI1111; do mkdir -p "$T/cards/$k"; done
echo "[$(cm 120 'PLAN: revision 1 x')]" >"$T/cards/PlnA1111/actions"
echo "[$(cm 1 'PLAN: revision 1 x')]" >"$T/cards/PlnB1111/actions"
echo "[$(cm 30 'PLAN CHANGES: revision 1: x'),$(cm 60 'PLAN: revision 1 x')]" >"$T/cards/PlnC1111/actions"
echo "[$(cm 30 'PLAN AGREED: revision 1'),$(cm 60 'PLAN: revision 1 x')]" >"$T/cards/PlnD1111/actions"
echo "[$(cm 30 'PLAN: revision 2 x'),$(cm 60 'PLAN AGREED: revision 1')]" >"$T/cards/PlnE1111/actions"
echo "[$(cm 120 'PLAN: revision 1 x')]" >"$T/cards/PlnF1111/actions"
echo "[$(cm 30 'PLAN: revision 2 x'),$(cm 90 'AWAITING VERIFIED: example-org/example-app#70 @ 70aa70aa')]" >"$T/cards/PlnG1111/actions"
echo "[$(cm 30 'AWAITING VERIFIED: example-org/example-app#71 @ 71bb71bb'),$(cm 90 'PLAN AGREED: revision 1')]" >"$T/cards/PlnH1111/actions"
echo '{"headRefOid":"70cc70cc","reviews":[]}' >"$tmp/gh/example-org_example-app-70.json"
echo '{"headRefOid":"71bb71bb","reviews":[]}' >"$tmp/gh/example-org_example-app-71.json"
echo '{"headRefOid":"72dd72dd","reviews":[]}' >"$tmp/gh/example-org_example-app-72.json"
echo "[$(cm 10 'VERIFIED: example-org/example-app#72 @ 72dd72dd'),$(cm 30 'PLAN: revision 2 x'),$(cm 90 'AWAITING VERIFIED: example-org/example-app#72 @ 72aa72aa')]" >"$T/cards/PlnI1111/actions"
echo "running workflow-verifier card=PlnA1111 id=pv1 last=3s children=0 reqs=1 ctx=1 - /x" >"$tmp/agents"
mark workflow-work 60
run "$tmp/o40a" env BOARD_WAIT_LIMIT=2 "$W"
ok "plan: an old PLAN: with a workflow verifier alive on its card (the card of the verifier's prompt) gives no VERIFY PLAN:" '! grep -q "VERIFY PLAN:.*PlnA1111" "$tmp/o40a"' "$(cat "$tmp/o40a")"
ok "plan: an unanswered PLAN: is no workflow work; a PLAN CHANGES: or PLAN AGREED: is" 'grep -qx "DEADLINE: workflow work waiting: PlnC1111, PlnD1111" "$tmp/o40a"' "rc=$(rc "$tmp/o40a") $(cat "$tmp/o40a")"
ok "plan: a PLAN: newer than the last PLAN AGREED: waits for the verifier again (VERIFY PLAN:, no workflow work), and a Blocked card with a PLAN: is left alone" 'grep -qx "VERIFY PLAN: \"\[AGENTS\] Plan after agreed\" \[PlnE1111\] plan revision 2" "$tmp/o40a" && ! grep -q "workflow work.*PlnE1111\|VERIFY PLAN:.*PlnF1111\|workflow work.*PlnF1111" "$tmp/o40a"' "$(cat "$tmp/o40a")"
ok "plan: a card with a PR, a new head and a PLAN: newer than its AWAITING VERIFIED: gets no VERIFY:" '! grep -q "^VERIFY: .*PlnG1111" "$tmp/o40a"' "$(cat "$tmp/o40a")"
ok "plan: a card with a PR verified at its head but a PLAN: newer than its AWAITING VERIFIED: gets no VERIFIED CARD: either" '! grep -q "^VERIFIED CARD: .*PlnI1111" "$tmp/o40a"' "$(cat "$tmp/o40a")"
ok "plan: a card whose AWAITING VERIFIED: is newer than its PLAN AGREED: gets VERIFY: for a head with no VERIFIED: as before" 'grep -qx "VERIFY: \"\[AGENTS\] Agreed plan, built (#71)\" \[PlnH1111\] example-org/example-app#71 @ 71bb71bb" "$tmp/o40a"' "$(cat "$tmp/o40a")"
: >"$tmp/agents"
run "$tmp/o40b" env BOARD_WAIT_LIMIT=2 "$W"
ok "plan: a PLAN: older than 10 minutes and no live verifier on the card: VERIFY PLAN: with its revision" 'grep -qx "VERIFY PLAN: \"\[AGENTS\] Plan old\" \[PlnA1111\] plan revision 1" "$tmp/o40b"' "rc=$(rc "$tmp/o40b") $(cat "$tmp/o40b")"
ok "plan: a PLAN: newer than the grace gives none, and neither does a verdict, a Blocked card or a PLAN: newer than a verified plan card with a PR" '! grep -q "VERIFY PLAN:.*\(PlnB1111\|PlnC1111\|PlnD1111\|PlnF1111\)" "$tmp/o40b"' "$(cat "$tmp/o40b")"
run "$tmp/o40c" env BOARD_WAIT_LIMIT=1 "$W"
ok "plan: VERIFY PLAN: once per plan comment" '! grep -q "PlnA1111" "$tmp/o40c"' "$(cat "$tmp/o40c")"
echo "[$(cm 2 'PLAN: revision 2 x'),$(cm 150 'PLAN CHANGES: revision 1: x'),$(cm 200 'PLAN: revision 1 x')]" >"$T/cards/PlnA1111/actions"
run "$tmp/o40d" env BOARD_WAIT_LIMIT=1 "$W"
ok "plan: a new revision inside the grace gives none yet" '! grep -q "PlnA1111" "$tmp/o40d"' "$(cat "$tmp/o40d")"
echo "[$(cm 20 'PLAN: revision 2 x'),$(cm 150 'PLAN CHANGES: revision 1: x'),$(cm 200 'PLAN: revision 1 x')]" >"$T/cards/PlnA1111/actions"
run "$tmp/o40e" env BOARD_WAIT_LIMIT=2 "$W"
ok "plan: a new revision, once its grace has passed, gets its own VERIFY PLAN:" 'grep -qx "VERIFY PLAN: \"\[AGENTS\] Plan old\" \[PlnA1111\] plan revision 2" "$tmp/o40e"' "rc=$(rc "$tmp/o40e") $(cat "$tmp/o40e")"
cards '[]'
# A held TODO: startable cards and no free card test server for 2 hours, once per episode.
cards '[{"id":"c12","name":"Waiting for a server","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"HelD1111"}]'
run "$tmp/o27" env BOARD_WAIT_LIMIT=1 "$W"
ok "deadline: a TODO held for less than 2 hours is no wake" '[ "$(rc "$tmp/o27")" = 3 ]' "rc=$(rc "$tmp/o27") $(cat "$tmp/o27")"
mark todo-held-since $((2 * 3600 + 60))
run "$tmp/o28" env BOARD_WAIT_LIMIT=2 "$W"
ok "deadline: startable cards held 2 hours for a server" 'grep -qx "DEADLINE: startable cards have waited 2 hours for a card test server" "$tmp/o28"' "rc=$(rc "$tmp/o28") $(cat "$tmp/o28")"
run "$tmp/o29" env BOARD_WAIT_LIMIT=1 "$W"
ok "deadline: the held TODO, once per episode" '[ "$(rc "$tmp/o29")" = 3 ]' "rc=$(rc "$tmp/o29") $(cat "$tmp/o29")"
# The same wake counts an answered card waiting in QUESTIONS for a server (card UD2L732X).
mkdir -p "$T/cards/AnsH1111"
echo '[{"id":"h3","type":"commentCard","date":"'"$(iso $((now - 10)))"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"ANSWERED: go; waiting for a test server"}},{"id":"h2","type":"commentCard","date":"'"$(iso $((now - 20)))"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"USER REPLY: go"}},{"id":"h1","type":"commentCard","date":"'"$(iso $((now - 40)))"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"BLOCKED: which? From: TODO"}}]' >"$T/cards/AnsH1111/actions"
cards '[{"id":"ah","name":"Answered, waiting","idList":"lq","idLabels":[],"idMembers":[],"shortLink":"AnsH1111"}]'
python3 -I - "$tmp/state.json" <<'PY'
import json, sys, time
f = sys.argv[1]; s = json.load(open(f)); s["marks"].pop("todo-held", None)
s["marks"]["todo-held-since"] = time.time() - 7260; s["last_slow"] = 0
json.dump(s, open(f, "w"))
PY
run "$tmp/o29c" env BOARD_WAIT_LIMIT=2 "$W"
run "$tmp/o29d" env BOARD_WAIT_LIMIT=2 "$W"
ok "deadline: an answered card waiting in QUESTIONS for a server counts as held" 'grep -qx "DEADLINE: startable cards have waited 2 hours for a card test server" "$tmp/o29c" "$tmp/o29d"' "rc=$(rc "$tmp/o29c") $(cat "$tmp/o29c" "$tmp/o29d")"
cards '[]'

# 9d. The labels are the script's. Its own state file, so the cases above are not disturbed.
W2() { env BOARD_WAIT_STATE=$tmp/state-labels.json "$@"; }
writes() { cat "$tmp/writes.log" 2>/dev/null; }
reset_writes() { : >"$tmp/writes.log"; }
ACT=000000000000000000000021 NOA=000000000000000000000023
printf 'test-server-1 Busy1111\ntest-server-2 Busy2222\ntest-server-3 Busy3333\n' >"$tmp/servers"
: >"$tmp/waiting"
# Active: on for a card with a live agent (including the merger's card), off for one whose agent reported; a status card is left alone.
cards '[{"id":"idLive","name":"Live card","idList":"lb","idLabels":[],"idMembers":[],"shortLink":"LivE1111"},
        {"id":"idOld","name":"Old card","idList":"lb","idLabels":["'"$ACT"'"],"idMembers":[],"shortLink":"OldA1111"},
        {"id":"idMrg","name":"Merging card","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"MerG1111"},
        {"id":"idMrgB","name":"Merging card in work","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"MerG3333"},
        {"id":"idSta","name":"⛔ BLOCKED: a status card","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"StaT2222"}]'
for k in LivE1111 OldA1111 MerG1111 MerG3333 StaT2222; do mkdir -p "$T/cards/$k"; echo '[]' >"$T/cards/$k/actions"; done
printf 'running card-manager card=LivE1111 id=a1 last=3s children=0 reqs=3 ctx=1000 - /x\nreported card-manager card=OldA1111 id=a2 last=3s children=0 reqs=3 ctx=1000 - /x\nrunning merger card=MerG1111 id=a3 last=3s children=0 reqs=3 ctx=1000 start=1000 card_from=call - /x\nrunning workflow-builder card=StaT2222 id=a4 last=3s children=0 reqs=1 ctx=1 - /x\n' >"$tmp/agents"
reset_writes
rm -rf "$tmp/active"; mkdir -p "$tmp/active"
run "$tmp/l1" W2 BOARD_WAIT_LIMIT=1 "$W"
ok "labels: Actively worked goes on a card with a live agent" 'gw -qx "POST /cards/idLive/idLabels $ACT"' "$(writes)"
ok "labels: a live merger that wrote no file labels no card, not even the card of its newest call (queued cards stay unlabelled)" '! gw -q "idMrg"' "$(writes)"
# The merger's file names the card in work (MerG3333); its card= (MerG1111, a queued card it only read) stays unlabelled.
"$bin/active-card.sh" merger MerG3333 >/dev/null
reset_writes
run "$tmp/l1m" W2 BOARD_WAIT_LIMIT=1 "$W"
ok "labels: only the card in the merger's file is labelled" 'gw -qx "POST /cards/idMrgB/idLabels $ACT" && ! gw -q "idMrg/"' "$(writes)"
# A file older than the live merger (a merger killed mid-card) names no card.
python3 -c "import os,sys; os.utime(sys.argv[1], (900, 900))" "$tmp/active/merger"
reset_writes
run "$tmp/l1n" W2 BOARD_WAIT_LIMIT=1 "$W"
ok "labels: a merger file older than the live merger's start labels nothing" '! gw -q "idMrg"' "$(writes)"
ok "labels: Actively worked comes off a card whose agent reported" 'gw -qx "DELETE /cards/idOld/idLabels/$ACT"' "$(writes)"
ok "labels: a status card is left alone" '! gw -q idSta' "$(writes)"
cards '[{"id":"idLive","name":"Live card","idList":"lb","idLabels":["'"$ACT"'"],"idMembers":[],"shortLink":"LivE1111"}]'
reset_writes
run "$tmp/l1b" W2 BOARD_WAIT_LIMIT=1 "$W"
ok "labels: a card that already has the label is not written again" '! gw -q idLive' "$(writes)"
# A merger's cards come from its file; a promoter's covered cards are green while the release status card reads
# "running:" (a card=-only row labels nothing). Suite card A and current card B are green, queued C is not.
cards '[{"id":"idR1","name":"Rel one","idList":"lx","idLabels":[],"idMembers":[],"shortLink":"ReL11111"},
        {"id":"idR2","name":"Rel two","idList":"lx","idLabels":[],"idMembers":[],"shortLink":"ReL22222"},
        {"id":"idR3x","name":"Rel three","idList":"lx","idLabels":[],"idMembers":[],"shortLink":"ReL33333"},
        {"id":"idRS","name":"🚀 RELEASE: running: full test","idList":"lx","idLabels":[],"idMembers":[],"shortLink":"ReLS1111"},
        {"id":"idMA","name":"Suite waiting","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"MerGAAAA"},
        {"id":"idMB","name":"Current","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"MerGBBBB"},
        {"id":"idMC","name":"Queued","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"MerGCCCC"}]'
for k in ReL11111 ReL22222 ReL33333 ReLS1111 MerGAAAA MerGBBBB MerGCCCC; do mkdir -p "$T/cards/$k"; echo '[]' >"$T/cards/$k/actions"; done
printf 'running promoter card=ReL11111 id=p1 last=3s children=0 reqs=3 ctx=1000 - /x\nrunning merger card=MerGCCCC id=a3 last=3s children=0 reqs=3 ctx=1000 start=1000 card_from=call - /x\n' >"$tmp/agents"
"$bin/active-card.sh" merger MerGAAAA MerGBBBB >/dev/null
reset_writes
run "$tmp/l1c" W2 BOARD_WAIT_LIMIT=1 "$W"
ok "labels: a release status card that reads running labels every covered card in RELEASING" 'gw -qx "POST /cards/idR1/idLabels $ACT" && gw -qx "POST /cards/idR2/idLabels $ACT" && gw -qx "POST /cards/idR3x/idLabels $ACT"' "$(writes)"
ok "labels: the release status card itself is never labelled" '! gw -q "/cards/idRS/idLabels $ACT"' "$(writes)"
ok "labels: the merger's suite card and current card are green, the queued card (its card=) is not" 'gw -qx "POST /cards/idMA/idLabels $ACT" && gw -qx "POST /cards/idMB/idLabels $ACT" && ! gw -q "idMC"' "$(writes)"
"$bin/active-card.sh" merger >/dev/null
cards '[{"id":"idMA","name":"Suite waiting","idList":"lm","idLabels":["'"$ACT"'"],"idMembers":[],"shortLink":"MerGAAAA"}]'
reset_writes
run "$tmp/l1e" W2 BOARD_WAIT_LIMIT=1 "$W"
ok "labels: a cleared merger file takes the label off the merger's cards" 'gw -qx "DELETE /cards/idMA/idLabels/$ACT"' "$(writes)"
for st in "waiting: sign-off" "waiting: you (a manual step)" "stalled: no promoter (staging deploy)" "failed" "released" "idle"; do
  cards '[{"id":"idR2","name":"Rel two","idList":"lx","idLabels":["'"$ACT"'"],"idMembers":[],"shortLink":"ReL22222"},
          {"id":"idRS","name":"🚀 RELEASE: '"$st"'","idList":"lx","idLabels":[],"idMembers":[],"shortLink":"ReLS1111"}]'
  reset_writes
  run "$tmp/l1f" W2 BOARD_WAIT_LIMIT=1 "$W"
  ok "labels: a release status card reading '$st' takes the label off the covered cards" 'gw -qx "DELETE /cards/idR2/idLabels/$ACT"' "$(writes)"
done
cards '[{"id":"idR2","name":"Rel two","idList":"lx","idLabels":["'"$ACT"'"],"idMembers":[],"shortLink":"ReL22222"},
        {"id":"idRS","name":"🚀 RELEASE: running: failing: the promoter files the 🚨 card","idList":"lx","idLabels":[],"idMembers":[],"shortLink":"ReLS1111"}]'
reset_writes
run "$tmp/l1g" W2 BOARD_WAIT_LIMIT=1 "$W"
ok "labels: running: failing: counts as running (the promoter is working the release)" '! gw -q idR2' "$(writes)"
cards '[{"id":"idR2","name":"Rel two","idList":"lx","idLabels":[],"idMembers":[],"shortLink":"ReL22222"},
        {"id":"idP1","name":"Promoter read","idList":"lb","idLabels":[],"idMembers":[],"shortLink":"PrmR1111"},
        {"id":"idV1","name":"Verifier prompt card","idList":"lb","idLabels":[],"idMembers":[],"shortLink":"VerP1111"},
        {"id":"idV2","name":"Verifier read card","idList":"lb","idLabels":[],"idMembers":[],"shortLink":"VerR2222"}]'
for k in PrmR1111 VerP1111 VerR2222; do mkdir -p "$T/cards/$k"; echo '[]' >"$T/cards/$k/actions"; done
printf 'running promoter card=PrmR1111 id=p1 last=3s children=0 reqs=3 ctx=1000 start=1000 card_from=call - /x\nrunning workflow-verifier card=VerP1111 id=v1 last=3s children=0 reqs=3 ctx=1000 start=1000 card_from=prompt - /x\nrunning workflow-verifier card=VerR2222 id=v2 last=3s children=0 reqs=3 ctx=1000 start=1000 card_from=call - /x\n' >"$tmp/agents"
reset_writes
run "$tmp/l1h" W2 BOARD_WAIT_LIMIT=1 "$W"
ok "labels: a workflow verifier's card from its prompt is green; a card it only read last (drift check) is not" 'gw -qx "POST /cards/idV1/idLabels $ACT" && ! gw -q "idV2"' "$(writes)"
ok "labels: a promoter's card= (its newest call) labels nothing, and no release status card means no covered card is green" '! gw -q "idP1" && ! gw -q "idR2"' "$(writes)"
cards '[{"id":"idR2","name":"Rel two","idList":"lx","idLabels":["'"$ACT"'"],"idMembers":[],"shortLink":"ReL22222"}]'
# Blocked and No action required, from the status comments.
cm() { echo '[{"date":"2026-10-15T0'"$1"':00:00.000Z","idMemberCreator":"'"${3:-$CLAUDE}"'","data":{"text":"'"$2"'"}}]'; }
cards '[{"id":"idWo","name":"Waits on a card","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"WaoC1111"},
        {"id":"idWy","name":"Waits on you","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"WayU1111"},
        {"id":"idQ","name":"A question","idList":"lq","idLabels":[],"idMembers":[],"shortLink":"QueS1111"},
        {"id":"idUb","name":"Unblocked","idList":"lt","idLabels":["'"$BLOCKED"'","'"$NOA"'"],"idMembers":[],"shortLink":"UnbL1111"},
        {"id":"idNo","name":"No status comment","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"NoSt1111"},
        {"id":"idSw","name":"⛔ BLOCKED: status","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"StaW1111"},
        {"id":"idAn","name":"Answered question","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"AnsW1111"},
        {"id":"idWa","name":"Wrong account after a question","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"WrgA1111"}]'
for k in WaoC1111 WayU1111 QueS1111 UnbL1111 NoSt1111 StaW1111 AnsW1111 WrgA1111; do mkdir -p "$T/cards/$k"; done
cm 9 "WAITS FOR: The other card (#40), for its endpoint" >"$T/cards/WaoC1111/actions"
cm 9 "WAITS FOR: you: apply the settings section. Check: test -f x" >"$T/cards/WayU1111/actions"
cm 9 "BLOCKED: which option? From: BUILDING" >"$T/cards/QueS1111/actions"
echo '[{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"WAITS FOR: x"}},{"date":"2026-10-15T10:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"UNBLOCKED: x merged"}}]' >"$T/cards/UnbL1111/actions"
echo '[]' >"$T/cards/NoSt1111/actions"
cm 9 "WAITS FOR: you: x" >"$T/cards/StaW1111/actions"
echo '[{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"BLOCKED: which option? From: BUILDING"}},{"date":"2026-10-15T10:00:00.000Z","idMemberCreator":"'"$USER"'","data":{"text":"FULL SUITE FAILED: main @ a, development @ b: x"}}]' >"$T/cards/WrgA1111/actions"
echo '[{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"BLOCKED: which option? From: BUILDING"}},{"date":"2026-10-15T10:00:00.000Z","idMemberCreator":"'"$USER"'","data":{"text":"Option 2"}}]' >"$T/cards/AnsW1111/actions"
: >"$tmp/agents"
reset_writes
run "$tmp/l2" W2 BOARD_WAIT_LIMIT=1 "$W"
ok "blocked label: a WAITS FOR: names a card: Blocked and No action required go on" 'gw -qx "POST /cards/idWo/idLabels $BLOCKED" && gw -qx "POST /cards/idWo/idLabels $NOA"' "$(writes)"
ok "blocked label: the BLOCKED: line follows in the same wake" 'grep -qx "BLOCKED: \"Waits on a card\" \[WaoC1111\] (TODO) has the Blocked label" "$tmp/l2"' "$(cat "$tmp/l2")"
ok "blocked label: WAITS FOR: you gets Blocked but not No action required" 'gw -qx "POST /cards/idWy/idLabels $BLOCKED" && ! gw -q "idWy/idLabels $NOA"' "$(writes)"
ok "blocked label: a BLOCKED: question gets Blocked but not No action required" 'gw -qx "POST /cards/idQ/idLabels $BLOCKED" && ! gw -q "idQ/idLabels $NOA"' "$(writes)"
ok "blocked label: UNBLOCKED: takes both labels off" 'gw -qx "DELETE /cards/idUb/idLabels/$BLOCKED" && gw -qx "DELETE /cards/idUb/idLabels/$NOA"' "$(writes)"
ok "blocked label: a card with no status comment keeps its label" '! gw -q idNo' "$(writes)"
ok "blocked label: a status card is left alone" '! gw -q idSw' "$(writes)"
ok "blocked label: the user's answer takes the label off a BLOCKED: question" 'gw -qx "DELETE /cards/idAn/idLabels/$BLOCKED"' "$(writes)"
# A wait on the user replaces a wait on a card: purple off, red stays. The stream path (a comment after the cursor) sets the state too.
cards '[{"id":"idSw2","name":"Switches","idList":"lt","idLabels":["'"$BLOCKED"'","'"$NOA"'"],"idMembers":[],"shortLink":"SwiT1111"}]'
mkdir -p "$T/cards/SwiT1111"; echo '[]' >"$T/cards/SwiT1111/actions"
later9=$(iso $((now + 900)))
actions '[{"id":"a90","type":"commentCard","date":"'"$later9"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"WAITS FOR: you: log in. Check: x","card":{"name":"Switches","shortLink":"SwiT1111"},"list":{"name":"TODO"}}}]'
reset_writes
run "$tmp/l3" W2 BOARD_WAIT_LIMIT=1 "$W"
ok "wrong account: a non-Claude FULL SUITE FAILED: after a BLOCKED: does not count as the user's answer (first read: Blocked stays)" '! gw -q "idWa/idLabels"' "$(writes)"
ok "blocked label: a new WAITS FOR: you takes No action required off and leaves Blocked" 'gw -qx "DELETE /cards/idSw2/idLabels/$NOA" && ! gw -q "idSw2/idLabels/$BLOCKED"' "$(writes)"
actions '[]'
# NEXT FOR YOU: (the user's step waits on agent work) turns No action required on, READY FOR YOU: turns it off and
# prints a line for the main session; Blocked stays on both.
cards '[{"id":"idNx","name":"Step waits on agents","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"NexT1111"}]'
mkdir -p "$T/cards/NexT1111"
echo '[{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"WAITS FOR: you: step 5, deploy. Check: x"}},{"date":"2026-10-15T10:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"NEXT FOR YOU: step 5, after the server builder merges development"}}]' >"$T/cards/NexT1111/actions"
reset_writes
run "$tmp/l3b" W2 BOARD_WAIT_LIMIT=1 "$W"
ok "next for you: purple goes on, Blocked stays" 'gw -qx "POST /cards/idNx/idLabels $NOA" && ! gw -q "idNx/idLabels/$BLOCKED"' "$(writes)"
cards '[{"id":"idNx","name":"Step waits on agents","idList":"lt","idLabels":["'"$BLOCKED"'","'"$NOA"'"],"idMembers":[],"shortLink":"NexT1111"}]'
later10=$(iso $((now + 960)))
actions '[{"id":"a91","type":"commentCard","date":"'"$later10"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"READY FOR YOU: step 5","card":{"name":"Step waits on agents","shortLink":"NexT1111"},"list":{"name":"TODO"}}}]'
reset_writes
run "$tmp/l3c" W2 BOARD_WAIT_LIMIT=2 "$W"
ok "ready for you: purple comes off, Blocked stays" 'gw -qx "DELETE /cards/idNx/idLabels/$NOA" && ! gw -q "idNx/idLabels/$BLOCKED"' "$(writes)"
ok "ready for you: the main session is told once" 'grep -qx "READY FOR YOU: \"Step waits on agents\" \[NexT1111\] (TODO): step 5" "$tmp/l3c"' "$(cat "$tmp/l3c")"
actions '[]'
# The user's answer (design (b), "[AGENTS] An answered card stays Blocked until someone posts UNBLOCKED:"
# https://trello.com/c/tpH5J4nu): the user's USER REPLY or own comment ends a BLOCKED:, a NEXT FOR YOU: and a
# READY FOR YOU: at once, and never a WAITS FOR:, which waits for the watcher's UNBLOCKED:. "USER REPLY (<note>):"
# counts as "USER REPLY:", and an UNBLOCKED: or RESOLVED: line inside it counts as its own comment
# ("🪲 [AGENTS] board-wait.sh leaves a stale Blocked label on a card in MERGED" https://trello.com/c/2CXsUdZa).
# First from the card's comments (a card the stream has not shown yet), newest last in each fixture.
c2() { echo '[{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"'"$1"'"}},{"date":"2026-10-15T10:00:00.000Z","idMemberCreator":"'"${3:-$CLAUDE}"'","data":{"text":"'"$2"'"}}]'; }
cards '[{"id":"idR1","name":"Old reply form","idList":"ld","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"RepA1111"},
        {"id":"idR2","name":"Reply on a wait","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"RepB1111"},
        {"id":"idR3","name":"Reply unblocks a wait","idList":"lm","idLabels":["'"$BLOCKED"'","'"$NOA"'"],"idMembers":[],"shortLink":"RepC1111"},
        {"id":"idR4","name":"Reply on next","idList":"lb","idLabels":["'"$BLOCKED"'","'"$NOA"'"],"idMembers":[],"shortLink":"RepD1111"},
        {"id":"idR5","name":"Reply on ready","idList":"lb","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"RepE1111"},
        {"id":"idR6","name":"Agent note quoting UNBLOCKED","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"RepF1111"}]'
for k in RepA1111 RepB1111 RepC1111 RepD1111 RepE1111 RepF1111 RepG1111 RepH1111; do mkdir -p "$T/cards/$k"; done
c2 "BLOCKED: which track? From: BUILDING" 'USER REPLY (2026-10-16): Closed beta.\n\nUNBLOCKED: both targets are settled.' >"$T/cards/RepA1111/actions"
c2 "WAITS FOR: you: apply section 23. Check: x" "USER REPLY: done" >"$T/cards/RepB1111/actions"
c2 "WAITS FOR: The other card (#40)" 'USER REPLY (2026-10-16): it merged\nUNBLOCKED: #40 merged' >"$T/cards/RepC1111/actions"
c2 "NEXT FOR YOU: step 5, after the builder merges main" "USER REPLY: go ahead without me" >"$T/cards/RepD1111/actions"
c2 "READY FOR YOU: step 5" "USER REPLY (from chat): done" >"$T/cards/RepE1111/actions"
c2 "WAITS FOR: you: log in. Check: x" 'Note for the builder.\nUNBLOCKED: is what the watcher will post' >"$T/cards/RepF1111/actions"
c2 "WAITS FOR: you: log in. Check: x" "done" "$USER" >"$T/cards/RepG1111/actions"
c2 "READY FOR YOU: step 5" "done" "$USER" >"$T/cards/RepH1111/actions"
reset_writes
run "$tmp/r1" W2 BOARD_WAIT_LIMIT=1 "$W"
ok "user reply: \"USER REPLY (<date>):\" with an UNBLOCKED: line takes Blocked off (a card in MERGED)" 'gw -qx "DELETE /cards/idR1/idLabels/$BLOCKED"' "$(writes)"
ok "user reply: a USER REPLY never ends a WAITS FOR: you" '! gw -q "idR2/idLabels"' "$(writes)"
ok "user reply: an UNBLOCKED: line inside a USER REPLY ends a WAITS FOR: (both labels off)" 'gw -qx "DELETE /cards/idR3/idLabels/$BLOCKED" && gw -qx "DELETE /cards/idR3/idLabels/$NOA"' "$(writes)"
ok "user reply: a USER REPLY ends a NEXT FOR YOU: (both labels off)" 'gw -qx "DELETE /cards/idR4/idLabels/$BLOCKED" && gw -qx "DELETE /cards/idR4/idLabels/$NOA"' "$(writes)"
ok "user reply: \"USER REPLY (<note>):\" ends a READY FOR YOU:" 'gw -qx "DELETE /cards/idR5/idLabels/$BLOCKED"' "$(writes)"
ok "user reply: an UNBLOCKED: line in an agent comment that is not a USER REPLY changes nothing" '! gw -q "idR6/idLabels"' "$(writes)"
# bootstrap_blocks reads at most 6 cards' comments per check, so the person's-comment cases are a second run.
cards '[{"id":"idR7","name":"Person on a wait","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"RepG1111"},
        {"id":"idR8","name":"Person on ready","idList":"lb","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"RepH1111"}]'
reset_writes
run "$tmp/r1b" W2 BOARD_WAIT_LIMIT=1 "$W"
ok "user reply: a person's comment never ends a WAITS FOR:" '! gw -q "idR7/idLabels"' "$(writes)"
ok "user reply: a person's comment ends a READY FOR YOU:" 'gw -qx "DELETE /cards/idR8/idLabels/$BLOCKED"' "$(writes)"
# Then from the stream (comments after the cursor), on cards whose state it already holds.
cards '[{"id":"idR2","name":"Reply on a wait","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"RepB1111"},
        {"id":"idS1","name":"Stream ready","idList":"lb","idLabels":[],"idMembers":[],"shortLink":"StrA1111"},
        {"id":"idS2","name":"Stream old form","idList":"ld","idLabels":[],"idMembers":[],"shortLink":"StrB1111"}]'
for k in StrA1111 StrB1111; do mkdir -p "$T/cards/$k"; echo '[]' >"$T/cards/$k/actions"; done
later11=$(iso $((now + 1020))) later12=$(iso $((now + 1030)))
actions '[{"id":"a95","type":"commentCard","date":"'"$later11"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"READY FOR YOU: step 2","card":{"name":"Stream ready","shortLink":"StrA1111"},"list":{"name":"BUILDING"}}},
          {"id":"a96","type":"commentCard","date":"'"$later11"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"WAITS FOR: The other card (#41)","card":{"name":"Stream old form","shortLink":"StrB1111"},"list":{"name":"MERGED"}}}]'
reset_writes
run "$tmp/r2" W2 BOARD_WAIT_LIMIT=2 "$W"
ok "user reply (stream): READY FOR YOU: and WAITS FOR: put Blocked on" 'gw -qx "POST /cards/idS1/idLabels $BLOCKED" && gw -qx "POST /cards/idS2/idLabels $BLOCKED"' "$(writes)"
cards '[{"id":"idR2","name":"Reply on a wait","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"RepB1111"},
        {"id":"idS1","name":"Stream ready","idList":"lb","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"StrA1111"},
        {"id":"idS2","name":"Stream old form","idList":"ld","idLabels":["'"$BLOCKED"'","'"$NOA"'"],"idMembers":[],"shortLink":"StrB1111"}]'
actions '[{"id":"a97","type":"commentCard","date":"'"$later12"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"USER REPLY: done","card":{"name":"Stream ready","shortLink":"StrA1111"},"list":{"name":"BUILDING"}}},
          {"id":"a98","type":"commentCard","date":"'"$later12"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"USER REPLY (2026-10-16): it merged\n\nUNBLOCKED: #41 merged","card":{"name":"Stream old form","shortLink":"StrB1111"},"list":{"name":"MERGED"}}},
          {"id":"a99","type":"commentCard","date":"'"$later12"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"USER REPLY: later","card":{"name":"Reply on a wait","shortLink":"RepB1111"},"list":{"name":"TODO"}}}]'
reset_writes
run "$tmp/r3" W2 BOARD_WAIT_LIMIT=2 "$W"
ok "user reply (stream): a USER REPLY ends a READY FOR YOU:" 'gw -qx "DELETE /cards/idS1/idLabels/$BLOCKED"' "$(writes)"
ok "user reply (stream): an UNBLOCKED: line inside \"USER REPLY (<date>):\" ends a WAITS FOR:" 'gw -qx "DELETE /cards/idS2/idLabels/$BLOCKED" && gw -qx "DELETE /cards/idS2/idLabels/$NOA"' "$(writes)"
ok "user reply (stream): a USER REPLY on a WAITS FOR: you leaves Blocked on" '! gw -q "idR2/idLabels"' "$(writes)"
ok "user reply (stream): \"USER REPLY (<date>):\" wakes the watcher" 'grep -q "^COMMENT (user): \"Stream old form\" \[StrB1111\] (MERGED): USER REPLY (2026-10-16): it merged" "$tmp/r3"' "$(cat "$tmp/r3")"
actions '[]'
# Only the older "USER REPLY (<note>):" form carries a line that clears: an UNBLOCKED: or RESOLVED: line in a plain
# "USER REPLY:" never ends a WAITS FOR: (the watcher's check comes first). From the card's comments, then the stream.
cards '[{"id":"idP1","name":"Plain reply quoting UNBLOCKED","idList":"lm","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"PlnA1111"}]'
mkdir -p "$T/cards/PlnA1111"
c2 "WAITS FOR: you: apply section 23. Check: x" 'USER REPLY: done\n\nUNBLOCKED: applied' >"$T/cards/PlnA1111/actions"
reset_writes
run "$tmp/r4" W2 BOARD_WAIT_LIMIT=1 "$W"
ok "user reply: an UNBLOCKED: line in a plain USER REPLY: leaves a WAITS FOR: you Blocked" '! gw -q "idP1/idLabels"' "$(writes)"

# Another person (neither the user nor the Claude account) is never the user: their comment, a "USER REPLY:" text
# included, answers nothing and clears nothing. From the card's comments (bootstrap), then from the stream.
OTHER=aaaaaaaaaaaaaaaaaaaaaaaa
cards '[{"id":"idO1","name":"Other on a question","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"OthA1111"},
        {"id":"idO2","name":"Other old form on a wait","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"OthB1111"},
        {"id":"idO3","name":"User on a question","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"OthC1111"},
        {"id":"idO4","name":"Other on a next","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"OthD1111"},
        {"id":"idO5","name":"Other on a ready","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"OthE1111"}]'
mkdir -p "$T/cards/OthA1111" "$T/cards/OthB1111" "$T/cards/OthC1111" "$T/cards/OthD1111" "$T/cards/OthE1111"
c2 "NEXT FOR YOU: step 5, after the builder merges main" "done" "$OTHER" >"$T/cards/OthD1111/actions"
c2 "READY FOR YOU: step 5" "done" "$OTHER" >"$T/cards/OthE1111/actions"
c2 "BLOCKED: which layout?" 'USER REPLY: done' "$OTHER" >"$T/cards/OthA1111/actions"
c2 "WAITS FOR: The other card (#41)" 'USER REPLY (2026-10-16): ok\n\nUNBLOCKED: merged' "$OTHER" >"$T/cards/OthB1111/actions"
c2 "BLOCKED: which layout?" 'the tablet one' "$USER" >"$T/cards/OthC1111/actions"
reset_writes
run "$tmp/ro1" W2 BOARD_WAIT_LIMIT=1 "$W"
ok "other person (bootstrap): a USER REPLY: text from another account leaves a BLOCKED: Blocked" '! gw -q "idO1/idLabels"' "$(writes)"
ok "other person (bootstrap): a USER REPLY (<note>): with UNBLOCKED: from another account leaves a WAITS FOR: Blocked" '! gw -q "DELETE /cards/idO2/idLabels"' "$(writes)"
ok "other person (bootstrap): the user's own comment still ends a BLOCKED:" 'gw -qx "DELETE /cards/idO3/idLabels/$BLOCKED"' "$(writes)"
ok "other person (bootstrap): a comment from another account leaves a NEXT FOR YOU: Blocked" '! gw -q "DELETE /cards/idO4/idLabels/$BLOCKED"' "$(writes)"
ok "other person (bootstrap): a comment from another account leaves a READY FOR YOU: Blocked" '! gw -q "idO5/idLabels"' "$(writes)"
cards '[{"id":"idO1","name":"Other on a question","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"OthA1111"},
        {"id":"idO2","name":"Other old form on a wait","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"OthB1111"}]'
lo=$(iso $((now + 1045)))
actions '[{"id":"o01","type":"commentCard","date":"'"$lo"'","idMemberCreator":"'"$OTHER"'","data":{"text":"USER REPLY: done","card":{"name":"Other on a question","shortLink":"OthA1111"},"list":{"name":"TODO"}}},
          {"id":"o02","type":"commentCard","date":"'"$lo"'","idMemberCreator":"'"$OTHER"'","data":{"text":"USER REPLY (x): ok\n\nUNBLOCKED: merged","card":{"name":"Other old form on a wait","shortLink":"OthB1111"},"list":{"name":"TODO"}}}]'
reset_writes
run "$tmp/ro2" W2 BOARD_WAIT_LIMIT=2 "$W"
ok "other person (stream): a USER REPLY: text from another account leaves a BLOCKED: Blocked" '! gw -q "idO1/idLabels"' "$(writes)"
ok "other person (stream): a USER REPLY (<note>): with UNBLOCKED: from another account leaves a WAITS FOR: Blocked" '! gw -q "DELETE /cards/idO2/idLabels"' "$(writes)"
ok "other person (stream): both print COMMENT (other): and not COMMENT (user):" 'grep -qx "COMMENT (other): \"Other on a question\" \[OthA1111\] (TODO): USER REPLY: done" "$tmp/ro2" && ! grep -q "COMMENT (user)" "$tmp/ro2"' "$(cat "$tmp/ro2")"
actions '[]'
# Stream path: the state is held from the card's own comments (one run), then comments after the cursor arrive.
cards '[{"id":"idO6","name":"Other stream next","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"OthF1111"},
        {"id":"idO7","name":"Other stream ready","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"OthG1111"},
        {"id":"idO8","name":"User stream question","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"OthH1111"}]'
mkdir -p "$T/cards/OthF1111" "$T/cards/OthG1111" "$T/cards/OthH1111"
echo '[{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"NEXT FOR YOU: step 5, after the builder merges main"}}]' >"$T/cards/OthF1111/actions"
echo '[{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"READY FOR YOU: step 5"}}]' >"$T/cards/OthG1111/actions"
echo '[{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"BLOCKED: which layout?"}}]' >"$T/cards/OthH1111/actions"
reset_writes
run "$tmp/ro3" W2 BOARD_WAIT_LIMIT=1 "$W"
lo2=$(iso $((now + 1070)))
actions '[{"id":"o03","type":"commentCard","date":"'"$lo2"'","idMemberCreator":"'"$OTHER"'","data":{"text":"done","card":{"name":"Other stream next","shortLink":"OthF1111"},"list":{"name":"TODO"}}},
          {"id":"o04","type":"commentCard","date":"'"$lo2"'","idMemberCreator":"'"$OTHER"'","data":{"text":"done","card":{"name":"Other stream ready","shortLink":"OthG1111"},"list":{"name":"TODO"}}},
          {"id":"o05","type":"commentCard","date":"'"$lo2"'","idMemberCreator":"'"$USER"'","data":{"text":"the tablet one","card":{"name":"User stream question","shortLink":"OthH1111"},"list":{"name":"TODO"}}}]'
reset_writes
run "$tmp/ro4" W2 BOARD_WAIT_LIMIT=2 "$W"
ok "other person (stream): a comment from another account leaves a NEXT FOR YOU: Blocked" '! gw -q "DELETE /cards/idO6/idLabels/$BLOCKED"' "$(writes)"
ok "other person (stream): a comment from another account leaves a READY FOR YOU: Blocked" '! gw -q "idO7/idLabels"' "$(writes)"
ok "other person (stream): the user's own plain comment ends a BLOCKED:" 'gw -qx "DELETE /cards/idO8/idLabels/$BLOCKED"' "$(writes)"
actions '[]'
cards '[{"id":"idR2","name":"Reply on a wait","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"RepB1111"},
        {"id":"idS3","name":"Stream later","idList":"lm","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"StrC1111"}]'
mkdir -p "$T/cards/StrC1111"; echo '[]' >"$T/cards/StrC1111/actions"
later13=$(iso $((now + 1040))) later14=$(iso $((now + 1050))) later15=$(iso $((now + 1060)))
actions '[{"id":"b01","type":"commentCard","date":"'"$later13"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"USER REPLY: done\n\nRESOLVED: applied","card":{"name":"Reply on a wait","shortLink":"RepB1111"},"list":{"name":"TODO"}}},
          {"id":"b02","type":"commentCard","date":"'"$later13"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"READY FOR YOU: merge step 3","card":{"name":"Stream later","shortLink":"StrC1111"},"list":{"name":"MERGING"}}}]'
reset_writes
run "$tmp/r5" W2 BOARD_WAIT_LIMIT=2 "$W"
ok "user reply (stream): a RESOLVED: line in a plain USER REPLY: leaves a WAITS FOR: you Blocked" '! gw -q "idR2/idLabels"' "$(writes)"
# A reply to a READY FOR YOU: that is not the step done ("later"): the label comes off with the answer, and the
# watcher's WAITS FOR: you: <the step> puts it back on, so a step due before the merge still holds the card.
actions '[{"id":"b03","type":"commentCard","date":"'"$later14"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"USER REPLY: later","card":{"name":"Stream later","shortLink":"StrC1111"},"list":{"name":"MERGING"}}}]'
reset_writes
run "$tmp/r6" W2 BOARD_WAIT_LIMIT=2 "$W"
ok "user reply (stream): \"later\" on a READY FOR YOU: takes Blocked off" 'gw -qx "DELETE /cards/idS3/idLabels/$BLOCKED"' "$(writes)"
cards '[{"id":"idS3","name":"Stream later","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"StrC1111"}]'
actions '[{"id":"b04","type":"commentCard","date":"'"$later15"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"WAITS FOR: you: merge step 3. Check: x","card":{"name":"Stream later","shortLink":"StrC1111"},"list":{"name":"MERGING"}}}]'
reset_writes
run "$tmp/r7" W2 BOARD_WAIT_LIMIT=2 "$W"
ok "user reply (stream): the watcher's WAITS FOR: you after \"later\" puts Blocked back (no purple)" 'gw -qx "POST /cards/idS3/idLabels $BLOCKED" && ! gw -q "idS3/idLabels $NOA"' "$(writes)"
actions '[]'
# An answered [AGENTS] card in WORKFLOW 🤖 and one workflow builder per card or batch ("[AGENTS] Fresh context per task"
# https://trello.com/c/T7JSwpI6): the USER REPLY to its BLOCKED: question takes Blocked off in the same poll, so the card
# is workflow work again unless a live workflow builder has it in its batch (cards=), even as its second card.
cards '[{"id":"idWq","name":"[AGENTS] Asks the user","idList":"lw","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"WfAsk111"}]'
mkdir -p "$T/cards/WfAsk111"
echo '[{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"BLOCKED: which design? From: WORKFLOW 🤖"}}]' >"$T/cards/WfAsk111/actions"
echo "running workflow-builder card=OthR1111 id=wq1 last=3s children=0 reqs=1 ctx=1 cards=OthR1111,WfAsk111 - /x" >"$tmp/agents"
reset_writes
run "$tmp/r8" W2 BOARD_WAIT_LIMIT=2 "$W"
ok "user reply + batch: a BLOCKED: [AGENTS] card keeps its label and is no workflow work" '! gw -q "idWq/idLabels.*$BLOCKED" && ! grep -q "workflow work waiting" "$tmp/r8"' "$(writes) $(cat "$tmp/r8")"
later16=$(iso $((now + 1070)))
actions '[{"id":"b05","type":"commentCard","date":"'"$later16"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"USER REPLY: option (b)","card":{"name":"[AGENTS] Asks the user","shortLink":"WfAsk111"},"list":{"name":"WORKFLOW 🤖"}}}]'
reset_writes
run "$tmp/r9" W2 BOARD_WAIT_LIMIT=2 "$W"
ok "user reply + batch: the answer takes Blocked off; the card is its live builder's batch card, not workflow work" 'gw -qx "DELETE /cards/idWq/idLabels/$BLOCKED" && ! grep -q "workflow work waiting" "$tmp/r9"' "$(writes) $(cat "$tmp/r9")"
actions '[]'
cards '[{"id":"idWq","name":"[AGENTS] Asks the user","idList":"lw","idLabels":[],"idMembers":[],"shortLink":"WfAsk111"}]'
: >"$tmp/agents"
run "$tmp/r10" W2 BOARD_WAIT_LIMIT=2 "$W"
ok "user reply + batch: with no builder on it, the answered card is workflow work" 'grep -qx "DEADLINE: workflow work waiting: WfAsk111" "$tmp/r10" && ! gw -q "POST /cards/idWq/idLabels $BLOCKED"' "$(writes) $(cat "$tmp/r10")"
cards '[]'
# A state file saved under the older rules ("🪲 [AGENTS] board-wait.sh leaves a stale Blocked label on a card in
# MERGED" https://trello.com/c/2CXsUdZa): a card answered in the old form before the cursor still holds 'q'. Its states
# are dropped once and every card's comments read again, so the label comes off (and is not put back) on restart.
W3() { env BOARD_WAIT_STATE=$tmp/state-migrate.json "$@"; }
python3 -I - "$tmp/state-migrate.json" "$(iso $((now + 2000)))" <<'PY2'
import json, sys
json.dump({"cursor": sys.argv[2], "marks": {"blocked:MigA1111": 1, "blocked:MigB1111": 1}, "last_slow": 0,
           "block": {"MigA1111": "q", "MigB1111": "q", "MigC1111": "off"}}, open(sys.argv[1], "w"))
PY2
cards '[{"id":"idM1","name":"Old state, label off","idList":"ld","idLabels":[],"idMembers":[],"shortLink":"MigA1111"},
        {"id":"idM2","name":"Old state, label on","idList":"ld","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"MigB1111"},
        {"id":"idM3","name":"Old state off, now waits","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"MigC1111"}]'
for k in MigA1111 MigB1111 MigC1111 MigD1111; do mkdir -p "$T/cards/$k"; done
c2 "BLOCKED: which track? From: BUILDING" 'USER REPLY (2026-10-16): Closed beta.\n\nUNBLOCKED: both targets are settled.' >"$T/cards/MigA1111/actions"
cp "$T/cards/MigA1111/actions" "$T/cards/MigB1111/actions"
c2 "UNBLOCKED: x" "WAITS FOR: The other card (#40)" >"$T/cards/MigC1111/actions"
reset_writes
run "$tmp/m1" W3 BOARD_WAIT_LIMIT=1 "$W"
ok "old state: a saved 'q' answered in the old form before the cursor never gets Blocked back" '! gw -q "idM1/idLabels"' "$(writes)"
ok "old state: a saved 'q' answered in the old form loses its Blocked label" 'gw -qx "DELETE /cards/idM2/idLabels/$BLOCKED"' "$(writes)"
ok "old state: every card is read again (a saved 'off' that now waits gets Blocked)" 'gw -qx "POST /cards/idM3/idLabels $BLOCKED"' "$(writes)"
ok "old state: the marker is saved" 'python3 -I -c "import json,sys; s=json.load(open(sys.argv[1])); sys.exit(0 if s.get(\"block_rules\") == 2 and s[\"block\"].get(\"MigA1111\") == \"off\" else 1)" "$tmp/state-migrate.json"' "$(cat "$tmp/state-migrate.json")"
# Once: with the marker saved, a state is kept, not read again.
python3 -I -c 'import json,sys; p=sys.argv[1]; s=json.load(open(p)); s["block"]["MigD1111"]="q"; json.dump(s,open(p,"w"))' "$tmp/state-migrate.json"
cards '[{"id":"idM4","name":"New state kept","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"MigD1111"}]'
c2 "BLOCKED: which track? From: BUILDING" "Option 2" "$USER" >"$T/cards/MigD1111/actions"
reset_writes
run "$tmp/m2" W3 BOARD_WAIT_LIMIT=1 "$W"
ok "old state: states saved under the new rules are not dropped again" 'gw -qx "POST /cards/idM4/idLabels $BLOCKED"' "$(writes)"
# A card with No action required is not stuck, until what it waits on is done.
mkdir -p "$T/cards/WtDn1111"
cm 9 "WAITS FOR: The other card (#40), for its endpoint" >"$T/cards/WtDn1111/actions"
cards '[{"id":"idWd","name":"Waits then free","idList":"lb","idLabels":["'"$BLOCKED"'","'"$NOA"'"],"idMembers":[],"shortLink":"WtDn1111"},
        {"id":"idOt","name":"The other card (#40)","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"OthR2222"}]'
mkdir -p "$T/cards/OthR2222"; echo '[]' >"$T/cards/OthR2222/actions"
run "$tmp/l4" W2 BOARD_WAIT_LIMIT=1 BOARD_WAIT_STUCK_GRACE=0 BOARD_WAIT_STUCK_REPEAT=0 "$W"
ok "stuck: a card waiting on another card that is still in MERGING is not stuck" '! grep -q "^STUCK" "$tmp/l4"' "$(cat "$tmp/l4")"
cards '[{"id":"idWd","name":"Waits then free","idList":"lb","idLabels":["'"$BLOCKED"'","'"$NOA"'"],"idMembers":[],"shortLink":"WtDn1111"},
        {"id":"idOt","name":"The other card (#40)","idList":"ld","idLabels":[],"idMembers":[],"shortLink":"OthR2222"}]'
run "$tmp/l5" W2 BOARD_WAIT_LIMIT=2 BOARD_WAIT_STUCK_GRACE=0 BOARD_WAIT_STUCK_REPEAT=0 "$W"
ok "stuck: once what it waits on is done and nothing picked the card up, it is stuck" 'grep -q "^STUCK: \"Waits then free\" \[WtDn1111\] (BUILDING): what it waits for is done" "$tmp/l5"' "$(cat "$tmp/l5")"
# The incident path (2026-10-17): a Blocked + No action required card whose WAITS FOR: links an open card and
# mentions, in passing, the #N of a card in DONE is not stuck while the linked card is open.
mkdir -p "$T/cards/Lnk22222" "$T/cards/OpnL2222"; echo '[]' >"$T/cards/OpnL2222/actions"
cm 9 "WAITS FOR: [test helpers] the teardown fix, after #239 fixed https://trello.com/c/OpnL2222" >"$T/cards/Lnk22222/actions"
cards '[{"id":"idLk","name":"Waits on the open card","idList":"lb","idLabels":["'"$BLOCKED"'","'"$NOA"'"],"idMembers":[],"shortLink":"Lnk22222"},
        {"id":"idDn","name":"Fixed the teardown (#239)","desc":"**PR:** example-org/example-app#239 (the fix)","idList":"ld","idLabels":[],"idMembers":[],"shortLink":"DonL2222"},
        {"id":"idOp","name":"The open card (#275)","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"OpnL2222"}]'
run "$tmp/l6" W2 BOARD_WAIT_LIMIT=2 BOARD_WAIT_STUCK_GRACE=0 BOARD_WAIT_STUCK_REPEAT=0 "$W"
ok "stuck: a #N mentioned in passing, of a card in DONE, does not make a card that links an open card stuck" '! grep -q "^STUCK.*Lnk22222" "$tmp/l6"' "$(cat "$tmp/l6")"

# 9e. The stuck-card check. Its own state file; no grace and no repeat wait.
W3() { env BOARD_WAIT_STATE=$tmp/state-stuck.json BOARD_WAIT_STUCK_GRACE=0 BOARD_WAIT_STUCK_REPEAT=0 "$@"; }
mkdir -p "$T/cards/Idle3333" "$T/cards/Mrg4444" "$T/cards/Test5555"
for k in Idle3333 Mrg4444 Test5555; do echo '[]' >"$T/cards/$k/actions"; done
: >"$tmp/agents"; : >"$tmp/waiting"
cards '[{"id":"s1","name":"Nobody builds this","idList":"lb","idLabels":[],"idMembers":[],"shortLink":"Idle3333"},
        {"id":"s5","name":"Nobody tests this","idList":"lT","idLabels":[],"idMembers":[],"shortLink":"Test5555"}]'
lists_testing() { cat >"$T/boards/AbCd1234/lists" <<'LISTS'
[{"id":"lt","name":"TODO 📚"},{"id":"lw","name":"WORKFLOW 🤖"},{"id":"lb","name":"BUILDING"},{"id":"lT","name":"TESTING 🧪"},{"id":"lr","name":"🙋‍♂️ REVIEW 👀"},
 {"id":"lm","name":"MERGING"},{"id":"ld","name":"MERGED"},{"id":"lq","name":"🙋‍♂️ QUESTIONS ❓"}]
LISTS
}
lists_testing
run "$tmp/k1" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "stuck: a card in BUILDING with no live agent" 'grep -qx "STUCK: \"Nobody builds this\" \[Idle3333\] (BUILDING): no agent is working on it" "$tmp/k1"' "$(cat "$tmp/k1")"
ok "stuck: a card in TESTING with no live agent" 'grep -qx "STUCK: \"Nobody tests this\" \[Test5555\] (TESTING): no agent is working on it" "$tmp/k1"' "$(cat "$tmp/k1")"
run "$tmp/k1b" W3 BOARD_WAIT_LIMIT=1 BOARD_WAIT_STUCK_REPEAT=100000 "$W"
ok "stuck: not printed again before the repeat time" '! grep -q "^STUCK" "$tmp/k1b"' "$(cat "$tmp/k1b")"
echo "Idle3333 normal 1" >"$tmp/waiting"
run "$tmp/k2" W3 BOARD_WAIT_LIMIT=1 "$W"
ok "stuck: a card in BUILDING waiting for a server for its AFTER run is not stuck" '! grep -q "Idle3333" "$tmp/k2"' "$(cat "$tmp/k2")"
: >"$tmp/waiting"
printf 'running card-manager card=Idle3333 id=a5 last=5s children=0 reqs=1 ctx=1 - /x\n' >"$tmp/agents"
run "$tmp/k3" W3 BOARD_WAIT_LIMIT=1 "$W"
ok "stuck: a card with a live agent is not stuck" '! grep -q "Idle3333" "$tmp/k3"' "$(cat "$tmp/k3")"
printf 'waiting card-manager card=Idle3333 id=a5 last=2000s children=0 reqs=1 ctx=1 - /x\n' >"$tmp/agents"
run "$tmp/k4" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "stuck: a live agent quiet for 30 minutes" 'grep -qx "STUCK: \"Nobody builds this\" \[Idle3333\] (BUILDING): card-manager id=a5 has written nothing for 33 minutes" "$tmp/k4"' "$(cat "$tmp/k4")"
printf 'waiting card-manager card=Idle3333 id=a5 last=2000s children=2 reqs=1 ctx=1 - /x\n' >"$tmp/agents"
run "$tmp/k5" W3 BOARD_WAIT_LIMIT=1 "$W"
ok "stuck: a quiet agent with live child agents is waiting for them, not stuck" '! grep -q "has written nothing" "$tmp/k5"' "$(cat "$tmp/k5")"
printf 'waiting merger card=- id=m7 last=2000s children=0 reqs=1 ctx=1 background_task_b1_still_running /x\n' >"$tmp/agents"
run "$tmp/k5b" W3 BOARD_WAIT_LIMIT=1 "$W"
ok "stuck: an agent waiting for its background command is not stuck" '! grep -q "has written nothing" "$tmp/k5b"' "$(cat "$tmp/k5b")"
printf 'waiting card-manager card=Idle3333 id=a5 last=-1s children=-2 reqs=1 ctx=-5 - /x\n' >"$tmp/agents"
run "$tmp/k5c" W3 BOARD_WAIT_LIMIT=1 "$W"
ok "stuck: a negative last=-1s counts as 0, no crash, not stuck" '! grep -q "Traceback\|TypeError" "$tmp/k5c" && ! grep -q "has written nothing" "$tmp/k5c"' "$(cat "$tmp/k5c")"
# A ready card in MERGING and no merger alive.
echo '[{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"MERGE READY: example-user/example-app-old#60: NO REVIEW NEEDED"}}]' >"$T/cards/Mrg4444/actions"
cards '[{"id":"s2","name":"Ready to merge","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"Mrg4444"}]'
: >"$tmp/agents"
run "$tmp/k6" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "stuck: a MERGE READY: card in MERGING and no merger alive" 'grep -qx "STUCK: \"Ready to merge\" \[Mrg4444\] (MERGING): ready to merge and no merger is alive" "$tmp/k6"' "$(cat "$tmp/k6")"
printf 'running merger card=Mrg4444 id=m8 last=5s children=0 reqs=1 ctx=1 - /x\n' >"$tmp/agents"
run "$tmp/k7" W3 BOARD_WAIT_LIMIT=1 "$W"
ok "stuck: not when a merger is alive" '! grep -q "^STUCK" "$tmp/k7"' "$(cat "$tmp/k7")"
: >"$tmp/agents"
echo '[{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"REFRESHED: example-user/example-app-old#60: no behavior change"}},{"date":"2026-10-15T08:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"CHECK FAILED: x"}}]' >"$T/cards/Mrg4444/actions"
run "$tmp/k8" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "stuck: a REFRESHED: no behavior change card is ready too" 'grep -q "^STUCK: \"Ready to merge\" .*ready to merge" "$tmp/k8"' "$(cat "$tmp/k8")"
echo '[{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"CONFLICT RESOLVED: example-user/example-app-old#60: no behavior change (no conflict now, nothing pushed)"}},{"date":"2026-10-15T08:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"CHECK FAILED: x"}}]' >"$T/cards/Mrg4444/actions"
run "$tmp/k8b" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "stuck: a CONFLICT RESOLVED: no behavior change (no conflict now, nothing pushed) card is ready too" 'grep -q "^STUCK: \"Ready to merge\" .*ready to merge" "$tmp/k8b"' "$(cat "$tmp/k8b")"
echo '[{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"CHECK FAILED: x"}},{"date":"2026-10-15T08:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"MERGE READY: y"}}]' >"$T/cards/Mrg4444/actions"
run "$tmp/k9" W3 BOARD_WAIT_LIMIT=1 "$W"
ok "stuck: a card with CHECK FAILED: after MERGE READY: is not ready" '! grep -q "^STUCK" "$tmp/k9"' "$(cat "$tmp/k9")"
# An UNBLOCKED: ends the WAITS FOR: / BLOCKED: before it (newest_status_index): the MERGE READY: under them counts again.
cu() { echo '{"date":"'"$1"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"'"$2"'"}}'; }
echo "[$(cu 2026-10-15T12:00:00.000Z 'UNBLOCKED: x'),$(cu 2026-10-15T11:00:00.000Z 'WAITS FOR: some other card'),$(cu 2026-10-15T10:00:00.000Z 'MERGE READY: example-user/example-app-old#60: NO REVIEW NEEDED')]" >"$T/cards/Mrg4444/actions"
run "$tmp/k9u1" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "unblocked: MERGE READY:, WAITS FOR:, UNBLOCKED: is ready to merge" 'grep -q "^STUCK: \"Ready to merge\" .*ready to merge" "$tmp/k9u1"' "$(cat "$tmp/k9u1")"
echo "[$(cu 2026-10-15T12:00:00.000Z 'WAITS FOR: another card'),$(cu 2026-10-15T11:30:00.000Z 'UNBLOCKED: x'),$(cu 2026-10-15T11:00:00.000Z 'WAITS FOR: some other card'),$(cu 2026-10-15T10:00:00.000Z 'MERGE READY: example-user/example-app-old#60: NO REVIEW NEEDED')]" >"$T/cards/Mrg4444/actions"
run "$tmp/k9u2" W3 BOARD_WAIT_LIMIT=1 "$W"
ok "unblocked: a WAITS FOR: after the UNBLOCKED: is not ready" '! grep -q "^STUCK" "$tmp/k9u2"' "$(cat "$tmp/k9u2")"
echo "[$(cu 2026-10-15T12:00:00.000Z 'UNBLOCKED: x'),$(cu 2026-10-15T11:00:00.000Z 'WAITS FOR: some other card')]" >"$T/cards/Mrg4444/actions"
run "$tmp/k9u3" W3 BOARD_WAIT_LIMIT=1 "$W"
ok "unblocked: an UNBLOCKED: with no earlier MERGE READY: is not ready" '! grep -q "^STUCK" "$tmp/k9u3"' "$(cat "$tmp/k9u3")"
echo "[$(cu 2026-10-15T12:00:00.000Z 'UNBLOCKED: x'),$(cu 2026-10-15T11:00:00.000Z 'WAITS FOR: some other card'),$(cu 2026-10-15T10:00:00.000Z 'MERGE READY: example-user/example-app-old#60: NO REVIEW NEEDED')]" >"$T/cards/Mrg4444/actions"
cards '[{"id":"s2","name":"Ready to merge","idList":"lm","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"Mrg4444"}]'
run "$tmp/k9u4" W3 BOARD_WAIT_LIMIT=1 "$W"
ok "unblocked: the Blocked label still wins over a MERGE READY: past an UNBLOCKED:" '! grep -q "^STUCK: \"Ready to merge\" .*ready to merge" "$tmp/k9u4"' "$(cat "$tmp/k9u4")"
cards '[{"id":"s2","name":"Ready to merge","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"Mrg4444"}]'
# An [AGENTS] card: the newest VERIFIED:/VERIFY FAILED: for its head decides whether it is ready.
cards '[{"id":"s2a","name":"[AGENTS] Ready to merge (#35)","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"Mrg4444",
         "desc":"**PR:** example-org/example-app#35, https://github.com/example-org/example-app/pull/35 (x)"}]'
echo '{"headRefOid":"abab1212","reviews":[]}' >"$tmp/gh/example-org_example-app-35.json"
: >"$tmp/agents"
echo '[{"date":"2026-10-15T11:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"VERIFY FAILED: example-org/example-app#35 @ abab1212: x"}},{"date":"2026-10-15T10:30:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"MERGE READY: example-org/example-app#35: NO REVIEW NEEDED"}},{"date":"2026-10-15T10:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"VERIFIED: example-org/example-app#35 @ abab1212"}}]' >"$T/cards/Mrg4444/actions"
run "$tmp/k9a" W3 BOARD_WAIT_LIMIT=1 "$W"
ok "stuck: an [AGENTS] card whose newest verdict for its head is VERIFY FAILED: is not ready" '! grep -q "^STUCK" "$tmp/k9a"' "$(cat "$tmp/k9a")"
echo '[{"date":"2026-10-15T13:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"MERGE READY: example-org/example-app#35: NO REVIEW NEEDED"}},{"date":"2026-10-15T12:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"VERIFIED: example-org/example-app#35 @ abab1212"}},{"date":"2026-10-15T11:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"VERIFY FAILED: example-org/example-app#35 @ abab1212: x"}},{"date":"2026-10-15T10:30:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"MERGE READY: example-org/example-app#35: NO REVIEW NEEDED"}}]' >"$T/cards/Mrg4444/actions"
run "$tmp/k9b" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "stuck: an [AGENTS] card with a VERIFIED: and a MERGE READY: newer than the VERIFY FAILED: is ready" 'grep -q "^STUCK: .*ready to merge" "$tmp/k9b"' "$(cat "$tmp/k9b")"
# A conflict-only fix keeps the VERIFIED: (card mWg2nZnw): a head no verdict names, after a VERIFIED: at an older commit and only
# no-behavior-change CONFLICT RESOLVED:/REFRESHED: comments, is ready when verified-carry.sh says CARRIED (a fake here: it notes
# each call in carry.log and exits with the number in carry-rc). A NOT CARRIED: naming the head cancels it.
printf '#!/usr/bin/env bash\necho "$*" >>%s/carry.log\nrc=$(cat %s/carry-rc)\n[ "$rc" = 0 ] && echo "CARRIED: $1" || echo "NOT CARRIED: $1"\nexit "$rc"\n' "$tmp" "$tmp" >"$tmp/fakebin/verified-carry"
chmod +x "$tmp/fakebin/verified-carry"; echo 0 >"$tmp/carry-rc"; : >"$tmp/carry.log"
export BOARD_WAIT_VERIFIED_CARRY=$tmp/fakebin/verified-carry
mkdir -p "$T/cards/Car5555"
cards '[{"id":"s2c","name":"[AGENTS] Conflict fixed (#36)","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"Car5555",
         "desc":"**PR:** example-org/example-app#36, https://github.com/example-org/example-app/pull/36 (x)"}]'
c36() { # c36 <comment text>... (newest first; dated an hour apart, the first newest)
  local h=20 out="" t
  for t in "$@"; do out+='{"date":"2026-10-15T'"$h"':00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"'"$t"'"}},'; h=$((h - 1)); done
  echo "[${out%,}]" >"$T/cards/Car5555/actions"
}
head36() { echo '{"headRefOid":"'"$1"'","reviews":[]}' >"$tmp/gh/example-org_example-app-36.json"; }
P=example-org/example-app#36
: >"$tmp/agents"
# (e) a carried head: ready, no VERIFY:, and a second poll with nothing changed runs the script no more.
head36 cdcd3434; c36 "CONFLICT RESOLVED: $P: no behavior change" "VERIFIED: $P @ abab0000"
run "$tmp/k9c" W3 BOARD_WAIT_LIMIT=1 "$W"
ok "carry: a conflict-only fix keeps the VERIFIED: (ready, the no-merger STUCK: line)" 'grep -q "^STUCK: \"\[AGENTS\] Conflict fixed (#36)\" .*ready to merge and no merger is alive" "$tmp/k9c"' "$(cat "$tmp/k9c")"
ok "carry: no VERIFY: for a carried head" '! grep -q "^VERIFY: " "$tmp/k9c"' "$(cat "$tmp/k9c")"
ok "carry: the script is asked about <ref> <A> <head>" 'grep -qx "$P abab0000 cdcd3434" "$tmp/carry.log"' "$(cat "$tmp/carry.log")"
n_calls=$(wc -l <"$tmp/carry.log")
run "$tmp/k9d" W3 BOARD_WAIT_LIMIT=1 "$W"
ok "carry: an unchanged card runs no second verified-carry.sh (cached)" '[ "$(wc -l <"$tmp/carry.log")" = "$n_calls" ]' "calls: $(cat "$tmp/carry.log")"
# (a) a NOT CARRIED: naming the head: not ready, no no-merger STUCK:, VERIFY: once for the head.
c36 "NOT CARRIED: $P @ cdcd3434: merge-gate: NOT CARRIED: commit abcdef1 changes files" "CONFLICT RESOLVED: $P: no behavior change" "VERIFIED: $P @ abab0000"
run "$tmp/k9e" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "carry: a NOT CARRIED: for the head makes it not ready (no no-merger STUCK:)" '! grep -q "Car5555.*ready to merge" "$tmp/k9e"' "$(cat "$tmp/k9e")"
ok "carry: a NOT CARRIED: for the head raises VERIFY: for it once" '[ "$(grep -c "^VERIFY: \"\[AGENTS\] Conflict fixed (#36)\" \[Car5555\] $P @ cdcd3434$" "$tmp/k9e")" = 1 ]' "$(cat "$tmp/k9e")"
run "$tmp/k9f" W3 BOARD_WAIT_LIMIT=1 "$W"
ok "carry: the VERIFY: is not raised again for the same head" '! grep -q "^VERIFY: " "$tmp/k9f"' "$(cat "$tmp/k9f")"
# (d) then the verifier's VERIFIED: at that head, with no MERGE READY: posted: ready again, no VERIFY:, the no-merger STUCK: line.
c36 "VERIFIED: $P @ cdcd3434" "NOT CARRIED: $P @ cdcd3434: merge-gate: NOT CARRIED: commit abcdef1 changes files" "CONFLICT RESOLVED: $P: no behavior change" "VERIFIED: $P @ abab0000"
run "$tmp/k9g" W3 BOARD_WAIT_LIMIT=1 "$W"
ok "carry: a VERIFIED: at the NOT CARRIED: head makes it ready with no MERGE READY: (the no-merger STUCK: line)" 'grep -q "^STUCK: .*Car5555.*ready to merge and no merger is alive" "$tmp/k9g"' "$(cat "$tmp/k9g")"
ok "carry: no VERIFY: after the VERIFIED: at that head" '! grep -q "^VERIFY: " "$tmp/k9g"' "$(cat "$tmp/k9g")"
# (c) a newer head ignores the old NOT CARRIED: and carries again.
head36 efef5656
c36 "REFRESHED: $P: no behavior change" "NOT CARRIED: $P @ cdcd3434: x" "CONFLICT RESOLVED: $P: no behavior change" "VERIFIED: $P @ abab0000"
run "$tmp/k9h" W3 BOARD_WAIT_LIMIT=1 "$W"
ok "carry: a newer head ignores a NOT CARRIED: for an older head" 'grep -q "^STUCK: .*Car5555.*ready to merge" "$tmp/k9h" && ! grep -q "^VERIFY: " "$tmp/k9h"' "$(cat "$tmp/k9h")"
# (b) no resolution comment since the VERIFIED: (a MERGE READY: is the newest status): not carried, VERIFY: for the head.
head36 9a9a1111; c36 "MERGE READY: $P: NO REVIEW NEEDED" "VERIFIED: $P @ abab0000"
run "$tmp/k9i" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "carry: no CONFLICT RESOLVED:/REFRESHED: since the VERIFIED: is not carried (VERIFY:, not ready)" 'grep -q "^VERIFY: .*Car5555.* @ 9a9a1111$" "$tmp/k9i" && ! grep -q "Car5555.*ready to merge" "$tmp/k9i"' "$(cat "$tmp/k9i")"
# (f) an older behavior-changing fix, or a VERIFY FAILED: newer than the VERIFIED:, is not carried.
head36 8b8b2222; c36 "REFRESHED: $P: no behavior change" "CONFLICT RESOLVED: $P: behavior changed: the gate reads two lines" "VERIFIED: $P @ abab0000"
run "$tmp/k9j" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "carry: a behavior-changing fix since the VERIFIED: is not carried" 'grep -q "^VERIFY: .*Car5555.* @ 8b8b2222$" "$tmp/k9j" && ! grep -q "Car5555.*ready to merge" "$tmp/k9j"' "$(cat "$tmp/k9j")"
head36 7c7c3333; c36 "CONFLICT RESOLVED: $P: no behavior change" "VERIFY FAILED: $P @ abab0000: a gap" "VERIFIED: $P @ abab0000"
run "$tmp/k9k" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "carry: a VERIFY FAILED: newer than the VERIFIED: is not carried" 'grep -q "^VERIFY: .*Car5555.* @ 7c7c3333$" "$tmp/k9k" && ! grep -q "Car5555.*ready to merge" "$tmp/k9k"' "$(cat "$tmp/k9k")"
# verified-carry.sh NOT CARRIED (exit 1) or ERROR (exit 2): not ready; an ERROR is asked again on a later poll.
head36 6d6d4444; c36 "CONFLICT RESOLVED: $P: no behavior change" "VERIFIED: $P @ abab0000"; echo 1 >"$tmp/carry-rc"
run "$tmp/k9l" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "carry: verified-carry.sh NOT CARRIED makes the head not ready (VERIFY:)" 'grep -q "^VERIFY: .*Car5555.* @ 6d6d4444$" "$tmp/k9l" && ! grep -q "Car5555.*ready to merge" "$tmp/k9l"' "$(cat "$tmp/k9l")"
head36 5e5e5555; echo 2 >"$tmp/carry-rc"; : >"$tmp/carry.log"
run "$tmp/k9m" W3 BOARD_WAIT_LIMIT=1 "$W"
run "$tmp/k9n" W3 BOARD_WAIT_LIMIT=1 "$W"
ok "carry: a verified-carry.sh ERROR is not ready and is asked again later (not cached for good)" '! grep -q "Car5555.*ready to merge" "$tmp/k9m" && [ "$(grep -c 5e5e5555 "$tmp/carry.log")" -ge 2 ]' "$(cat "$tmp/k9m") calls: $(cat "$tmp/carry.log")"
echo 0 >"$tmp/carry-rc"
# An orange card in MERGING with no conflict fix running.
cards '[{"id":"s3","name":"Conflicted","idList":"lm","idLabels":["'"$ORANGE"'"],"idMembers":[],"shortLink":"Cnf5555"}]'
mkdir -p "$T/cards/Cnf5555"; echo '[]' >"$T/cards/Cnf5555/actions"
run "$tmp/k10" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "stuck: an orange card in MERGING with no conflict fix running" 'grep -qx "STUCK: \"Conflicted\" \[Cnf5555\] (MERGING): its merge conflict or refresh has no fix running" "$tmp/k10"' "$(cat "$tmp/k10")"
# List order (rules.md): in MERGING only the top eligible card's conflict fix is wanted; a lower orange card waits labelled.
cards '[{"id":"o1","name":"Top conflicted","idList":"lm","idLabels":["'"$ORANGE"'"],"idMembers":[],"shortLink":"Top1111","pos":100},
        {"id":"o2","name":"Lower conflicted","idList":"lm","idLabels":["'"$ORANGE"'"],"idMembers":[],"shortLink":"Low2222","pos":200}]'
mkdir -p "$T/cards/Top1111" "$T/cards/Low2222"; echo '[]' >"$T/cards/Top1111/actions"; echo '[]' >"$T/cards/Low2222/actions"
run "$tmp/k10a" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "order: only the top orange card in MERGING is stuck without a fix; the lower one is gated" 'grep -q "\[Top1111\].*conflict or refresh" "$tmp/k10a" && ! grep -q "Low2222" "$tmp/k10a"' "$(cat "$tmp/k10a")"
cards '[{"id":"o1","name":"Top conflicted","idList":"lm","idLabels":["'"$ORANGE"'"],"idMembers":[],"shortLink":"Top1111","pos":300},
        {"id":"o2","name":"Lower conflicted","idList":"lm","idLabels":["'"$ORANGE"'"],"idMembers":[],"shortLink":"Low2222","pos":200}]'
run "$tmp/k10b" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "order: list position decides the top card, not the short link" 'grep -q "\[Low2222\].*conflict or refresh" "$tmp/k10b" && ! grep -q "Top1111" "$tmp/k10b"' "$(cat "$tmp/k10b")"
cards '[{"id":"o1","name":"Plain first","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"Top1111","pos":100},
        {"id":"o3","name":"[AGENTS] Orange agents","idList":"lm","idLabels":["'"$ORANGE"'"],"idMembers":[],"shortLink":"AgnO3333","pos":300},
        {"id":"o2","name":"Lower conflicted","idList":"lm","idLabels":["'"$ORANGE"'"],"idMembers":[],"shortLink":"Low2222","pos":200}]'
mkdir -p "$T/cards/AgnO3333"; echo '[]' >"$T/cards/AgnO3333/actions"
run "$tmp/k10c" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "order: an [AGENTS] card merges ahead of a plain card, so its conflict is workflow work and the plain orange card is gated" 'grep -qx "DEADLINE: workflow work waiting: AgnO3333" "$tmp/k10c" && ! grep -q "Low2222" "$tmp/k10c"' "$(cat "$tmp/k10c")"
# The waiting call carries the BUILDING order (🚨 first, then list position).
cards '[{"id":"b1","name":"Second","idList":"lb","idLabels":[],"idMembers":[],"shortLink":"Bld2","pos":200},
        {"id":"b2","name":"First","idList":"lb","idLabels":[],"idMembers":[],"shortLink":"Bld1","pos":100},
        {"id":"b3","name":"🚨 Urgent","idList":"lb","idLabels":[],"idMembers":[],"shortLink":"BldU","pos":900}]'
rm -f "$tmp/waiting-args"
run "$tmp/k10d" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "order: waiting is asked with --order in BUILDING order, 🚨 first" 'grep -qx "waiting --order BldU,Bld1,Bld2" "$tmp/waiting-args"' "$(cat "$tmp/waiting-args" 2>&1)"
# MERGING order reads DEPENDS ON:/WITH:/INCLUDED IN: from the card's comments (never the description).
PRA='"desc":"**PR:** example-org/example-app#61, https://github.com/example-org/example-app/pull/61 (x)"'
cards '[{"id":"d1","name":"Top waits","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"DepT1111","pos":100},
        {"id":"d2","name":"Lower orange","idList":"lm","idLabels":["'"$ORANGE"'"],"idMembers":[],"shortLink":"DepL2222","pos":200,'"$PRA"'}]'
mkdir -p "$T/cards/DepT1111" "$T/cards/DepL2222"; echo '[]' >"$T/cards/DepL2222/actions"
echo '[{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"DEPENDS ON: example-org/example-app#61"}}]' >"$T/cards/DepT1111/actions"
run "$tmp/k10e" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "order: a top card whose DEPENDS ON: comment names a lower orange card's PR ranks after it, so the lower fix is allowed" 'grep -q "\[DepL2222\].*conflict or refresh" "$tmp/k10e"' "$(cat "$tmp/k10e")"
echo '[{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"WITH: Fixer card https://trello.com/c/DepL2222: example-org/example-app#59 check is fixed by example-org/example-app#61"}}]' >"$T/cards/DepT1111/actions"
run "$tmp/k10e2" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "order: a WITH: comment naming the fixing card ranks the card after it" 'grep -q "\[DepL2222\].*conflict or refresh" "$tmp/k10e2"' "$(cat "$tmp/k10e2")"
echo '[{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"INCLUDED IN: example-org/example-app#99 (Carrier)"}}]' >"$T/cards/DepT1111/actions"
cards '[{"id":"d1","name":"Top orange carried","idList":"lm","idLabels":["'"$ORANGE"'"],"idMembers":[],"shortLink":"DepT1111","pos":100},
        {"id":"d2","name":"Lower orange","idList":"lm","idLabels":["'"$ORANGE"'"],"idMembers":[],"shortLink":"DepL2222","pos":200}]'
run "$tmp/k10f" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "order: a carried top card (an INCLUDED IN: comment) is skipped, the next card is top" 'grep -q "\[DepL2222\].*conflict or refresh" "$tmp/k10f" && ! grep -q "DepT1111" "$tmp/k10f"' "$(cat "$tmp/k10f")"
echo '[]' >"$T/cards/DepT1111/actions"
cards '[{"id":"d1","name":"Top Blocked","idList":"lm","idLabels":["'"$ORANGE"'","000000000000000000000022"],"idMembers":[],"shortLink":"DepT1111","pos":100},
        {"id":"d2","name":"Lower orange","idList":"lm","idLabels":["'"$ORANGE"'"],"idMembers":[],"shortLink":"DepL2222","pos":200}]'
run "$tmp/k10g" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "order: a Blocked top card is skipped, the next card is top" 'grep -q "\[DepL2222\].*conflict or refresh" "$tmp/k10g" && ! grep -q "STUCK.*DepT1111" "$tmp/k10g"' "$(cat "$tmp/k10g")"
cards '[{"id":"d1","name":"Top yellow","idList":"lm","idLabels":["'"$ORANGE"'","000000000000000000000025"],"idMembers":[],"shortLink":"DepT1111","pos":100},
        {"id":"d2","name":"Lower orange","idList":"lm","idLabels":["'"$ORANGE"'"],"idMembers":[],"shortLink":"DepL2222","pos":200}]'
run "$tmp/k10h" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "order: a yellow top card is skipped, the next card is top" 'grep -q "\[DepL2222\].*conflict or refresh" "$tmp/k10h" && ! grep -q "DepT1111" "$tmp/k10h"' "$(cat "$tmp/k10h")"
# A MERGING fixture: a 🚨 card, an app card above an [AGENTS] card, and a DEPENDS ON card: the [AGENTS] card is top after the 🚨 card.
cards '[{"id":"m1","name":"App card","idList":"lm","idLabels":["'"$ORANGE"'"],"idMembers":[],"shortLink":"MrgA1111","pos":100},
        {"id":"m2","name":"[AGENTS] Workflow card","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"MrgW2222","pos":200},
        {"id":"m3","name":"🚨 Urgent card","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"MrgU3333","pos":300}]'
mkdir -p "$T/cards/MrgA1111" "$T/cards/MrgW2222" "$T/cards/MrgU3333"; for k in MrgA1111 MrgW2222 MrgU3333; do echo '[]' >"$T/cards/$k/actions"; done
run "$tmp/k10i" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "order: with a 🚨 card and an [AGENTS] card below an app card, the gate refuses the app card's fix" '! grep -q "MrgA1111" "$tmp/k10i"' "$(cat "$tmp/k10i")"
# VERIFY: for a card in MERGING is gated to the top card and the once key of a lower card is not used up (rules.md, List order).
cards '[{"id":"vt1","name":"[AGENTS] Top verify (#90)","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"VgT11111","pos":100,
         "desc":"**PR:** example-org/example-app#90, https://github.com/example-org/example-app/pull/90 (rule)"},
        {"id":"vt2","name":"[AGENTS] Lower verify (#91)","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"VgL22222","pos":200,
         "desc":"**PR:** example-org/example-app#91, https://github.com/example-org/example-app/pull/91 (rule)"}]'
echo '{"headRefOid":"9a9a9a9a","reviews":[]}' >"$tmp/gh/example-org_example-app-90.json"
echo '{"headRefOid":"9b9b9b9b","reviews":[]}' >"$tmp/gh/example-org_example-app-91.json"
mkdir -p "$T/cards/VgT11111" "$T/cards/VgL22222"; echo '[]' >"$T/cards/VgT11111/actions"; echo '[]' >"$T/cards/VgL22222/actions"
run "$tmp/k10v1" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "order: an unverified top [AGENTS] card in MERGING gets VERIFY:, the lower one gets none" 'grep -q "^VERIFY: .*VgT11111.* @ 9a9a9a9a" "$tmp/k10v1" && ! grep -q "VgL22222" "$tmp/k10v1"' "$(cat "$tmp/k10v1")"
cards '[{"id":"vt2","name":"[AGENTS] Lower verify (#91)","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"VgL22222","pos":200,
         "desc":"**PR:** example-org/example-app#91, https://github.com/example-org/example-app/pull/91 (rule)"}]'
run "$tmp/k10v2" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "order: once the card above leaves MERGING the lower card's VERIFY: prints (its once key was not used up)" 'grep -qx "VERIFY: \"\[AGENTS\] Lower verify (#91)\" \[VgL22222\] example-org/example-app#91 @ 9b9b9b9b" "$tmp/k10v2"' "$(cat "$tmp/k10v2")"
# A failed `waiting` call: no stuck line from an empty want list, no new card named.
cards '[{"id":"w1","name":"Waits for server","idList":"lb","idLabels":[],"idMembers":[],"shortLink":"WtF11111","pos":100},
        {"id":"w2","name":"New card","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"WtF22222","pos":100}]'
mkdir -p "$T/cards/WtF11111" "$T/cards/WtF22222"; echo '[]' >"$T/cards/WtF11111/actions"; echo '[]' >"$T/cards/WtF22222/actions"
printf 'test-server-1 free\ntest-server-2 Busy2222\ntest-server-3 Busy3333\n' >"$tmp/servers"
echo "WtF11111 normal 1" >"$tmp/waiting"; touch "$tmp/waiting-fails"
run "$tmp/k10j" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "waiting fails: no STUCK: line for the card that only waits for a server, no new card named in START:" '! grep -q "^STUCK" "$tmp/k10j" && ! grep -q "WtF22222" "$tmp/k10j"' "$(cat "$tmp/k10j")"
rm -f "$tmp/waiting-fails"; : >"$tmp/waiting"
# START: names TODO ids in list order, 🚨 first.
printf 'test-server-1 free\ntest-server-2 free\ntest-server-3 free\n' >"$tmp/servers"
cards '[{"id":"t1","name":"Plain low","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"TdoL2222","pos":300},
        {"id":"t2","name":"Plain high","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"TdoH1111","pos":100},
        {"id":"t3","name":"🚨 Urgent low","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"TdoU3333","pos":900}]'
mkdir -p "$T/cards/TdoL2222" "$T/cards/TdoH1111" "$T/cards/TdoU3333"; for k in TdoL2222 TdoH1111 TdoU3333; do echo '[]' >"$T/cards/$k/actions"; done
run "$tmp/k10k" W3 BOARD_WAIT_LIMIT=2 BOARD_WAIT_START_REPEAT=0 "$W"
ok "start: TODO ids are named in list order, 🚨 first" 'grep -q "(TdoU3333, TdoH1111, TdoL2222)" "$tmp/k10k"' "$(cat "$tmp/k10k")"
# A card in MERGING whose newest status is REVIEW: waits on the user's GitHub approval like a card in REVIEW.
mkdir -p "$T/cards/Rvw6666"
rvcard() { cards '[{"id":"s8","name":"Dragged in (#70)","idList":"lm","idLabels":['"$1"'],"idMembers":[],"shortLink":"Rvw6666",
  "desc":"**PR:** example-user/example-app-old#70, https://github.com/example-user/example-app-old/pull/70 (app)'"$2"'"}]'; }
rvgh() { echo '{"headRefOid":"'"$1"'","reviews":['"$2"']}' >"$tmp/gh/example-user_example-app-old-$3.json"; }
rvrev() { echo '{"id":"'"$1"'","author":{"login":"example-user"},"state":"'"$2"'","submittedAt":"2026-10-15T10:00:00Z","commit":{"oid":"'"$3"'"}}'; }
echo '[{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"REVIEW: https://github.com/example-user/example-app-old/pull/70/files"}}]' >"$T/cards/Rvw6666/actions"
: >"$tmp/agents"
rvcard "" ""
rvgh h70 "$(rvrev rv1 APPROVED h70)" 70
echo "APPROVED: example-user/example-app-old#70: the user approved its head" >"$tmp/policy/example-user_example-app-old-70"
run "$tmp/rv1" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "review wait: an approval of a MERGING card with REVIEW: newest wakes it" 'grep -qx "REVIEW: \"Dragged in (#70)\" \[Rvw6666\] example-user/example-app-old#70 APPROVED" "$tmp/rv1"' "$(cat "$tmp/rv1")"
ok "review wait: the stuck line prints for it" 'grep -qx "STUCK: \"Dragged in (#70)\" \[Rvw6666\] (MERGING): newest status is REVIEW: and the user approved every PR on GitHub, nothing has picked it up" "$tmp/rv1"' "$(cat "$tmp/rv1")"
run "$tmp/rv1b" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "review wait: event mark already set, the stuck line still prints (a missed event is recovered)" '! grep -q "^REVIEW:" "$tmp/rv1b" && grep -q "^STUCK: \"Dragged in (#70)\".*REVIEW: and the user approved" "$tmp/rv1b"' "$(cat "$tmp/rv1b")"
ok "review wait: a MERGING card whose newest status is REVIEW: is never ready to merge" '! grep -q "^STUCK: \"Dragged in.*ready to merge" "$tmp/rv1" "$tmp/rv1b"' "$(cat "$tmp/rv1")"
rvcard "" "\\n**PR:** example-user/example-app-old#71, https://github.com/example-user/example-app-old/pull/71 (app)"
rvgh h71 "" 71
run "$tmp/rv2" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "review wait: two open PRs, one approved: no stuck line" '! grep -q "^STUCK: \"Dragged in" "$tmp/rv2"' "$(cat "$tmp/rv2")"
rvcard "" ""
rvgh h70new "$(rvrev rv1 APPROVED h70)" 70
run "$tmp/rv3" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "review wait: an approval at an old head the policy accepts (a merge of the base): the stuck line prints" 'grep -q "^STUCK: \"Dragged in (#70)\" \[Rvw6666\] (MERGING): newest status is REVIEW: and the user approved" "$tmp/rv3"' "$(cat "$tmp/rv3")"
echo "REVIEW NEEDED: example-user/example-app-old#70: approved on an older commit" >"$tmp/policy/example-user_example-app-old-70"
rvgh h70newer "$(rvrev rv1 APPROVED h70)" 70
run "$tmp/rv3b" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "review wait: an approval at an old head the policy refuses: no stuck line" '! grep -q "^STUCK: \"Dragged in" "$tmp/rv3b"' "$(cat "$tmp/rv3b")"
echo "ERROR: cannot read" >"$tmp/policy/example-user_example-app-old-70"
rvgh h70err "$(rvrev rv1 APPROVED h70)" 70
run "$tmp/rv3c" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "review wait: a policy ERROR: no stuck line, no crash" '! grep -q "^STUCK: \"Dragged in" "$tmp/rv3c" && ! grep -q Traceback "$tmp/rv3c"' "$(cat "$tmp/rv3c")"
: >"$tmp/policy.log"
echo "APPROVED: example-user/example-app-old#70: ok" >"$tmp/policy/example-user_example-app-old-70"
rvgh h70dis "$(rvrev rv1 APPROVED h70),$(rvrev rv9 DISMISSED h70 | sed 's/10:00:00Z/11:00:00Z/')" 70
run "$tmp/rv3d" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "review wait: a DISMISSED newest review is counted: no APPROVED event for the older one beyond its own id" '! grep -q "^REVIEW:.*DISMISSED" "$tmp/rv3d"' "$(cat "$tmp/rv3d")"
run "$tmp/rv3e" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "review policy cache: the same head, review and body: the policy runs once" '[ "$(grep -c "example-app-old#70" "$tmp/policy.log")" = 1 ]' "$(cat "$tmp/policy.log")"
echo '{"headRefOid":"h70dis","body":"App-visible: no","reviews":['"$(rvrev rv1 APPROVED h70),$(rvrev rv9 DISMISSED h70 | sed 's/10:00:00Z/11:00:00Z/')"']}' >"$tmp/gh/example-user_example-app-old-70.json"
run "$tmp/rv3f" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "review policy cache: a changed PR body runs the policy again" '[ "$(grep -c "example-app-old#70" "$tmp/policy.log")" = 2 ]' "$(cat "$tmp/policy.log")"
echo "echo '# changed' >/dev/null" >>"$tmp/fakebin/review-policy"
run "$tmp/rv3g" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "review policy cache: a changed policy file runs the policy again" '[ "$(grep -c "example-app-old#70" "$tmp/policy.log")" = 3 ]' "$(cat "$tmp/policy.log")"
ok "review wait: an approval at an old head: the card is never ready to merge" '! grep -q "^STUCK: \"Dragged in.*ready to merge" "$tmp/rv3"' "$(cat "$tmp/rv3")"
rvgh h70 "$(rvrev rv1 APPROVED h70)" 70
echo '[{"date":"2026-10-15T09:10:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"MERGE READY: example-user/example-app-old#70: APPROVED"}},{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"REVIEW: x"}}]' >"$T/cards/Rvw6666/actions"
run "$tmp/rv4" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "review wait: MERGE READY: newest: no review event and no review stuck line" '! grep -q "^REVIEW:\|REVIEW: and the user approved" "$tmp/rv4"' "$(cat "$tmp/rv4")"
echo '[{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"REVIEW: x"}}]' >"$T/cards/Rvw6666/actions"
echo "REVIEW NEEDED: example-user/example-app-old#70: the newest review is CHANGES_REQUESTED" >"$tmp/policy/example-user_example-app-old-70"
rvgh h70 "$(rvrev rv5 CHANGES_REQUESTED h70)" 70
run "$tmp/rv5" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "review wait: changes requested on a MERGING card: the event once, and the changes-requested stuck line" 'grep -qx "REVIEW: \"Dragged in (#70)\" \[Rvw6666\] example-user/example-app-old#70 CHANGES_REQUESTED" "$tmp/rv5" && grep -qx "STUCK: \"Dragged in (#70)\" \[Rvw6666\] (MERGING): the user requested changes on GitHub, nothing has picked it up" "$tmp/rv5" && ! grep -q "user approved" "$tmp/rv5"' "$(cat "$tmp/rv5")"
echo '[{"date":"2026-10-15T09:30:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"UNBLOCKED: x"}},{"date":"2026-10-15T09:20:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"WAITS FOR: another card"}},{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"REVIEW: x"}}]' >"$T/cards/Rvw6666/actions"
run "$tmp/rv5u" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "review wait: REVIEW:, WAITS FOR:, UNBLOCKED: is still a review wait" 'grep -qx "STUCK: \"Dragged in (#70)\" \[Rvw6666\] (MERGING): the user requested changes on GitHub, nothing has picked it up" "$tmp/rv5u"' "$(cat "$tmp/rv5u")"
# an old changes-requested review (before the newest comment with a REVIEW: line): no line
echo '[{"date":"2026-10-15T10:30:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"REVIEW: x"}}]' >"$T/cards/Rvw6666/actions"
run "$tmp/rv5c" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "review wait: a changes-requested review older than the newest REVIEW: comment: no stuck line" '! grep -q "requested changes" "$tmp/rv5c"' "$(cat "$tmp/rv5c")"
# the anchor is a line starting REVIEW:, not only the comment's start (the merger's comment starts with the policy line)
echo '[{"date":"2026-10-15T10:30:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"REVIEW NEEDED: a/b#1: x\nREVIEW: https://example/files"}}]' >"$T/cards/Rvw6666/actions"
run "$tmp/rv5d" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "review wait: the anchor is a line starting REVIEW: anywhere in the comment" '! grep -q "requested changes" "$tmp/rv5d"' "$(cat "$tmp/rv5d")"
# no comment with a REVIEW: line at all (a card dragged in): any newest changes-requested review counts
echo '[{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"REVIEW: x"}}]' >"$T/cards/Rvw6666/actions"
cards '[{"id":"s8","name":"Dragged in (#70)","idList":"lr","idLabels":[],"idMembers":[],"shortLink":"Rvw6666","desc":"**PR:** example-user/example-app-old#70, https://github.com/example-user/example-app-old/pull/70 (app)"}]'
echo '[]' >"$T/cards/Rvw6666/actions"
run "$tmp/rv5e" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "review wait: a REVIEW card with no REVIEW: comment: a newest changes-requested review counts" 'grep -qx "STUCK: \"Dragged in (#70)\" \[Rvw6666\] (REVIEW): the user requested changes on GitHub, nothing has picked it up" "$tmp/rv5e"' "$(cat "$tmp/rv5e")"
# a REVIEW card whose PRs all pass: the REVIEW wording; a yellow one: none
rvgh h70 "$(rvrev rv6 APPROVED h70)" 70
echo "APPROVED: example-user/example-app-old#70: ok" >"$tmp/policy/example-user_example-app-old-70"
run "$tmp/rv5f" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "review wait: a REVIEW card whose every PR passes: the stuck line survives the prune" 'grep -qx "STUCK: \"Dragged in (#70)\" \[Rvw6666\] (REVIEW): every PR passes the review policy (approved on GitHub or no review needed), nothing has picked it up" "$tmp/rv5f"' "$(cat "$tmp/rv5f")"
cards '[{"id":"s8","name":"Dragged in (#70)","idList":"lr","idLabels":["000000000000000000000025"],"idMembers":[],"shortLink":"Rvw6666","desc":"**PR:** example-user/example-app-old#70, https://github.com/example-user/example-app-old/pull/70 (app)"}]'
run "$tmp/rv5g" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "review wait: a yellow REVIEW card: no review stuck line" '! grep -q "^STUCK: \"Dragged in" "$tmp/rv5g"' "$(cat "$tmp/rv5g")"
# a failed comment read (the card's actions answer 404): not "no REVIEW: comment", so no changes-requested stuck line
cards '[{"id":"s8","name":"Dragged in (#70)","idList":"lr","idLabels":[],"idMembers":[],"shortLink":"Rvw6666","desc":"**PR:** example-user/example-app-old#70, https://github.com/example-user/example-app-old/pull/70 (app)"}]'
rvgh h70 "$(rvrev rv5 CHANGES_REQUESTED h70)" 70
mv "$T/cards/Rvw6666/actions" "$T/cards/Rvw6666/actions.off"
run "$tmp/rv5h" W3 BOARD_WAIT_LIMIT=2 "$W"
mv "$T/cards/Rvw6666/actions.off" "$T/cards/Rvw6666/actions"
ok "review wait: a failed comment read on a REVIEW card: no changes-requested stuck line" '! grep -q "requested changes" "$tmp/rv5h"' "$(cat "$tmp/rv5h")"
rvcard "" ""
echo '[{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"REVIEW: x"}}]' >"$T/cards/Rvw6666/actions"
rvgh h70 "$(rvrev rv5 CHANGES_REQUESTED h70)" 70
run "$tmp/rv5b" W3 BOARD_WAIT_LIMIT=1 "$W"
ok "review wait: the changes-requested event is not repeated" '! grep -q "^REVIEW:" "$tmp/rv5b"' "$(cat "$tmp/rv5b")"
rvgh h70 "$(rvrev rv6 APPROVED h70)" 70
cards '[{"id":"s8","name":"Dragged in (#70)","idList":"lm","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"Rvw6666","desc":"**PR:** example-user/example-app-old#70, https://github.com/example-user/example-app-old/pull/70 (app)"}]'
run "$tmp/rv6" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "review wait: a Blocked card in MERGING: no review event and no review stuck line" '! grep -q "^REVIEW:\|REVIEW: and the user approved" "$tmp/rv6"' "$(cat "$tmp/rv6")"
cards '[]'
# The release status card ("🚀 RELEASE: …", top of RELEASING) carries the steps; a release is in progress while RELEASING holds a
# card besides it. Both uploads and no promoter alive: nobody finishes the release.
lists
mkdir -p "$T/cards/Rel7777" "$T/cards/Cov8888"; echo '[]' >"$T/cards/Cov8888/actions"
relcards() { cards '[{"id":"s6","name":"🚀 RELEASE: running","idList":"lx","idLabels":['"$1"'],"idMembers":[],"shortLink":"Rel7777"},{"id":"s7","name":"Covered card","idList":"lx","idLabels":[],"idMembers":[],"shortLink":"Cov8888"}]'; }
relcards ""
echo '[{"date":"2026-10-15T09:30:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"IOS UPLOADED: client-build/1.1.11+156"}},{"date":"2026-10-15T09:20:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"ANDROID UPLOADED: client-build/1.1.11+156"}},{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"PROMOTING: development @ a, main @ b"}}]' >"$T/cards/Rel7777/actions"
: >"$tmp/agents"
run "$tmp/k10a" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "stuck: both uploads exist, no SMOKE comment, no promoter alive" 'grep -qx "STUCK: \"🚀 RELEASE: running\" \[Rel7777\] (RELEASING): both uploads exist (no SMOKE comment) and no promoter is alive" "$tmp/k10a"' "$(cat "$tmp/k10a")"
printf 'waiting promoter card=Rel7777 id=p1 last=60s children=0 reqs=1 ctx=1 - /x\n' >"$tmp/agents"
run "$tmp/k10b" W3 BOARD_WAIT_LIMIT=1 "$W"
ok "stuck: not when a promoter is alive" '! grep -q "both uploads" "$tmp/k10b"' "$(cat "$tmp/k10b")"
echo '[{"date":"2026-10-15T09:20:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"ANDROID UPLOADED: client-build/1.1.11+156"}},{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"PROMOTING: development @ a, main @ b"}}]' >"$T/cards/Rel7777/actions"
: >"$tmp/agents"
run "$tmp/k10c" W3 BOARD_WAIT_LIMIT=1 "$W"
ok "stuck: only one upload is not stuck" '! grep -q "both uploads" "$tmp/k10c"' "$(cat "$tmp/k10c")"
echo '[{"date":"2026-10-15T10:30:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"PROMOTING: development @ c, main @ d"}},{"date":"2026-10-15T09:30:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"IOS UPLOADED: client-build/1.1.11+156"}},{"date":"2026-10-15T09:20:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"ANDROID UPLOADED: client-build/1.1.11+156"}}]' >"$T/cards/Rel7777/actions"
run "$tmp/k10d" W3 BOARD_WAIT_LIMIT=1 "$W"
ok "stuck: uploads of an earlier release (before the newest PROMOTING:) do not count" '! grep -q "both uploads" "$tmp/k10d"' "$(cat "$tmp/k10d")"
# A stalled release: the release status card with no uploads yet, and neither a promoter nor an app builder alive.
echo '[{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"PROMOTING: development @ a, main @ b"}}]' >"$T/cards/Rel7777/actions"
: >"$tmp/agents"
run "$tmp/k10e" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "stuck: the release status card with no promoter and no app builder alive" 'grep -qx "STUCK: \"🚀 RELEASE: running\" \[Rel7777\] (RELEASING): the release has stalled: no promoter and no app builder is alive; start the promoter" "$tmp/k10e"' "$(cat "$tmp/k10e")"
# At the app-build step the missing app builder is named, not the promoter.
rel() { printf '[' >"$T/cards/Rel7777/actions"; local first=1; for t in "$@"; do [ $first = 1 ] || printf ',' >>"$T/cards/Rel7777/actions"; first=0
  printf '{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"%s","data":{"text":"%s"}}' "$CLAUDE" "$t" >>"$T/cards/Rel7777/actions"; done; printf ']' >>"$T/cards/Rel7777/actions"; }
rel "STAGING DEPLOYED: d, client-build/1.1.12+157 (main @ b)" "PROMOTING: development @ a, main @ b"
run "$tmp/k10j" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "stuck: staging deployed, no app build: both app builders are named" 'grep -qx "STUCK: \"🚀 RELEASE: running\" \[Rel7777\] (RELEASING): the release has stalled: no promoter and no app builder is alive; start the android and ios app builder" "$tmp/k10j"' "$(cat "$tmp/k10j")"
rel "ANDROID UPLOADED: client-build/1.1.12+157" "ANDROID BUILT: client-build/1.1.12+157" "IOS BUILT: client-build/1.1.12+157" "SMOKE PASSED" "STAGING DEPLOYED: d, client-build/1.1.12+157 (main @ b)" "PROMOTING: development @ a, main @ b"
run "$tmp/k10k" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "stuck: Android uploaded, iOS built and SMOKE passed: only the iOS builder is named" 'grep -qx "STUCK: \"🚀 RELEASE: running\" \[Rel7777\] (RELEASING): the release has stalled: no promoter and no app builder is alive; start the ios app builder" "$tmp/k10k"' "$(cat "$tmp/k10k")"
rel "IOS BUILT: client-build/1.1.12+157" "ANDROID BUILT: client-build/1.1.12+157" "STAGING DEPLOYED: d, client-build/1.1.12+157 (main @ b)" "PROMOTING: development @ a, main @ b"
run "$tmp/k10l" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "stuck: both built, SMOKE not run: the promoter is named" 'grep -qx "STUCK: \"🚀 RELEASE: running\" \[Rel7777\] (RELEASING): the release has stalled: no promoter and no app builder is alive; start the promoter" "$tmp/k10l"' "$(cat "$tmp/k10l")"
rel "STAGING DEPLOYED: d, client: unchanged" "PROMOTING: development @ a, main @ b"
run "$tmp/k10m" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "stuck: client unchanged: the promoter is named" 'grep -qx "STUCK: \"🚀 RELEASE: running\" \[Rel7777\] (RELEASING): the release has stalled: no promoter and no app builder is alive; start the promoter" "$tmp/k10m"' "$(cat "$tmp/k10m")"
rel "IOS BUILD FAILED: client-build/1.1.12+157: compile error" "STAGING DEPLOYED: d, client-build/1.1.12+157 (main @ b)" "PROMOTING: development @ a, main @ b"
run "$tmp/k10n" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "stuck: iOS BUILD FAILED, Android not built: the promoter is named, not the Android builder" 'grep -qx "STUCK: \"🚀 RELEASE: running\" \[Rel7777\] (RELEASING): the release has stalled: no promoter and no app builder is alive; start the promoter" "$tmp/k10n"' "$(cat "$tmp/k10n")"
# FULL SUITE HELD: (the promoter ended on purpose after a second host loss) with its hold open: the release waits, it has not stalled.
mkdir -p "$T/cards/Hld99999"
echo '[{"date":"2026-10-15T09:10:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"RELEASE BLOCKER: the release test host was lost twice"}}]' >"$T/cards/Hld99999/actions"
cards '[{"id":"s6","name":"🚀 RELEASE: running","idList":"lx","idLabels":[],"idMembers":[],"shortLink":"Rel7777"},{"id":"s7","name":"Covered card","idList":"lx","idLabels":[],"idMembers":[],"shortLink":"Cov8888"},{"id":"s9","name":"Release blocked: the release test host was lost twice","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"Hld99999"}]'
rel "FULL SUITE HELD: Release blocked: the release test host was lost twice" "FULL SUITE VOID: host lost" "FULL SUITE VOID: host lost" "PROMOTING: development @ a, main @ b"
: >"$tmp/agents"
python3 - "$tmp/state-stuck.json" <<'PY'
import json, sys
p = sys.argv[1]; st = json.load(open(p))
st.setdefault("holds", {})["Hld99999"] = {"name": "Release blocked: the release test host was lost twice", "list": "QUESTIONS"}
json.dump(st, open(p, "w"))
PY
run "$tmp/k10p" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "stuck: FULL SUITE HELD: with its hold open is not stalled" '! grep -q "has stalled" "$tmp/k10p"' "$(cat "$tmp/k10p")"
echo '[{"date":"2026-10-15T09:10:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"RELEASE BLOCKER: the release test host was lost twice"}},{"date":"2026-10-15T10:10:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"RESOLVED: host is back"}}]' >"$T/cards/Hld99999/actions"
cards '[{"id":"s6","name":"🚀 RELEASE: running","idList":"lx","idLabels":[],"idMembers":[],"shortLink":"Rel7777"},{"id":"s7","name":"Covered card","idList":"lx","idLabels":[],"idMembers":[],"shortLink":"Cov8888"},{"id":"s9","name":"Release blocked: the release test host was lost twice","idList":"lz","idLabels":[],"idMembers":[],"shortLink":"Hld99999"}]'
python3 - "$tmp/state-stuck.json" <<'PY'
import json, sys
p = sys.argv[1]; st = json.load(open(p)); st["holds"] = {}
json.dump(st, open(p, "w"))
PY
run "$tmp/k10q" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "stuck: FULL SUITE HELD: after the hold ended reads stalled and starts the promoter" 'grep -qx "STUCK: \"🚀 RELEASE: running\" \[Rel7777\] (RELEASING): the release has stalled: no promoter and no app builder is alive; start the promoter" "$tmp/k10q"' "$(cat "$tmp/k10q")"
relcards ""
rel "PROMOTING: development @ a, main @ b"
printf 'waiting promoter card=Rel7777 id=p2 last=60s children=0 reqs=1 ctx=1 - /x\n' >"$tmp/agents"
run "$tmp/k10f" W3 BOARD_WAIT_LIMIT=1 "$W"
ok "stuck: a release with a live promoter is not stalled" '! grep -q "has stalled" "$tmp/k10f"' "$(cat "$tmp/k10f")"
printf 'running android-builder card=Rel7777 id=b1 last=60s children=0 reqs=1 ctx=1 - /x\n' >"$tmp/agents"
run "$tmp/k10g" W3 BOARD_WAIT_LIMIT=1 "$W"
ok "stuck: a release with a live Android builder is not stalled" '! grep -q "has stalled" "$tmp/k10g"' "$(cat "$tmp/k10g")"
printf 'running ios-builder card=Rel7777 id=b2 last=60s children=0 reqs=1 ctx=1 - /x\n' >"$tmp/agents"
run "$tmp/k10h" W3 BOARD_WAIT_LIMIT=1 "$W"
ok "stuck: a release with a live iOS builder is not stalled" '! grep -q "has stalled" "$tmp/k10h"' "$(cat "$tmp/k10h")"
: >"$tmp/agents"
relcards '"'"$BLOCKED"'"'
run "$tmp/k10i" W3 BOARD_WAIT_LIMIT=1 "$W"
ok "stuck: a Blocked RELEASING card (a manual step) is not stalled" '! grep -q "has stalled" "$tmp/k10i"' "$(cat "$tmp/k10i")"
# A release status card alone in RELEASING (no release in progress) is never stalled; it is never "actively worked".
rel "PROMOTING: development @ a, main @ b"
cards '[{"id":"s6","name":"🚀 RELEASE: idle","idList":"lx","idLabels":[],"idMembers":[],"shortLink":"Rel7777"}]'
: >"$tmp/agents"
reset_writes
run "$tmp/k10o" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "stuck: the release status card alone in RELEASING is no release in progress" '! grep -q "has stalled\|both uploads\|no release status card" "$tmp/k10o"' "$(cat "$tmp/k10o")"
# RELEASING holds a card but no release status card: said once.
cards '[{"id":"s7","name":"Covered card","idList":"lx","idLabels":[],"idMembers":[],"shortLink":"Cov8888"}]'
run "$tmp/k10p" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "stuck: RELEASING holds cards but no release status card" 'grep -q "STUCK: RELEASING holds cards but no release status card" "$tmp/k10p"' "$(cat "$tmp/k10p")"
# A failed release keeps its cards in RELEASING (never STUCK:) and waits for its fix card; once the fix card is joinable
# (in MERGED, or in MERGING with MERGE READY: as its newest status once settings section 39 is applied), one
# RELEASE FIX READY: line says to start the promoter. The settings file is a fake (BOARD_WAIT_USER_SETTINGS).
printf '{"autoMode":{"allow":["the promoter: git -C <wt> cherry-pick -m 1 -x <merge commit>"]}}\n' >"$tmp/settings-no.json"
printf '{"autoMode":{"allow":["the promoter: git -C <wt> cherry-pick -m 1 -x <merge commit>; git -C <wt> cherry-pick -x <sha>..<sha>"]}}\n' >"$tmp/settings-yes.json"
export BOARD_WAIT_USER_SETTINGS=$tmp/settings-no.json
lists
mkdir -p "$T/cards/Fix99999"; echo '[]' >"$T/cards/Fix99999/actions"
cj() { echo '{"date":"'"$1"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"'"$2"'"}}'; }   # one comment as JSON
fixcards() { # $1 fix card list id, $2 more cards (JSON, with a leading comma) 
  cards '[{"id":"s6","name":"🚀 RELEASE: failed","idList":"lx","idLabels":[],"idMembers":[],"shortLink":"Rel7777"},{"id":"s7","name":"Covered card","idList":"lx","idLabels":[],"idMembers":[],"shortLink":"Cov8888"},{"id":"s8","name":"🚨 The fix","idList":"'"$1"'","idLabels":[],"idMembers":[],"shortLink":"Fix99999"}'"${2:-}"']'; }
echo "[$(cj 2026-10-18T11:00:00.000Z 'RELEASE FIX: 🚨 The fix https://trello.com/c/Fix99999'),$(cj 2026-10-18T09:00:00.000Z 'PROMOTING: development @ a, main @ b')]" >"$T/cards/Rel7777/actions"
fixcards ld
: >"$tmp/agents"; rm -f "$tmp/state-stuck.json"
run "$tmp/k10r" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "failed release: the fix card in MERGED says to start the promoter" 'grep -qx "RELEASE FIX READY: \"🚨 The fix\" \[Fix99999\] is joinable (MERGED) and the failed release \"🚀 RELEASE: failed\" \[Rel7777\] waits for it: start the promoter" "$tmp/k10r"' "$(cat "$tmp/k10r")"
ok "failed release: its cards in RELEASING are not stalled" '! grep -q "has stalled" "$tmp/k10r"' "$(cat "$tmp/k10r")"
ok "failed release: the old RELEASE FIX MERGED: line is gone" '! grep -q "RELEASE FIX MERGED" "$tmp/k10r"' "$(cat "$tmp/k10r")"
fixcards lt
rm -f "$tmp/state-stuck.json"
run "$tmp/k10s" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "failed release: a fix card not yet in MERGED starts nothing" '! grep -q "RELEASE FIX READY" "$tmp/k10s"' "$(cat "$tmp/k10s")"
# Two named fix cards: nothing prints while one is not joinable; once both are in MERGED, a line each.
mkdir -p "$T/cards/Fix88888"; echo '[]' >"$T/cards/Fix88888/actions"
echo "[$(cj 2026-10-18T12:00:00.000Z 'RELEASE FIX: 🚨 The other fix https://trello.com/c/Fix88888'),$(cj 2026-10-18T11:00:00.000Z 'RELEASE FIX: 🚨 The fix https://trello.com/c/Fix99999'),$(cj 2026-10-18T09:00:00.000Z 'PROMOTING: development @ a, main @ b')]" >"$T/cards/Rel7777/actions"
other() { echo ',{"id":"s9","name":"🚨 The other fix","idList":"'"$1"'","idLabels":[],"idMembers":[],"shortLink":"Fix88888"}'; }
fixcards ld "$(other lt)"
rm -f "$tmp/state-stuck.json"
run "$tmp/k10t" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "failed release: two fix cards, one not joinable, starts nothing" '! grep -q "RELEASE FIX READY" "$tmp/k10t"' "$(cat "$tmp/k10t")"
fixcards ld "$(other ld)"
rm -f "$tmp/state-stuck.json"
run "$tmp/k10u" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "failed release: two fix cards, both in MERGED, a line for each" '[ "$(grep -c "RELEASE FIX READY" "$tmp/k10u")" = 2 ]' "$(cat "$tmp/k10u")"
# A fix card in MERGING: joinable only with MERGE READY: as its newest status AND the allow entry applied.
echo "[$(cj 2026-10-18T11:00:00.000Z 'RELEASE FIX: 🚨 The fix https://trello.com/c/Fix99999'),$(cj 2026-10-18T09:00:00.000Z 'PROMOTING: development @ a, main @ b')]" >"$T/cards/Rel7777/actions"
echo "[$(cj 2026-10-18T12:00:00.000Z 'MERGE READY: example-org/example-api#9 NO REVIEW NEEDED')]" >"$T/cards/Fix99999/actions"
fixcards lm
rm -f "$tmp/state-stuck.json"
run "$tmp/k10v" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "failed release: a MERGING fix with MERGE READY: before settings section 39 is applied starts nothing" '! grep -q "RELEASE FIX READY" "$tmp/k10v"' "$(cat "$tmp/k10v")"
rm -f "$tmp/state-stuck.json"
run "$tmp/k10w" W3 BOARD_WAIT_USER_SETTINGS="$tmp/settings-yes.json" BOARD_WAIT_LIMIT=2 "$W"
ok "failed release: a MERGING fix with MERGE READY: once section 39 is applied says to start the promoter" 'grep -qx "RELEASE FIX READY: \"🚨 The fix\" \[Fix99999\] is joinable (MERGING with MERGE READY:) and the failed release \"🚀 RELEASE: failed\" \[Rel7777\] waits for it: start the promoter" "$tmp/k10w"' "$(cat "$tmp/k10w")"
# The same state does not print again; the move to MERGED does (the state token changed).
fixcards ld
run "$tmp/k10x" W3 BOARD_WAIT_USER_SETTINGS="$tmp/settings-yes.json" BOARD_WAIT_LIMIT=2 "$W"
ok "failed release: the fix moving from MERGING to MERGED prints the line again" 'grep -q "RELEASE FIX READY.*is joinable (MERGED)" "$tmp/k10x"' "$(cat "$tmp/k10x")"
# Not joinable in MERGING: a newest status that is not MERGE READY: (a refresh, a review, a check failure), or a RELEASE FIX WAITS: newer than it.
for newest in 'REFRESHED: example-org/example-api#9: no behavior change' 'REVIEW: https://github.com/example-org/example-api/pull/9/files' 'CHECK FAILED: red'; do
  echo "[$(cj 2026-10-18T13:00:00.000Z "$newest"),$(cj 2026-10-18T12:00:00.000Z 'MERGE READY: example-org/example-api#9 NO REVIEW NEEDED')]" >"$T/cards/Fix99999/actions"
  fixcards lm; rm -f "$tmp/state-stuck.json"
  run "$tmp/k10y" W3 BOARD_WAIT_USER_SETTINGS="$tmp/settings-yes.json" BOARD_WAIT_LIMIT=2 "$W"
  ok "failed release: a MERGING fix whose newest status is '${newest%%:*}:' starts nothing" '! grep -q "RELEASE FIX READY" "$tmp/k10y"' "$(cat "$tmp/k10y")"
done
echo "[$(cj 2026-10-18T12:00:00.000Z 'MERGE READY: example-org/example-api#9 NO REVIEW NEEDED')]" >"$T/cards/Fix99999/actions"
echo "[$(cj 2026-10-18T12:30:00.000Z 'RELEASE FIX WAITS: 🚨 The fix https://trello.com/c/Fix99999: head check failed; joins from MERGED'),$(cj 2026-10-18T11:00:00.000Z 'RELEASE FIX: 🚨 The fix https://trello.com/c/Fix99999'),$(cj 2026-10-18T09:00:00.000Z 'PROMOTING: development @ a, main @ b')]" >"$T/cards/Rel7777/actions"
fixcards lm; rm -f "$tmp/state-stuck.json"
run "$tmp/k10z" W3 BOARD_WAIT_USER_SETTINGS="$tmp/settings-yes.json" BOARD_WAIT_LIMIT=2 "$W"
ok "failed release: a RELEASE FIX WAITS: newer than the MERGE READY: keeps a MERGING fix from being joinable" '! grep -q "RELEASE FIX READY" "$tmp/k10z"' "$(cat "$tmp/k10z")"
echo "[$(cj 2026-10-18T13:00:00.000Z 'MERGE READY: example-org/example-api#9 NO REVIEW NEEDED')]" >"$T/cards/Fix99999/actions"
rm -f "$tmp/state-stuck.json"
run "$tmp/k10z2" W3 BOARD_WAIT_USER_SETTINGS="$tmp/settings-yes.json" BOARD_WAIT_LIMIT=2 "$W"
ok "failed release: a MERGE READY: newer than the RELEASE FIX WAITS: makes it joinable again" 'grep -q "RELEASE FIX READY.*is joinable (MERGING with MERGE READY:)" "$tmp/k10z2"' "$(cat "$tmp/k10z2")"
# An UNBLOCKED: answers a WAITS FOR: on the fix card: the MERGE READY: under it is the newest status again (newest_status_index).
echo "[$(cj 2026-10-18T14:00:00.000Z 'UNBLOCKED: x'),$(cj 2026-10-18T13:00:00.000Z 'WAITS FOR: some other card'),$(cj 2026-10-18T12:00:00.000Z 'MERGE READY: example-org/example-api#9 NO REVIEW NEEDED')]" >"$T/cards/Fix99999/actions"
echo "[$(cj 2026-10-18T11:00:00.000Z 'RELEASE FIX: 🚨 The fix https://trello.com/c/Fix99999'),$(cj 2026-10-18T09:00:00.000Z 'PROMOTING: development @ a, main @ b')]" >"$T/cards/Rel7777/actions"
fixcards lm; rm -f "$tmp/state-stuck.json"
run "$tmp/k10u1" W3 BOARD_WAIT_USER_SETTINGS="$tmp/settings-yes.json" BOARD_WAIT_LIMIT=2 "$W"
ok "failed release: MERGE READY:, WAITS FOR:, UNBLOCKED: on a MERGING fix is joinable (MERGING@ the MERGE READY: date)" 'grep -q "RELEASE FIX READY.*is joinable (MERGING with MERGE READY:)" "$tmp/k10u1"' "$(cat "$tmp/k10u1")"
# The level check: a joinable fix and no promoter alive is STUCK (a lost line); not with a promoter alive.
echo "[$(cj 2026-10-18T11:00:00.000Z 'RELEASE FIX: 🚨 The fix https://trello.com/c/Fix99999'),$(cj 2026-10-18T09:00:00.000Z 'PROMOTING: development @ a, main @ b')]" >"$T/cards/Rel7777/actions"
fixcards ld; rm -f "$tmp/state-stuck.json"
run "$tmp/k10aa" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "failed release: a joinable fix and no promoter alive is STUCK" 'grep -qx "STUCK: \"🚀 RELEASE: failed\" \[Rel7777\] (RELEASING): every fix is joinable and no promoter is alive; start the promoter" "$tmp/k10aa"' "$(cat "$tmp/k10aa")"
printf 'running promoter card=Rel7777 id=p5 last=3s children=0 reqs=3 ctx=1000 - /x\n' >"$tmp/agents"; rm -f "$tmp/state-stuck.json"
run "$tmp/k10ab" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "failed release: a joinable fix with a live promoter is not STUCK" '! grep -q "every fix is joinable" "$tmp/k10ab"' "$(cat "$tmp/k10ab")"
: >"$tmp/agents"; fixcards lt; rm -f "$tmp/state-stuck.json"
run "$tmp/k10ac" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "failed release: a fix that is not joinable is not STUCK" '! grep -q "every fix is joinable" "$tmp/k10ac"' "$(cat "$tmp/k10ac")"
# The culprit search of a first run: FULL SUITE FAILED:, a RELEASE FIX: after it, no RELEASE SEARCH ENDED:, no promoter.
SEARCHLINE='STUCK: "🚀 RELEASE: failed" [Rel7777] (RELEASING): the failed release'"'"'s culprit search has no promoter alive and no RELEASE SEARCH ENDED: line; start the promoter'
failing() { # $@ = the comments, newest first, as "<date>|<text>"
  local out="" c; for c in "$@"; do out="$out${out:+,}$(cj "${c%%|*}" "${c#*|}")"; done; echo "[$out]" >"$T/cards/Rel7777/actions"; }
failing '2026-10-18T10:30:00.000Z|RELEASE FIX: 🚨 The fix https://trello.com/c/Fix99999' '2026-10-18T10:00:00.000Z|FULL SUITE FAILED: main @ b, development @ a: ui' '2026-10-18T09:00:00.000Z|PROMOTING: development @ a, main @ b'
rm -f "$tmp/state-stuck.json"
run "$tmp/k10ad" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "culprit search: failed first run, RELEASE FIX: filed, no RELEASE SEARCH ENDED:, no promoter: STUCK" 'grep -qxF "$SEARCHLINE" "$tmp/k10ad"' "$(cat "$tmp/k10ad")"
printf 'running promoter card=Rel7777 id=p5 last=3s children=0 reqs=3 ctx=1000 - /x\n' >"$tmp/agents"; rm -f "$tmp/state-stuck.json"
run "$tmp/k10ae" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "culprit search: not with a live promoter" '! grep -qF "culprit search" "$tmp/k10ae"' "$(cat "$tmp/k10ae")"
: >"$tmp/agents"
failing '2026-10-18T11:00:00.000Z|RELEASE SEARCH ENDED: no culprit' '2026-10-18T10:30:00.000Z|RELEASE FIX: 🚨 The fix https://trello.com/c/Fix99999' '2026-10-18T10:00:00.000Z|FULL SUITE FAILED: main @ b, development @ a: ui' '2026-10-18T09:00:00.000Z|PROMOTING: development @ a, main @ b'
rm -f "$tmp/state-stuck.json"
run "$tmp/k10af" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "culprit search: not after RELEASE SEARCH ENDED:" '! grep -qF "culprit search" "$tmp/k10af"' "$(cat "$tmp/k10af")"
failing '2026-10-18T10:30:00.000Z|RELEASE FIX: 🚨 The fix https://trello.com/c/Fix99999' '2026-10-18T10:00:00.000Z|SMOKE FAILED: x' '2026-10-18T09:00:00.000Z|PROMOTING: development @ a, main @ b'
rm -f "$tmp/state-stuck.json"
run "$tmp/k10ag" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "culprit search: a SMOKE failure runs no search, so no line" '! grep -qF "culprit search" "$tmp/k10ag"' "$(cat "$tmp/k10ag")"
failing '2026-10-18T14:00:00.000Z|RELEASE FIX: 🚨 The fix https://trello.com/c/Fix99999' '2026-10-18T13:30:00.000Z|FULL SUITE FAILED: main @ b, development @ a: ui again' '2026-10-18T13:00:00.000Z|PROMOTING: development @ a, main @ b\nRelease branch: release/b-a\nAdded: 🚨 The earlier fix (cherry-picked x)'
rm -f "$tmp/state-stuck.json"
run "$tmp/k10ah" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "culprit search: a failure of a rerun with a fix (an Added: line) runs no search, so no line" '! grep -qF "culprit search" "$tmp/k10ah"' "$(cat "$tmp/k10ah")"
# A second red rerun: the newest PROMOTING: names only the newest fix (Added: B); the earlier fix A is on the older run's
# Added: line. A second fix B that is joinable still prints its line, and no culprit search is asked for.
fixcards ld; rm -f "$tmp/state-stuck.json"
failing '2026-10-18T16:00:00.000Z|RELEASE FIX: 🚨 The fix https://trello.com/c/Fix99999' '2026-10-18T15:30:00.000Z|FULL SUITE FAILED: main @ b, development @ a: ui third' '2026-10-18T15:00:00.000Z|PROMOTING: development @ a, main @ b\nAdded: 🚨 The second fix (cherry-picked y)' '2026-10-18T14:00:00.000Z|FULL SUITE FAILED: main @ b, development @ a: ui again' '2026-10-18T13:00:00.000Z|PROMOTING: development @ a, main @ b\nAdded: 🚨 The earlier fix (cherry-picked x)'
run "$tmp/k10ai" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "second red rerun: a joinable new fix prints its line and asks for no culprit search" 'grep -q "RELEASE FIX READY.*\[Fix99999\]" "$tmp/k10ai" && ! grep -qF "culprit search" "$tmp/k10ai"' "$(cat "$tmp/k10ai")"
# The promoter's gate and pin-step wording is checked in test-board-content.sh (the text, as the gate is the promoter's prose).
# A live promoter does not label the release status card; the card still gets Blocked from its WAITS FOR: (a sign-off).
printf 'running promoter card=Cov8888 id=p9 last=3s children=0 reqs=3 ctx=1000 - /x\n' >"$tmp/agents"
relcards ""
echo '[{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"WAITS FOR: you (sign-off)"}}]' >"$T/cards/Rel7777/actions"
reset_writes
run "$tmp/k10q" W2 BOARD_WAIT_LIMIT=1 "$W"
ok "labels: the release status card is never actively worked" '! gw -qx "POST /cards/s6/idLabels $ACT"' "$(writes)"
ok "labels: the release status card gets Blocked from its WAITS FOR: (sign-off)" 'gw -qx "POST /cards/s6/idLabels $BLOCKED"' "$(writes)"
: >"$tmp/agents"
lists_testing
# A free server, a startable TODO card: printed again on a later wake, not only once.
cards '[{"id":"s4","name":"Startable","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"Strt6666"}]'
printf 'test-server-1 free\ntest-server-2 Busy2222\ntest-server-3 Busy3333\n' >"$tmp/servers"
run "$tmp/k11" W3 BOARD_WAIT_LIMIT=2 BOARD_WAIT_START_REPEAT=0 "$W"
run "$tmp/k12" W3 BOARD_WAIT_LIMIT=2 BOARD_WAIT_START_REPEAT=0 "$W"
ok "start: still true on the next wake: printed again" 'grep -q "^START: 1 free card test server; TODO has 1 startable card (Strt6666)" "$tmp/k11" && grep -q "^START: " "$tmp/k12"' "$(cat "$tmp/k11") / $(cat "$tmp/k12")"
run "$tmp/k13" W3 BOARD_WAIT_LIMIT=1 BOARD_WAIT_START_REPEAT=100000 "$W"
ok "start: not again inside the repeat time" '! grep -q "^START" "$tmp/k13"' "$(cat "$tmp/k13")"
# A card waiting for its AFTER run keeps the free server: TODO is not announced, the waiting card is.
echo "Idle3333 normal 1" >"$tmp/waiting"
run "$tmp/k14" W3 BOARD_WAIT_LIMIT=2 BOARD_WAIT_START_REPEAT=0 "$W"
ok "start: a free server with a card waiting for AFTER names that card, not TODO" 'grep -qx "START: 1 free card test server; BUILDING has 1 card waiting for their AFTER run (Idle3333)" "$tmp/k14"' "$(cat "$tmp/k14")"
: >"$tmp/waiting"
# A returning card (it has a BEFORE: comment) needs no server: START names it with every server busy,
# and the new card beside it is not announced (no server free for it).
cards '[{"id":"s5","name":"Returning","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"Retn7777"},
        {"id":"s6","name":"Brand new","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"Newc8888"}]'
mkdir -p "$T/cards/Retn7777" "$T/cards/Newc8888"
echo '[{"id":"b1","type":"commentCard","date":"'"$(iso $((now + 10)))"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"BEFORE: mobile card/x @ abc1234"}}]' >"$T/cards/Retn7777/actions"
echo '[]' >"$T/cards/Newc8888/actions"
printf 'test-server-1 Busy1111\ntest-server-2 Busy2222\ntest-server-3 Busy3333\n' >"$tmp/servers"
run "$tmp/k14b" W3 BOARD_WAIT_LIMIT=2 BOARD_WAIT_START_REPEAT=0 "$W"
ok "start: a returning card is named although no server is free; the new card is not" 'grep -qx "START: 0 free card test servers; TODO has 1 returning card (Retn7777), no test server needed" "$tmp/k14b"' "$(cat "$tmp/k14b")"
printf 'test-server-1 free\ntest-server-2 Busy2222\ntest-server-3 Busy3333\n' >"$tmp/servers"
run "$tmp/k14c" W3 BOARD_WAIT_LIMIT=2 BOARD_WAIT_START_REPEAT=0 "$W"
ok "start: with a server free both are named, the new card as startable, the returning one apart" 'grep -qx "START: 1 free card test server; TODO has 1 startable card (Newc8888); TODO has 1 returning card (Retn7777), no test server needed" "$tmp/k14c"' "$(cat "$tmp/k14c")"
# A server reserved for a new card in TODO (the card paused for the promoter's culprit search) is free for that card: START names it.
printf 'test-server-1 free (reserved for Newc8888)\ntest-server-2 Busy2222\ntest-server-3 Busy3333\n' >"$tmp/servers"
run "$tmp/k14d" W3 BOARD_WAIT_LIMIT=2 BOARD_WAIT_START_REPEAT=0 "$W"
ok "start: a server reserved for a new TODO card counts as free for it" 'grep -qx "START: 0 free card test servers; TODO has 1 startable card (Newc8888); a server is kept for Newc8888; TODO has 1 returning card (Retn7777), no test server needed" "$tmp/k14d"' "$(cat "$tmp/k14d")"
# A card a tester moved VERIFY -> TODO (old BEFORE:, no NOT VERIFIED: yet) is a NEW card, not a returning one;
# one with CHANGES REQUESTED: newest after such a move still returns; a NOT VERIFIED: newest makes it new too.
cards '[{"id":"s7","name":"Back from verify","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"Vrfy7777"},
        {"id":"s8","name":"Changes requested","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"Chgr8888"},
        {"id":"s9","name":"Not verified","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"Nvfy9999"}]'
mkdir -p "$T/cards/Vrfy7777" "$T/cards/Chgr8888" "$T/cards/Nvfy9999"
mv_() { printf '{"id":"m1","type":"updateCard","date":"%s","data":{"listBefore":{"name":"VERIFY 🔎"},"listAfter":{"name":"TODO 📚"}}}' "$1"; }
cm_() { printf '{"id":"%s","type":"commentCard","date":"%s","idMemberCreator":"%s","data":{"text":"%s"}}' "$1" "$2" "$CLAUDE" "$3"; }
echo "[$(mv_ "$(iso $((now + 20)))"),$(cm_ b1 "$(iso $((now + 10)))" 'BEFORE: mobile card/x @ abc1234')]" >"$T/cards/Vrfy7777/actions"
echo "[$(cm_ c1 "$(iso $((now + 30)))" 'CHANGES REQUESTED: x'),$(mv_ "$(iso $((now + 20)))"),$(cm_ b1 "$(iso $((now + 10)))" 'BEFORE: mobile card/x @ abc1234')]" >"$T/cards/Chgr8888/actions"
echo "[$(cm_ n1 "$(iso $((now + 30)))" 'NOT VERIFIED: still broken'),$(cm_ b1 "$(iso $((now + 10)))" 'BEFORE: mobile card/x @ abc1234')]" >"$T/cards/Nvfy9999/actions"
printf 'test-server-1 Busy1111\ntest-server-2 Busy2222\ntest-server-3 Busy3333\n' >"$tmp/servers"
run "$tmp/k14v" W3 BOARD_WAIT_LIMIT=2 BOARD_WAIT_START_REPEAT=0 "$W"
ok "start: VERIFY -> TODO with no NOT VERIFIED: and a NOT VERIFIED: card are new; the CHANGES REQUESTED: card still returns" 'grep -qx "START: 0 free card test servers; TODO has 1 returning card (Chgr8888), no test server needed" "$tmp/k14v"' "$(cat "$tmp/k14v")"
# A failed move read is never cached: the card is not named returning, and once the read works it is a new card (VERIFY -> TODO).
cards '[{"id":"s10","name":"Move read fails","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"Mfl00001"}]'
mkdir -p "$T/cards/Mfl00001"
echo "[$(mv_ "$(iso $((now + 20)))"),$(cm_ b1 "$(iso $((now + 10)))" 'BEFORE: mobile card/x @ abc1234')]" >"$T/cards/Mfl00001/actions"
: >"$T/cards/Mfl00001/actions.moves-fail"
run "$tmp/k14w" W3 BOARD_WAIT_LIMIT=2 BOARD_WAIT_START_REPEAT=0 "$W"
ok "start: a failed move read does not make the card returning" '! grep -q "^START:.*Mfl00001" "$tmp/k14w"' "$(cat "$tmp/k14w")"
rm -f "$T/cards/Mfl00001/actions.moves-fail"
# A reserved server serves its own card only: a second new card is not named on its account.
cards '[{"id":"s5","name":"Returning","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"Retn7777"},
        {"id":"s6","name":"Brand new","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"Newc8888"},
        {"id":"s7","name":"Other new","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"Thrd1111"}]'
mkdir -p "$T/cards/Thrd1111"; echo '[]' >"$T/cards/Thrd1111/actions"
printf 'test-server-1 free (reserved for Newc8888)\ntest-server-2 Busy2222\ntest-server-3 Busy3333\n' >"$tmp/servers"
run "$tmp/k14f" W3 BOARD_WAIT_LIMIT=2 BOARD_WAIT_START_REPEAT=0 "$W"
ok "start: a server reserved for one new card does not make a second new card startable" 'grep -q "startable card (Newc8888)" "$tmp/k14f" && ! grep -q "Thrd1111" "$tmp/k14f"' "$(cat "$tmp/k14f")"
echo "Idle3333 normal 1" >"$tmp/waiting"
printf 'test-server-1 free (reserved for Newc8888)\ntest-server-2 free\ntest-server-3 Busy3333\n' >"$tmp/servers"
run "$tmp/k14g" W3 BOARD_WAIT_LIMIT=2 BOARD_WAIT_START_REPEAT=0 "$W"
ok "start: the one other free server goes to the waiting AFTER card, so only the reserved-for card is named" 'grep -q "startable card (Newc8888)" "$tmp/k14g" && ! grep -q "Thrd1111" "$tmp/k14g"' "$(cat "$tmp/k14g")"
: >"$tmp/waiting"
cards '[{"id":"s5","name":"Returning","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"Retn7777"},
        {"id":"s6","name":"Brand new","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"Newc8888"}]'
printf 'test-server-1 free (reserved for Othr9999)\ntest-server-2 Busy2222\ntest-server-3 Busy3333\n' >"$tmp/servers"
run "$tmp/k14e" W3 BOARD_WAIT_LIMIT=2 BOARD_WAIT_START_REPEAT=0 "$W"
ok "start: a server reserved for another card does not make a new card startable" '! grep -q "startable card" "$tmp/k14e"' "$(cat "$tmp/k14e")"
printf 'test-server-1 Busy1111\ntest-server-2 Busy2222\ntest-server-3 Busy3333\n' >"$tmp/servers"
# The promoter's borrow-promoter reserved a busy server: the watcher is woken to pause that card, once; a pause file ends it.
printf 'test-server-1 Busy1111 (reserved for promoter)\ntest-server-2 Busy2222\ntest-server-3 Busy3333\n' >"$tmp/servers"
mkdir -p "$tmp/pausedir"
run "$tmp/k14d" W3 BOARD_WAIT_PAUSE_DIR="$tmp/pausedir" BOARD_WAIT_LIMIT=2 "$W"
ok "promoter pause: a busy server reserved for the promoter wakes the watcher naming the card" 'grep -q "^PAUSE FOR PROMOTER: Busy1111 on test-server-1" "$tmp/k14d"' "$(cat "$tmp/k14d")"
run "$tmp/k14e" W3 BOARD_WAIT_PAUSE_DIR="$tmp/pausedir" BOARD_WAIT_LIMIT=1 "$W"
ok "promoter pause: not again while nothing changed" '! grep -q "PAUSE FOR PROMOTER" "$tmp/k14e"' "$(cat "$tmp/k14e")"
echo "PAUSE for the promoter" >"$tmp/pausedir/Busy1111"
run "$tmp/k14f" W3 BOARD_WAIT_PAUSE_DIR="$tmp/pausedir" BOARD_WAIT_LIMIT=1 BOARD_WAIT_START_REPEAT=0 "$W"
ok "promoter pause: none once the card's pause file exists" '! grep -q "PAUSE FOR PROMOTER" "$tmp/k14f"' "$(cat "$tmp/k14f")"
rm -f "$tmp/pausedir/Busy1111"
printf 'test-server-1 Busy1111\ntest-server-2 Busy2222\ntest-server-3 Busy3333\n' >"$tmp/servers"
# A 🚨 new card with every server busy: START says to pre-empt now. A server reserved for it (a
# pre-emption already under way) is not asked for again. A server that frees mid-pre-emption names the card
# as startable. A free server with a normal card waiting for AFTER goes to the 🚨 card.
cards '[{"id":"u1","name":"🚨 Urgent fix","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"Urg1AAAA"}]'
mkdir -p "$T/cards/Urg1AAAA"; echo '[]' >"$T/cards/Urg1AAAA/actions"
printf 'test-server-1 Busy1111\ntest-server-2 Busy2222\ntest-server-3 Busy3333\n' >"$tmp/servers"
run "$tmp/u1" W3 BOARD_WAIT_LIMIT=2 BOARD_WAIT_START_REPEAT=0 "$W"
ok "urgent: every server busy and a 🚨 card in TODO: pre-empt now" 'grep -qx "START: 0 free card test servers; TODO has 1 🚨 card (Urg1AAAA) and no free test server: pre-empt now" "$tmp/u1"' "$(cat "$tmp/u1")"
run "$tmp/u1b" W3 BOARD_WAIT_LIMIT=2 BOARD_WAIT_START_REPEAT=0 "$W"
ok "urgent: pre-empt now is printed once per card and server state, not again on the next wake" '! grep -q "pre-empt now" "$tmp/u1b"' "$(cat "$tmp/u1b")"
printf 'test-server-1 Busy1111\ntest-server-2 Busy2222\ntest-server-3 Busy3333 (reserved for Urg1AAAA)\n' >"$tmp/servers"
run "$tmp/u2" W3 BOARD_WAIT_LIMIT=1 BOARD_WAIT_START_REPEAT=0 "$W"
ok "urgent: a server already reserved for the 🚨 card: no second pre-emption" '! grep -q "^START" "$tmp/u2"' "$(cat "$tmp/u2")"
printf 'test-server-1 Busy1111\ntest-server-2 Busy2222\ntest-server-3 Busy3333\n' >"$tmp/servers"
run "$tmp/u2b" W3 BOARD_WAIT_LIMIT=1 BOARD_WAIT_START_REPEAT=0 "$W"
ok "urgent: the server state changed and came back: pre-empt now is news again" 'grep -q "pre-empt now" "$tmp/u2b"' "$(cat "$tmp/u2b")"
printf 'test-server-1 Busy1111\ntest-server-2 Busy2222\ntest-server-3 Busy3333 (reserved for Urg1AAAA)\n' >"$tmp/servers"
printf 'test-server-1 free\ntest-server-2 Busy2222\ntest-server-3 Busy3333 (reserved for Urg1AAAA)\n' >"$tmp/servers"
run "$tmp/u3" W3 BOARD_WAIT_LIMIT=2 BOARD_WAIT_START_REPEAT=0 "$W"
ok "urgent: a server frees mid-pre-emption: the 🚨 card is startable on it" 'grep -qx "START: 1 free card test server; TODO has 1 startable card (Urg1AAAA)" "$tmp/u3"' "$(cat "$tmp/u3")"
# 9d2. An answered card waiting in QUESTIONS for a server (card UD2L732X): an ANSWERED: comment newer than its
# newest BLOCKED:, whatever comes after it (a ROUTED:), is startable like a new TODO card; START: names it apart.
mkdir -p "$T/cards/Ans1AAAA" "$T/cards/Ans2BBBB" "$T/cards/Ans3CCCC"
echo '[{"id":"a4","type":"commentCard","date":"'"$(iso $((now - 10)))"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"ROUTED: user comment"}},{"id":"a3","type":"commentCard","date":"'"$(iso $((now - 20)))"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"ANSWERED: do it; waiting for a test server"}},{"id":"a2","type":"commentCard","date":"'"$(iso $((now - 30)))"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"USER REPLY: do it"}},{"id":"a1","type":"commentCard","date":"'"$(iso $((now - 40)))"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"BLOCKED: which? From: TODO"}}]' >"$T/cards/Ans1AAAA/actions"
echo '[{"id":"b2","type":"commentCard","date":"'"$(iso $((now - 10)))"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"BLOCKED: again? From: TODO"}},{"id":"b1","type":"commentCard","date":"'"$(iso $((now - 20)))"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"ANSWERED: old; waiting for a test server"}}]' >"$T/cards/Ans2BBBB/actions"
echo '[{"id":"c1","type":"commentCard","date":"'"$(iso $((now - 20)))"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"BLOCKED: which? From: TODO"}}]' >"$T/cards/Ans3CCCC/actions"
cards '[{"id":"an1","name":"Answered one","idList":"lq","idLabels":[],"idMembers":[],"shortLink":"Ans1AAAA"},
        {"id":"an2","name":"Asked again","idList":"lq","idLabels":[],"idMembers":[],"shortLink":"Ans2BBBB"},
        {"id":"an3","name":"Unanswered","idList":"lq","idLabels":[],"idMembers":[],"shortLink":"Ans3CCCC"}]'
printf 'test-server-1 free\n' >"$tmp/servers"; : >"$tmp/waiting"
run "$tmp/an1" W3 BOARD_WAIT_LIMIT=2 BOARD_WAIT_START_REPEAT=0 "$W"
ok "answered: ANSWERED: newer than BLOCKED:, with a ROUTED: after it, and a free server: START names it, and only it" 'grep -qx "START: 1 free card test server; QUESTIONS has 1 answered card waiting for a server (Ans1AAAA): step 11 item 2a" "$tmp/an1"' "$(cat "$tmp/an1")"
printf 'test-server-1 Busy1111\ntest-server-2 Busy2222\ntest-server-3 Busy3333\n' >"$tmp/servers"
reset_writes
run "$tmp/an2" W3 BOARD_WAIT_LIMIT=2 BOARD_WAIT_START_REPEAT=0 "$W"
ok "answered: no free server: no START:, the Waiting for shared resource label goes on" '! grep -q "^START" "$tmp/an2" && gw -qx "POST /cards/an1/idLabels 000000000000000000000026"' "$(cat "$tmp/an2") $(writes)"
ok "answered: a card with a BLOCKED: newer than its ANSWERED:, or never answered, is not waiting" '! gw -q "POST /cards/an2/idLabels 000000000000000000000026" && ! gw -q "POST /cards/an3/idLabels 000000000000000000000026"' "$(writes)"
cards '[{"id":"an1","name":"🚨 Answered urgent","idList":"lq","idLabels":[],"idMembers":[],"shortLink":"Ans1AAAA"}]'
run "$tmp/an3" W3 BOARD_WAIT_LIMIT=2 BOARD_WAIT_START_REPEAT=0 "$W"
ok "answered: a 🚨 answered card with every server busy: pre-empt now" 'grep -qx "START: 0 free card test servers; QUESTIONS has 1 answered 🚨 card (Ans1AAAA) and no free test server: pre-empt now" "$tmp/an3"' "$(cat "$tmp/an3")"
cards '[{"id":"u1","name":"🚨 Urgent fix","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"Urg1AAAA"}]'
echo "Idle3333 normal 1" >"$tmp/waiting"
printf 'test-server-1 free\ntest-server-2 Busy2222\ntest-server-3 Busy3333\n' >"$tmp/servers"
run "$tmp/u4" W3 BOARD_WAIT_LIMIT=2 BOARD_WAIT_START_REPEAT=0 "$W"
ok "urgent: a free server goes to the 🚨 card ahead of a normal card waiting for AFTER" 'grep -q "TODO has 1 startable card (Urg1AAAA)" "$tmp/u4"' "$(cat "$tmp/u4")"
: >"$tmp/waiting"
# A 🚨 card waiting in BUILDING for its AFTER run (not in TODO): a server that frees while another is
# reserved for it shows in START's "BUILDING has … waiting" part (board-watcher.md step 10, item 4 lifts on it).
cards '[]'
echo "Urg1AAAA urgent 1" >"$tmp/waiting"
printf 'test-server-1 free\ntest-server-2 Busy2222\ntest-server-3 Busy3333 (reserved for Urg1AAAA)\n' >"$tmp/servers"
run "$tmp/u5" W3 BOARD_WAIT_LIMIT=2 BOARD_WAIT_START_REPEAT=0 "$W"
ok "urgent: a 🚨 card waiting in BUILDING for AFTER, a server frees: START names it as waiting" 'grep -qx "START: 1 free card test server; BUILDING has 1 card waiting for their AFTER run (Urg1AAAA)" "$tmp/u5"' "$(cat "$tmp/u5")"
: >"$tmp/waiting"
printf 'test-server-1 Busy1111\ntest-server-2 Busy2222\ntest-server-3 Busy3333\n' >"$tmp/servers"
# The context ceiling, once per agent.
cards '[]'
printf 'running card-manager card=Ctx7777 id=cx1 last=5s children=0 reqs=300 ctx=250000 - /x\nrunning card-manager card=Ctx8888 id=cx2 last=5s children=0 reqs=30 ctx=100000 - /x\n' >"$tmp/agents"
run "$tmp/k15" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "context: an agent past the ceiling is named" 'grep -qx "CONTEXT: card-manager card=Ctx7777 id=cx1 ctx=250000" "$tmp/k15" && ! grep -q cx2 "$tmp/k15"' "$(cat "$tmp/k15")"
run "$tmp/k16" W3 BOARD_WAIT_LIMIT=1 "$W"
ok "context: once per agent" '! grep -q "^CONTEXT" "$tmp/k16"' "$(cat "$tmp/k16")"
# A workflow builder past the ceiling is named too (the main session hands it off, run-board.md).
printf 'running workflow-builder card=CtxW7777 id=cx3 last=5s children=0 reqs=300 ctx=250000 - /x\n' >"$tmp/agents"
run "$tmp/k16w" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "context: a workflow builder past the ceiling is named" 'grep -qx "CONTEXT: workflow-builder card=CtxW7777 id=cx3 ctx=250000" "$tmp/k16w"' "$(cat "$tmp/k16w")"
run "$tmp/k16x" W3 BOARD_WAIT_LIMIT=1 "$W"
ok "context: a workflow builder once" '! grep -q "^CONTEXT" "$tmp/k16x"' "$(cat "$tmp/k16x")"
# A merger and a workflow verifier past the ceiling are named too (no handoff; the main session tells the user).
printf 'running merger card=- id=cx4 last=5s children=0 reqs=300 ctx=250000 - /x\nrunning workflow-verifier card=CtxV7777 id=cx5 last=5s children=0 reqs=300 ctx=250000 - /x\n' >"$tmp/agents"
run "$tmp/k16m" W3 BOARD_WAIT_LIMIT=2 "$W"
ok "context: a merger past the ceiling is named" 'grep -qx "CONTEXT: merger card=- id=cx4 ctx=250000" "$tmp/k16m"' "$(cat "$tmp/k16m")"
ok "context: a workflow verifier past the ceiling is named" 'grep -qx "CONTEXT: workflow-verifier card=CtxV7777 id=cx5 ctx=250000" "$tmp/k16m"' "$(cat "$tmp/k16m")"
run "$tmp/k16n" W3 BOARD_WAIT_LIMIT=1 "$W"
ok "context: a merger and a verifier once" '! grep -q "^CONTEXT" "$tmp/k16n"' "$(cat "$tmp/k16n")"
: >"$tmp/agents"
# A failing agent-state.sh strips no label.
printf '#!/usr/bin/env bash\nexit 1\n' >"$tmp/fakebin/agent-state-bad"; chmod +x "$tmp/fakebin/agent-state-bad"
cards '[{"id":"idOld","name":"Old card","idList":"lb","idLabels":["'"$ACT"'"],"idMembers":[],"shortLink":"OldA1111"}]'
reset_writes
run "$tmp/k17" W3 BOARD_WAIT_LIMIT=1 BOARD_WAIT_AGENT_STATE="$tmp/fakebin/agent-state-bad" "$W"
ok "labels: a failed agent-state.sh removes no label" '! gw -q idOld' "$(writes)"
# A refused label write (a read-only token): one LABELS: line, not again while it stays refused, and
# again once a write went through in between.
lists
printf 'running card-manager card=Refu1111 id=rf1 last=3s children=0 reqs=3 ctx=1000 - /x\n' >"$tmp/agents"
cards '[{"id":"idRef","name":"Refused card","idList":"lb","idLabels":[],"idMembers":[],"shortLink":"Refu1111"}]'
touch "$tmp/refuse-writes"
run "$tmp/r1" W2 BOARD_WAIT_LIMIT=2 "$W"
ok "labels: a refused write prints one LABELS: line" '[ "$(grep -c "^LABELS: write refused (HTTP 403)" "$tmp/r1")" = 1 ]' "$(cat "$tmp/r1")"
run "$tmp/r2" W2 BOARD_WAIT_LIMIT=1 "$W"
ok "labels: refused again, no new line" '! grep -q "^LABELS:" "$tmp/r2"' "$(cat "$tmp/r2")"
rm -f "$tmp/refuse-writes"; reset_writes
run "$tmp/r3" W2 BOARD_WAIT_LIMIT=1 "$W"
ok "labels: the write goes through once the token is fixed" 'gw -q "idRef\|idLabels"' "$(writes)"
cards '[{"id":"idRef","name":"Refused card","idList":"lb","idLabels":[],"idMembers":[],"shortLink":"Refu1111"}]'
touch "$tmp/refuse-writes"
run "$tmp/r4" W2 BOARD_WAIT_LIMIT=2 "$W"
ok "labels: refused after a write went through is news again" 'grep -q "^LABELS: write refused (HTTP 403)" "$tmp/r4"' "$(cat "$tmp/r4")"
echo 503 >"$tmp/refuse-writes"
run "$tmp/r5" W2 BOARD_WAIT_LIMIT=1 "$W"
ok "labels: a 503 refusal is noted on stderr only, no LABELS: line" '! grep -q "^LABELS:" "$tmp/r5" && grep -q "refused: HTTP 503" "$tmp/r5"' "$(cat "$tmp/r5")"
rm -f "$tmp/refuse-writes"; : >"$tmp/agents"
cards '[]'

# 9c. The release status card's name and description are kept by this script (rules.md, The release status card): the state
# comes from the release comments since the newest PROMOTING:, the covered cards, the Blocked label and the live agents.
Wr() { env BOARD_WAIT_STATE=$tmp/state-relcard.json "$@"; }
relname() { # run once and print the name the script wrote
  reset_writes; rm -f "$tmp/state-relcard.json"; run "$tmp/rc" Wr BOARD_WAIT_LIMIT=1 "$W"; gw '^PUT /cards/s6 ' | sed 's|^PUT /cards/s6 ||'; }
relcards ""
: >"$tmp/agents"
printf 'running promoter card=Cov8888 id=p9 last=3s children=0 reqs=3 ctx=1000 - /x\n' >"$tmp/agents"
rel "PROMOTING: development @ a, main @ b"
ok "release card: a fresh pin with a live promoter is 'running: full test'" '[ "$(relname)" = "🚀 RELEASE: running: full test" ]' "$(relname)"
rel "FULL SUITE GREEN: main @ b, development @ a" "PROMOTING: development @ a, main @ b"
ok "release card: a green full test is 'running: staging deploy'" '[ "$(relname)" = "🚀 RELEASE: running: staging deploy" ]' "$(relname)"
rel "STAGING DEPLOYED: d, client-build/1.1.12+157 (main @ b)" "FULL SUITE GREEN: main @ b, development @ a" "PROMOTING: development @ a, main @ b"
ok "release card: a staging deploy is 'running: app builds'" '[ "$(relname)" = "🚀 RELEASE: running: app builds" ]' "$(relname)"
rel "STAGING PUSH: development @ a from c" "FULL SUITE GREEN: main @ b, development @ a" "PROMOTING: development @ a, main @ b"
ok "release card: a staging push is still 'running: staging deploy'" '[ "$(relname)" = "🚀 RELEASE: running: staging deploy" ]' "$(relname)"
rel "SMOKE PASSED" "ANDROID BUILT: client-build/1.1.12+157" "STAGING DEPLOYED: d, client-build/1.1.12+157 (main @ b)" "PROMOTING: development @ a, main @ b"
ok "release card: SMOKE passed is 'running: uploads'" '[ "$(relname)" = "🚀 RELEASE: running: uploads" ]' "$(relname)"
rel "STAGING DEPLOYED: d, client: unchanged" "PROMOTING: development @ a, main @ b"
ok "release card: client unchanged is 'running: finishing the release'" '[ "$(relname)" = "🚀 RELEASE: running: finishing the release" ]' "$(relname)"
rel "FULL SUITE FAILED: main @ b, development @ a: some test" "PROMOTING: development @ a, main @ b"
ok "release card: a failed full test with the cards still in RELEASING is 'failing'" 'grn -q "^🚀 RELEASE: running: failing"' "$(relname)"
rel "RELEASE FIX: 🚨 The fix https://trello.com/c/Fix99999" "FULL SUITE FAILED: ui" "PROMOTING: development @ a, main @ b"
ok "release card: a failure with a RELEASE FIX: comment and the cards still in RELEASING is 'failed'" '[ "$(relname)" = "🚀 RELEASE: failed" ]' "$(relname)"
rel "RELEASE FIX: 🚨 After paying, the Day Pass never shows https://trello.com/c/4LRSFjSA" "FULL SUITE FAILED: main @ b, development @ a: full test" "PROMOTING: development @ 0eb042b0, main @ 65332631"
ok "release card: the copied PROMOTING:, FULL SUITE FAILED:, RELEASE FIX: as three comments is 'failed'" '[ "$(relname)" = "🚀 RELEASE: failed" ]' "$(relname)"
# A RELEASE FIX VOID: makes the status card failed (nothing clears it).
rel "RELEASE FIX: 🚨 The fix https://trello.com/c/Fix99999" "RELEASE FIX VOID: 🚨 The fix: new commits" "PROMOTING: development @ a, main @ b"
ok "release card: a RELEASE FIX VOID: with a RELEASE FIX: after it is 'failed'" '[ "$(relname)" = "🚀 RELEASE: failed" ]' "$(relname)"
# A dead promoter: a running step with no live promoter or app builder.
: >"$tmp/agents"
rel "FULL SUITE GREEN: main @ b, development @ a" "PROMOTING: development @ a, main @ b"
ok "release card: no live promoter shows 'stalled: no promoter'" '[ "$(relname)" = "🚀 RELEASE: stalled: no promoter (staging deploy)" ]' "$(relname)"
printf 'running ios-builder card=Rel7777 id=i1 last=3s children=0 reqs=3 ctx=1000 - /x\n' >"$tmp/agents"
ok "release card: a live app builder is not a stall" '[ "$(relname)" = "🚀 RELEASE: running: staging deploy" ]' "$(relname)"
# Waiting on the user: the Blocked label with the green* sign-off, or with another manual step.
: >"$tmp/agents"
relcards '"'"$BLOCKED"'"'
rel "GREEN*: main @ b, development @ a" "PROMOTING: development @ a, main @ b"
ok "release card: Blocked after GREEN* is 'waiting: sign-off'" '[ "$(relname)" = "🚀 RELEASE: waiting: sign-off" ]' "$(relname)"
rel "WAITS FOR: you (upload)" "ANDROID BUILT: client-build/1.1.12+157" "PROMOTING: development @ a, main @ b"
ok "release card: Blocked on another manual step is 'waiting: you'" 'grn -q "^🚀 RELEASE: waiting: you"' "$(relname)"
# Only the user's own ship or hold is the release decision; another person's is not (release_state).
relu() { printf '[' >"$T/cards/Rel7777/actions"; local first=1; while [ $# -gt 0 ]; do [ $first = 1 ] || printf ',' >>"$T/cards/Rel7777/actions"; first=0
  printf '{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"%s","data":{"text":"%s"}}' "$1" "$2" >>"$T/cards/Rel7777/actions"; shift 2; done; printf ']' >>"$T/cards/Rel7777/actions"; }
relcards '"'"$BLOCKED"'"'
relu "$OTHER" "ship" "$CLAUDE" "GREEN*: main @ b, development @ a" "$CLAUDE" "PROMOTING: development @ a, main @ b"
ok "release card: another person's ship after GREEN* is not the decision ('waiting: sign-off')" '[ "$(relname)" = "🚀 RELEASE: waiting: sign-off" ]' "$(relname)"
relu "$USER" "ship" "$CLAUDE" "GREEN*: main @ b, development @ a" "$CLAUDE" "PROMOTING: development @ a, main @ b"
ok "release card: the user's own ship after GREEN* is the decision (no longer 'waiting: sign-off')" '! grn -q "waiting: sign-off"' "$(relname)"
cards '[{"id":"s6","name":"🚀 RELEASE: running","idList":"lx","idLabels":[],"idMembers":[],"shortLink":"Rel7777"}]'
relu "$OTHER" "hold" "$CLAUDE" "PROMOTING: development @ a, main @ b"
ok "release card: another person's hold is not the decision (not 'failed')" '! grn -q "RELEASE: failed"' "$(relname)"
relu "$USER" "hold" "$CLAUDE" "PROMOTING: development @ a, main @ b"
ok "release card: the user's own hold is the decision ('failed')" '[ "$(relname)" = "🚀 RELEASE: failed" ]' "$(relname)"
# Nothing covered left: failed (a failure comment) or released (a pin, no failure); nothing at all is idle.
cards '[{"id":"s6","name":"🚀 RELEASE: running","idList":"lx","idLabels":[],"idMembers":[],"shortLink":"Rel7777"}]'
rel "FULL SUITE FAILED: main @ b, development @ a: t" "PROMOTING: development @ a, main @ b"
ok "release card: no covered cards after a failure is 'failed'" '[ "$(relname)" = "🚀 RELEASE: failed" ]' "$(relname)"
rel "BETA PROMOTED: client-build/1.1.12+157" "PROMOTING: development @ a, main @ b"
ok "release card: no covered cards after a clean release is 'released'" '[ "$(relname)" = "🚀 RELEASE: released" ]' "$(relname)"
# A pin with nothing in RELEASING yet (the promoter has not moved the first card) is not "released".
printf 'running promoter card=Cov8888 id=p9 last=3s children=0 reqs=3 ctx=1000 - /x\n' >"$tmp/agents"
rel "PROMOTING: development @ a, main @ b"
ok "release card: a pin with nothing in RELEASING yet is 'running: full test', not released" '[ "$(relname)" = "🚀 RELEASE: running: full test" ]' "$(relname)"
: >"$tmp/agents"
# A failure followed by a success step does not count (a non-code deploy failure is a manual step that was fixed).
rel "BETA PROMOTED: client-build/1.1.12+157" "STAGING DEPLOYED: d, client-build/1.1.12+157 (main @ b)" "STAGING DEPLOY FAILED: runner offline" "PROMOTING: development @ a, main @ b"
ok "release card: a failure followed by a later success is 'released', not failed" '[ "$(relname)" = "🚀 RELEASE: released" ]' "$(relname)"
rel "STAGING DEPLOY FAILED: code error" "FULL SUITE GREEN: main @ b, development @ a" "PROMOTING: development @ a, main @ b"
ok "release card: a failure with no success after it is still 'failed'" '[ "$(relname)" = "🚀 RELEASE: failed" ]' "$(relname)"
rel "BETA PROMOTE FAILED: client-build/1.1.12+157" "STAGING DEPLOYED: d, client-build/1.1.12+157 (main @ b)" "PROMOTING: development @ a, main @ b"
ok "release card: a release ending in BETA PROMOTE FAILED is 'released'" '[ "$(relname)" = "🚀 RELEASE: released" ]' "$(relname)"
rel "ANDROID BUILT: client-build/1.1.12+157" "IOS BUILD FAILED: x" "STAGING DEPLOYED: d, client-build/1.1.12+157 (main @ b)" "PROMOTING: development @ a, main @ b"
ok "release card: one platform's build failure is not cleared by the other's success" '[ "$(relname)" = "🚀 RELEASE: failed" ]' "$(relname)"
rel "IOS BUILT: client-build/1.1.12+157" "ANDROID BUILD FAILED: x" "IOS BUILD FAILED: y" "PROMOTING: development @ a, main @ b"
ok "release card: a failure is cleared only by the same step's success" '[ "$(relname)" = "🚀 RELEASE: failed" ]' "$(relname)"
echo '[]' >"$T/cards/Rel7777/actions"
ok "release card: a card with no release comments and no covered cards is 'idle'" '[ "$(relname)" = "🚀 RELEASE: idle" ]' "$(relname)"
# The description carries the pair and the covered cards; written only when the name or description changed.
relcards ""
printf 'running promoter card=Cov8888 id=p9 last=3s children=0 reqs=3 ctx=1000 - /x\n' >"$tmp/agents"
rel "PROMOTING: development @ a, main @ b"
cards '[{"id":"s6","name":"🚀 RELEASE: running: full test","idList":"lx","idLabels":[],"idMembers":[],"shortLink":"Rel7777","desc":"**State:** running: full test\n**Pinned pair:** development @ a, main @ b\n**Newest step:** PROMOTING: development @ a, main @ b\n**Covered cards:** Covered card https://trello.com/c/Cov8888\n\nKept by board-wait.sh on every slow check. Agents only post the release comments; this name and description follow them."},{"id":"s7","name":"Covered card","idList":"lx","idLabels":[],"idMembers":[],"shortLink":"Cov8888"}]'
reset_writes; rm -f "$tmp/state-relcard.json"; run "$tmp/rc" Wr BOARD_WAIT_LIMIT=1 "$W"
ok "release card: name and description already true: no write" '! gw -q "^PUT "' "$(writes)"
relcards ""
reset_writes; rm -f "$tmp/state-relcard.json"; run "$tmp/rc" Wr BOARD_WAIT_LIMIT=1 "$W"
ok "release card: a stale description is rewritten" 'gw -q "^PUT /cards/s6 "' "$(writes)"
: >"$tmp/agents"
cards '[]'

# 9e. Waiting for shared resource: the want cards (in BUILDING) and the new startable TODO cards START: does not name.
W5() { env BOARD_WAIT_STATE=$tmp/state-queue.json "$@"; }
WR=000000000000000000000026
: >"$tmp/agents"
for k in Wnt11111 New22222 Ret33333 Blk44444 Gon55555 Old66666; do mkdir -p "$T/cards/$k"; echo '[]' >"$T/cards/$k/actions"; done
echo '[{"id":"b1","type":"commentCard","date":"'"$(iso $((now + 10)))"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"BEFORE: mobile card/x @ abc1234"}}]' >"$T/cards/Ret33333/actions"
printf 'test-server-1 Busy1111\ntest-server-2 Busy2222\ntest-server-3 Busy3333\n' >"$tmp/servers"
printf 'Wnt11111 normal 1\nGon55555 normal 1\n' >"$tmp/waiting"
cards '[{"id":"qWnt","name":"Wants AFTER","idList":"lb","idLabels":[],"idMembers":[],"shortLink":"Wnt11111"},
        {"id":"qNew","name":"New card","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"New22222"},
        {"id":"qRet","name":"Returning card","idList":"lt","idLabels":["'"$WR"'"],"idMembers":[],"shortLink":"Ret33333"},
        {"id":"qBlk","name":"Blocked new","idList":"lt","idLabels":["'"$BLOCKED"'","'"$WR"'"],"idMembers":[],"shortLink":"Blk44444"},
        {"id":"qGon","name":"Stale want, in REVIEW","idList":"lr","idLabels":[],"idMembers":[],"shortLink":"Gon55555"},
        {"id":"qSta","name":"⛔ BLOCKED: status","idList":"lt","idLabels":["'"$WR"'"],"idMembers":[],"shortLink":"StaT5555"}]'
reset_writes
run "$tmp/q1" W5 BOARD_WAIT_LIMIT=1 "$W"
ok "queue label: a want card in BUILDING gets it" 'gw -qx "POST /cards/qWnt/idLabels $WR"' "$(writes)"
ok "queue label: a new startable TODO card with no free server gets it (START: has nothing to print for it)" 'gw -qx "POST /cards/qNew/idLabels $WR"' "$(writes)"
ok "queue label: a returning card loses it (it needs no server)" 'gw -qx "DELETE /cards/qRet/idLabels/$WR"' "$(writes)"
ok "queue label: a Blocked card loses it" 'gw -qx "DELETE /cards/qBlk/idLabels/$WR"' "$(writes)"
ok "queue label: a want of a card not in BUILDING gets none" '! gw -q "POST /cards/qGon"' "$(writes)"
ok "queue label: a status card is left alone" '! gw -q qSta' "$(writes)"
cards '[{"id":"qWnt","name":"Wants AFTER","idList":"lb","idLabels":["'"$WR"'"],"idMembers":[],"shortLink":"Wnt11111"},
        {"id":"qNew","name":"New card","idList":"lt","idLabels":["'"$WR"'"],"idMembers":[],"shortLink":"New22222"}]'
reset_writes
run "$tmp/q2" W5 BOARD_WAIT_LIMIT=1 "$W"
ok "queue label: a card that already has it is not written again" '! gw -q "qWnt\|qNew"' "$(writes)"
touch "$tmp/waiting-fails"; : >"$tmp/waiting"
reset_writes
run "$tmp/q3" W5 BOARD_WAIT_LIMIT=1 "$W"
ok "queue label: a failed waiting read changes no label" '! gw -q "$WR"' "$(writes)"
rm "$tmp/waiting-fails"; touch "$tmp/list-fails"
reset_writes
run "$tmp/q4" W5 BOARD_WAIT_LIMIT=1 "$W"
ok "queue label: a failed list read changes no label" '! gw -q "$WR"' "$(writes)"
rm "$tmp/list-fails"
printf 'test-server-1 free\ntest-server-2 Busy2222\ntest-server-3 Busy3333\n' >"$tmp/servers"
reset_writes
run "$tmp/q5" W5 BOARD_WAIT_LIMIT=1 "$W"
ok "queue label: with a server free for the new card (no wants) it loses the label" 'gw -qx "DELETE /cards/qNew/idLabels/$WR"' "$(writes)"
ok "queue label: a want card whose want file is gone loses it" 'gw -qx "DELETE /cards/qWnt/idLabels/$WR"' "$(writes)"
# The stuck check ignores the label: a BUILDING card with it, no want file and no agent is still reported.
cards '[{"id":"qWnt","name":"Label but no want","idList":"lb","idLabels":["'"$WR"'"],"idMembers":[],"shortLink":"Wnt11111"}]'
run "$tmp/q6" env BOARD_WAIT_STATE=$tmp/state-queue-stuck.json BOARD_WAIT_STUCK_GRACE=0 BOARD_WAIT_STUCK_REPEAT=0 BOARD_WAIT_LIMIT=2 "$W"
ok "queue label: the stuck check ignores the label" 'grep -qx "STUCK: \"Label but no want\" \[Wnt11111\] (BUILDING): no agent is working on it" "$tmp/q6"' "$(cat "$tmp/q6")"
: >"$tmp/waiting"
printf 'test-server-1 Busy1111\ntest-server-2 Busy2222\ntest-server-3 Busy3333\n' >"$tmp/servers"
cards '[]'

# 9f. Non-agent TODO cards: a title tag keeps a card out of START: and the held-TODO deadline; any other
# non-agent card is startable until it leaves TODO (the watcher sends it to QUESTIONS at pickup). A picked-up
# card waiting in TODO keeps its wait. Its own state file, so the cases above are not disturbed.
W4() { env BOARD_WAIT_STATE=$tmp/state-skip.json BOARD_WAIT_START_REPEAT=0 "$@"; }
for k in TagW1111 TagU1111 NonA1111 TdoW1111 TdoU1111; do mkdir -p "$T/cards/$k"; echo '[]' >"$T/cards/$k/actions"; done
printf 'test-server-1 free\ntest-server-2 Busy2222\ntest-server-3 Busy3333\n' >"$tmp/servers"
: >"$tmp/agents"; : >"$tmp/waiting"
cards '[{"id":"g1","name":"[Webapp] Admin page","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"TagW1111","desc":""},
        {"id":"g2","name":"[REFERENCE] Store listing copy","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"TagR1111","desc":""},
        {"id":"g3","name":"[MILESTONE] Beta","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"TagM1111","desc":""}]'
run "$tmp/s1" W4 BOARD_WAIT_LIMIT=1 "$W"
ok "non-agent: a card with a non-agent title tag is not startable (no START: with a free server)" '[ "$(rc "$tmp/s1")" = 3 ] && ! grep -q "^START" "$tmp/s1"' "rc=$(rc "$tmp/s1") $(cat "$tmp/s1")"
cards '[{"id":"g4","name":"🚨 [Webapp] Admin page down","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"TagU1111","desc":""}]'
run "$tmp/s1b" W4 BOARD_WAIT_LIMIT=2 "$W"
ok "non-agent: a 🚨 card with a title tag is still startable (the watcher sends it to QUESTIONS)" 'grep -qx "START: 1 free card test server; TODO has 1 startable card (TagU1111)" "$tmp/s1b"' "$(cat "$tmp/s1b")"
cards '[{"id":"g5","name":"Submit the app to the stores","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"NonA1111","desc":"Fill in the forms"}]'
run "$tmp/s2" W4 BOARD_WAIT_LIMIT=2 "$W"
ok "non-agent: an untagged non-agent card in TODO is startable (the watcher sends it to QUESTIONS at pickup)" 'grep -q "^START: .*(NonA1111)" "$tmp/s2"' "$(cat "$tmp/s2")"
cards '[{"id":"g5","name":"Submit the app to the stores","idList":"lq","idLabels":[],"idMembers":[],"shortLink":"NonA1111","desc":"Fill in the forms"}]'
run "$tmp/s3" W4 BOARD_WAIT_LIMIT=1 "$W"
ok "non-agent: once it leaves TODO for QUESTIONS it is not startable" '[ "$(rc "$tmp/s3")" = 3 ] && ! grep -q "^START" "$tmp/s3"' "rc=$(rc "$tmp/s3") $(cat "$tmp/s3")"
# The held-TODO deadline: no free server for over 2 hours, TODO holds only a tagged card: no wake.
cards '[{"id":"g1","name":"[Webapp] Admin page","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"TagW1111","desc":""}]'
printf 'test-server-1 Busy1111\ntest-server-2 Busy2222\ntest-server-3 Busy3333\n' >"$tmp/servers"
run "$tmp/s4" W4 BOARD_WAIT_LIMIT=1 "$W"
python3 -I - "$tmp/state-skip.json" <<'PY2'
import json, sys, time
s = json.load(open(sys.argv[1])); s["marks"]["todo-held-since"] = time.time() - 2 * 3600 - 60; s["marks"].pop("todo-held", None)
json.dump(s, open(sys.argv[1], "w"))
PY2
run "$tmp/s5" W4 BOARD_WAIT_LIMIT=1 "$W"
ok "non-agent: the held-TODO deadline ignores a tagged card" '[ "$(rc "$tmp/s5")" = 3 ] && ! grep -q "DEADLINE: startable" "$tmp/s5"' "rc=$(rc "$tmp/s5") $(cat "$tmp/s5")"
# A card already picked up and waiting in TODO keeps its wait: Blocked goes on, and UNBLOCKED: takes it off.
cards '[{"id":"g6","name":"Waits in TODO","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"TdoW1111","desc":""},
        {"id":"g7","name":"Unblocked in TODO","idList":"lt","idLabels":["'"$BLOCKED"'","'"$NOA"'"],"idMembers":[],"shortLink":"TdoU1111","desc":""}]'
cm 9 "WAITS FOR: The other card (#40), for its endpoint" >"$T/cards/TdoW1111/actions"
echo '[{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"WAITS FOR: x"}},{"date":"2026-10-15T10:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"UNBLOCKED: x merged"}}]' >"$T/cards/TdoU1111/actions"
reset_writes
run "$tmp/s6" W4 BOARD_WAIT_LIMIT=1 "$W"
ok "non-agent: a picked-up TODO card with a WAITS FOR: still gets the Blocked label" 'gw -qx "POST /cards/g6/idLabels $BLOCKED"' "$(writes)"
ok "non-agent: UNBLOCKED: still takes the labels off a TODO card" 'gw -qx "DELETE /cards/g7/idLabels/$BLOCKED" && gw -qx "DELETE /cards/g7/idLabels/$NOA"' "$(writes)"
cards '[]'

# 9g. The release UI hold (card xUEx4rdv): while the release's full test runs no normal card is named in START:.
real_hold_before=$(stat -f %m "$HOME/Development/example_files/test-servers/release-ui-hold" 2>/dev/null || echo none)
W6() { env BOARD_WAIT_STATE=$tmp/state-hold.json "$@"; }
rm -f "$tmp/hold-file" "$tmp/state-hold.json"
mkdir -p "$T/cards/Hld11111" "$T/cards/Hld22222"; echo '[]' >"$T/cards/Hld11111/actions"; echo '[]' >"$T/cards/Hld22222/actions"
holdcards() { cards '[{"id":"hR","name":"🚀 RELEASE: idle","idList":"lx","idLabels":[],"idMembers":[],"shortLink":"RelH1111"},{"id":"hC","name":"Covered","idList":"lx","idLabels":[],"idMembers":[],"shortLink":"Cov9999"},{"id":"hN","name":"Normal new","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"Hld11111"}'"$1"']'; }
mkdir -p "$T/cards/RelH1111" "$T/cards/Cov9999"; echo '[]' >"$T/cards/Cov9999/actions"
echo '[{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"PROMOTING: development @ a, main @ b"}}]' >"$T/cards/RelH1111/actions"
printf 'test-server-1 free\ntest-server-2 Busy2222\ntest-server-3 Busy3333\n' >"$tmp/servers"; : >"$tmp/waiting"
printf 'waiting promoter card=RelH1111 id=p1 last=60s children=0 reqs=1 ctx=1 - /x\n' >"$tmp/agents"
holdcards ""
run "$tmp/hd1" W6 BOARD_WAIT_LIMIT=2 BOARD_WAIT_START_REPEAT=0 "$W"
ok "release hold: a normal card IS named in START: while the full test runs (the hold waits at the UI start)" 'grep -q "^START: .*Hld11111" "$tmp/hd1"' "$(cat "$tmp/hd1")"
ok "release hold: RELEASE UI HOLD: once, with the new meaning" '[ "$(grep -c "^RELEASE UI HOLD: " "$tmp/hd1")" = 1 ] && grep -q "card UI runs wait before their first emulator use (API runs go on)" "$tmp/hd1"' "$(cat "$tmp/hd1")"
ok "release hold: the hold file is set (fake card-test-server.sh, never the real directory)" '[ "$(cat "$tmp/hold-file")" = RelH1111 ]'
run "$tmp/hd2" W6 BOARD_WAIT_LIMIT=1 BOARD_WAIT_START_REPEAT=0 "$W"
ok "release hold: not printed again on the next poll" '! grep -q "RELEASE UI HOLD" "$tmp/hd2"' "$(cat "$tmp/hd2")"
holdcards ',{"id":"hU","name":"🚨 Urgent new","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"Hld22222"}'
run "$tmp/hd3" W6 BOARD_WAIT_LIMIT=2 BOARD_WAIT_START_REPEAT=0 "$W"
ok "release hold: a 🚨 card is named too" 'grep -q "^START: .*Hld22222" "$tmp/hd3"' "$(cat "$tmp/hd3")"
holdcards ""
echo "Hld11111 normal 1" >"$tmp/waiting"
cards '[{"id":"hR","name":"🚀 RELEASE: idle","idList":"lx","idLabels":[],"idMembers":[],"shortLink":"RelH1111"},{"id":"hC","name":"Covered","idList":"lx","idLabels":[],"idMembers":[],"shortLink":"Cov9999"},{"id":"hN","name":"Normal want","idList":"lb","idLabels":[],"idMembers":[],"shortLink":"Hld11111"}]'
run "$tmp/hd4" W6 BOARD_WAIT_LIMIT=2 BOARD_WAIT_START_REPEAT=0 "$W"
ok "release hold: a want card in BUILDING is named (its AFTER run gets a server) and not STUCK:" 'grep -q "^START: .*Hld11111" "$tmp/hd4" && ! grep -q "^STUCK" "$tmp/hd4"' "$(cat "$tmp/hd4")"
: >"$tmp/waiting"; holdcards ""
echo '[{"date":"2026-10-15T09:10:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"FULL SUITE GREEN: main @ b, development @ a"}},{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"PROMOTING: development @ a, main @ b"}}]' >"$T/cards/RelH1111/actions"
run "$tmp/hd5" W6 BOARD_WAIT_LIMIT=2 BOARD_WAIT_START_REPEAT=0 "$W"
ok "release hold: RELEASE UI HOLD ENDED: once, the file is removed, START: names the card" '[ "$(grep -c "^RELEASE UI HOLD ENDED: " "$tmp/hd5")" = 1 ] && [ ! -f "$tmp/hold-file" ] && grep -q "^START: .*Hld11111" "$tmp/hd5"' "$(cat "$tmp/hd5")"
# A stall and a VOID rerun under the same PROMOTING: is a second episode with its own pair of lines.
echo '[{"date":"2026-10-15T09:20:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"FULL SUITE VOID: host went away"}},{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"PROMOTING: development @ a, main @ b"}}]' >"$T/cards/RelH1111/actions"
run "$tmp/hd6" W6 BOARD_WAIT_LIMIT=2 BOARD_WAIT_START_REPEAT=0 "$W"
ok "release hold: a VOID rerun is a new hold episode with a new start line" '[ "$(grep -c "^RELEASE UI HOLD: " "$tmp/hd6")" = 1 ] && [ -f "$tmp/hold-file" ]' "$(cat "$tmp/hd6")"
: >"$tmp/agents"
run "$tmp/hd7" W6 BOARD_WAIT_LIMIT=2 BOARD_WAIT_START_REPEAT=0 "$W"
ok "release hold: no promoter alive (stalled) ends the hold" 'grep -q "^RELEASE UI HOLD ENDED: " "$tmp/hd7" && [ ! -f "$tmp/hold-file" ]' "$(cat "$tmp/hd7")"
printf 'waiting promoter card=RelH1111 id=p1 last=60s children=0 reqs=1 ctx=1 - /x\n' >"$tmp/agents"
echo '[{"date":"2026-10-15T09:20:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"STAGING DEPLOYED: x"}},{"date":"2026-10-15T09:10:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"FULL SUITE GREEN: main @ b, development @ a"}},{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"PROMOTING: development @ a, main @ b"}}]' >"$T/cards/RelH1111/actions"
run "$tmp/hd8" W6 BOARD_WAIT_LIMIT=2 BOARD_WAIT_START_REPEAT=0 "$W"
ok "release hold: a later release step (no covered card read as running: staging deploy) holds nothing" '! grep -q "^RELEASE UI HOLD: " "$tmp/hd8" && [ ! -f "$tmp/hold-file" ]' "$(cat "$tmp/hd8")"
# (f) a failed release holds nothing.
echo '[{"date":"2026-10-15T09:20:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"FULL SUITE FAILED: x"}},{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"PROMOTING: development @ a, main @ b"}}]' >"$T/cards/RelH1111/actions"
run "$tmp/hd9" W6 BOARD_WAIT_LIMIT=2 BOARD_WAIT_START_REPEAT=0 "$W"
ok "release hold: a failed release holds nothing" '! grep -q "^RELEASE UI HOLD: " "$tmp/hd9" && [ ! -f "$tmp/hold-file" ]' "$(cat "$tmp/hd9")"
# Hold on again, then (g) a failed card-text read keeps the decision, and the bound ends it.
echo '[{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"PROMOTING: development @ a, main @ b"}}]' >"$T/cards/RelH1111/actions"
mv "$tmp/state-hold.json" "$tmp/state-hold.json.keep"; rm -f "$tmp/state-hold.json"
holdcards ""
run "$tmp/hd10" W6 BOARD_WAIT_LIMIT=2 BOARD_WAIT_START_REPEAT=0 "$W"
mv "$T/cards/RelH1111/actions" "$T/cards/RelH1111/actions.off"
run "$tmp/hd11" W6 BOARD_WAIT_LIMIT=2 BOARD_WAIT_START_REPEAT=0 "$W"
ok "release hold: a failed card-text read keeps the earlier decision" '[ -f "$tmp/hold-file" ] && ! grep -q "RELEASE UI HOLD ENDED" "$tmp/hd11"' "$(cat "$tmp/hd11")"
python3 -I - "$tmp/state-hold.json" <<'PY2'
import json, sys, time
s = json.load(open(sys.argv[1])); s["release_hold"]["decided_at"] = time.time() - 901
json.dump(s, open(sys.argv[1], "w"))
PY2
run "$tmp/hd12" W6 BOARD_WAIT_LIMIT=2 BOARD_WAIT_START_REPEAT=0 "$W"
ok "release hold: a decision older than 15 minutes ends the hold (ENDED: once, file cleared)" '[ "$(grep -c "^RELEASE UI HOLD ENDED: " "$tmp/hd12")" = 1 ] && [ ! -f "$tmp/hold-file" ]' "$(cat "$tmp/hd12")"
mv "$T/cards/RelH1111/actions.off" "$T/cards/RelH1111/actions"
# The bound ended the hold above (ENDED: printed, file cleared). The hold resumes under the same state: a new episode
# with its own start line, then its own ENDED: line when the full test ends.
run "$tmp/hd12b" W6 BOARD_WAIT_LIMIT=2 BOARD_WAIT_START_REPEAT=0 "$W"
ok "release hold: after the bound a resumed hold prints a new RELEASE UI HOLD: line and sets the file" '[ "$(grep -c "^RELEASE UI HOLD: " "$tmp/hd12b")" = 1 ] && [ -f "$tmp/hold-file" ]' "$(cat "$tmp/hd12b")"
echo '[{"date":"2026-10-15T09:10:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"FULL SUITE GREEN: main @ b, development @ a"}},{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"PROMOTING: development @ a, main @ b"}}]' >"$T/cards/RelH1111/actions"
run "$tmp/hd12c" W6 BOARD_WAIT_LIMIT=2 BOARD_WAIT_START_REPEAT=0 "$W"
ok "release hold: the resumed hold prints RELEASE UI HOLD ENDED: once and clears the file" '[ "$(grep -c "^RELEASE UI HOLD ENDED: " "$tmp/hd12c")" = 1 ] && [ ! -f "$tmp/hold-file" ]' "$(cat "$tmp/hd12c")"
echo '[{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"PROMOTING: development @ a, main @ b"}}]' >"$T/cards/RelH1111/actions"
# The hold on again, then the release status card disappears from a successful board read: ENDED: once.
rm -f "$tmp/state-hold.json"
run "$tmp/hd13" W6 BOARD_WAIT_LIMIT=2 BOARD_WAIT_START_REPEAT=0 "$W"
cards '[{"id":"hC","name":"Covered","idList":"lx","idLabels":[],"idMembers":[],"shortLink":"Cov9999"},{"id":"hN","name":"Normal new","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"Hld11111"}]'
run "$tmp/hd14" W6 BOARD_WAIT_LIMIT=2 BOARD_WAIT_START_REPEAT=0 "$W"
ok "release hold: a missing release card ends the hold (ENDED: once, file cleared)" '[ -f "$tmp/hd13" ] && grep -q "^RELEASE UI HOLD: " "$tmp/hd13" && [ "$(grep -c "^RELEASE UI HOLD ENDED: " "$tmp/hd14")" = 1 ] && [ ! -f "$tmp/hold-file" ]' "$(cat "$tmp/hd13" "$tmp/hd14")"
# (i) the real state directory is untouched.
ok "release hold: the real state directory is untouched" '[ ! -e "$HOME/Development/example_files/test-servers/release-ui-hold" ] || [ "$(stat -f %m "$HOME/Development/example_files/test-servers/release-ui-hold")" = "$real_hold_before" ]'
: >"$tmp/agents"; cards '[]'

# 10. A Trello failure doesn't end the wait with a false event; it ends QUIET with a note.
mv "$T/boards/AbCd1234/lists" "$T/boards/AbCd1234/lists.off"
run "$tmp/o19" env BOARD_WAIT_LIMIT=1 "$W"
ok "trello: a failed read is QUIET plus a note on stderr" '[ "$(rc "$tmp/o19")" = 3 ] && grep -q "board-wait: Trello" "$tmp/o19"' "rc=$(rc "$tmp/o19") $(cat "$tmp/o19")"
mv "$T/boards/AbCd1234/lists.off" "$T/boards/AbCd1234/lists"

# 11. The Mac's disk (card https://trello.com/c/O6PJ58xL): DISK LOW:/DISK REMOVE:/DISK CRITICAL:/DISK OK:, the hold, the selection of
# removable worktrees. A temporary repo with a bare remote and worktrees named like the real ones; a fake
# card-test-server that logs its disk-hold calls; no network.
R=$tmp/drepo; mkdir -p "$R"
gitq() { git -c user.name=t -c user.email=t@t "$@"; }
gitq init -q -b main "$R" && gitq -C "$R" commit -q --allow-empty -m base
gitq init -q --bare "$tmp/dremote.git" && gitq -C "$R" remote add origin "$tmp/dremote.git" && gitq -C "$R" push -q -u origin main 2>/dev/null
WT=$R/.claude/worktrees; mkdir -p "$WT"
wtadd() { gitq -C "$R" worktree add -q --detach "$WT/$1" HEAD; }
for n in feature-tester-MrgdCard mobile-builder-DoneCard test-builder-ArchCard feature-tester-BldgCard workflow-builder-WflwCard \
         feature-tester-LiveCard mobile-builder-DirtCard mobile-builder-UnpuCard feature-tester-LookFail mobile-builder-LookFail feature-tester-TestCard; do wtadd "$n"; done
gitq -C "$R" worktree add -q -b unbr-branch "$WT/mobile-builder-UnbrCard" HEAD
mkdir -p "$WT/testhost-deploy-20261009" "$WT/testhost-deploy-20261009b" "$WT/merger-12345678" "$WT/builds"
touch "$WT/mobile-builder-DirtCard/untracked.txt"
gitq -C "$WT/mobile-builder-UnpuCard" commit -q --allow-empty -m local
gitq -C "$WT/mobile-builder-UnbrCard" commit -q --allow-empty -m local
cat >"$T/boards/AbCd1234/lists" <<'EOF'
[{"id":"lt","name":"TODO 📚"},{"id":"lw","name":"WORKFLOW 🤖"},{"id":"lb","name":"BUILDING"},{"id":"lg","name":"TESTING"},
 {"id":"lm","name":"MERGING"},{"id":"ld","name":"MERGED"},{"id":"lz","name":"DONE! 🙌🏽"}]
EOF
dcard() { printf '{"id":"d%s","name":"Card %s","idList":"%s","idLabels":[],"idMembers":[],"shortLink":"%s","desc":""}' "$2" "$2" "$1" "$2"; }
dcards() { cards "[$(dcard ld MrgdCard),$(dcard lz DoneCard),$(dcard lb BldgCard),$(dcard lw WflwCard),$(dcard lm LiveCard),$(dcard lz DirtCard),$(dcard lz UnpuCard),$(dcard lz UnbrCard),$(dcard lg TestCard)]"; }
dcards
for k in MrgdCard DoneCard BldgCard WflwCard LiveCard DirtCard UnpuCard UnbrCard TestCard; do mkdir -p "$T/cards/$k"; echo '[]' >"$T/cards/$k/actions"; done
echo '{"closed":true}' >"$T/cards/ArchCard"       # a card Trello knows as archived; LookFail has no such file (404)
printf 'running feature-tester card=LiveCard id=live1 last=5s children=0\n' >"$tmp/agents"
: >"$tmp/waiting"
printf '#!/usr/bin/env bash\nif [ "${1:-}" = waiting ]; then exit 0; fi\nif [ "${1:-}" = disk-hold ]; then echo "$*" >>%s/hold.log; exit 0; fi\ncat %s/servers\n' "$tmp" "$tmp" >"$tmp/fakebin/card-test-server-disk"
chmod +x "$tmp/fakebin/card-test-server-disk"
printf 'test-server-1 free\ntest-server-2 Busy2222\ntest-server-3 Busy3333\n' >"$tmp/servers"
mkdir -p "$tmp/dfold/a"
DW() { env BOARD_WAIT_STATE=$tmp/dstate.json BOARD_WAIT_WORKTREE_REPOS="$R" BOARD_WAIT_CARD_TEST_SERVER=$tmp/fakebin/card-test-server-disk \
  BOARD_WAIT_CLEAN_OK=$tmp/clean.ok BOARD_WAIT_DISK_FOLDERS="$tmp/dfold" BOARD_WAIT_START_REPEAT=0 "$@"; }
dstate() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])).get("disk",{}); print(json.dumps(d.get(sys.argv[2])))' "$tmp/dstate.json" "$1"; }
rm -f "$tmp/hold.log" "$tmp/clean.ok"
echo '{}' >"$tmp/dstate.json"   # an existing state without a holds key: the holds are complete (no HOLDS KNOWN: wake)

run "$tmp/dk0" DW BOARD_WAIT_DISK_FREE_GB=80 BOARD_WAIT_LIMIT=2 "$W"
ok "disk: free space above the low mark prints no DISK line and holds nothing" '[ "$(rc "$tmp/dk0")" = 3 ] && ! grep -q "^DISK" "$tmp/dk0" && [ ! -s "$tmp/hold.log" ]' "$(cat "$tmp/dk0")"
run "$tmp/dk1" DW BOARD_WAIT_DISK_FREE_GB=30 BOARD_WAIT_LIMIT=5 "$W"
ok "disk: below the low mark with candidates: DISK LOW: with the count, then the DISK REMOVE: lines" 'grep -q "^DISK LOW: 30 GB free (.*% used); 3 removable worktrees" "$tmp/dk1" && [ "$(grep -c "^DISK REMOVE:" "$tmp/dk1")" = 3 ]' "$(cat "$tmp/dk1")"
ok "disk: a merged card, a done card and an archived card (card lookup says closed) are removed, with the exact command" 'grep -q "^DISK REMOVE: .* GB: git -C $R worktree remove $WT/feature-tester-MrgdCard\$" "$tmp/dk1" && grep -q "worktree remove $WT/mobile-builder-DoneCard\$" "$tmp/dk1" && grep -q "worktree remove $WT/test-builder-ArchCard\$" "$tmp/dk1"' "$(cat "$tmp/dk1")"
ok "disk: BUILDING, TESTING, WORKFLOW, a live agent, a dirty tree, an unpushed detached HEAD, an unpushed branch, a failed card lookup and folders not named like a card's are kept" '! grep -qE "BldgCard|TestCard|WflwCard|LiveCard|DirtCard|UnpuCard|UnbrCard|LookFail|testhost|merger|builds" <<<"$(grep "^DISK" "$tmp/dk1")"' "$(cat "$tmp/dk1")"
ok "disk: two worktrees of a card whose lookup failed cost one lookup (one warning), and both are kept" '[ "$(grep -c "card lookup LookFail failed" "$tmp/dk1")" = 1 ]' "$(grep "card lookup" "$tmp/dk1")"
ok "disk: no command carries --force" '! grep -q -- "--force" "$tmp/dk1"'
# the clock survives a fast poll (BOARD_WAIT_SLOW large: no slow check) and a later slow check inside the repeat
run "$tmp/dk2" DW BOARD_WAIT_DISK_FREE_GB=30 BOARD_WAIT_SLOW=100000 BOARD_WAIT_LIMIT=1 "$W"
run "$tmp/dk3" DW BOARD_WAIT_DISK_FREE_GB=30 BOARD_WAIT_LIMIT=2 "$W"
ok "disk: a fast poll and then a slow check inside the repeat print no second DISK LOW:" '[ "$(rc "$tmp/dk2")" = 3 ] && [ "$(rc "$tmp/dk3")" = 3 ] && ! grep -q "^DISK" "$tmp/dk2" "$tmp/dk3"' "$(cat "$tmp/dk2") $(cat "$tmp/dk3")"
run "$tmp/dk4" DW BOARD_WAIT_DISK_FREE_GB=30 BOARD_WAIT_DISK_REPEAT=0 BOARD_WAIT_LIMIT=5 "$W"
ok "disk: at the low level the repeat keeps its DISK LOW: header" 'grep -q "^DISK LOW: 30 GB free" "$tmp/dk4"' "$(cat "$tmp/dk4")"
ok "disk: after the repeat it comes again; before worktree-clean.ok exists a printed path is not judged failed" '[ "$(grep -c "^DISK REMOVE:" "$tmp/dk4")" = 3 ]' "$(cat "$tmp/dk4")"
touch "$tmp/clean.ok"
run "$tmp/dk5" DW BOARD_WAIT_DISK_FREE_GB=30 BOARD_WAIT_DISK_REPEAT=0 BOARD_WAIT_LIMIT=5 "$W"
ok "disk: with the first run passed, a path printed before and still there is a failed removal: not printed again, and nothing removable is said once" '! grep -q "^DISK REMOVE:" "$tmp/dk5" && grep -q "^DISK LOW: 30 GB free (.*% used); nothing removable (the rest is: .*dfold" "$tmp/dk5" && [ "$(dstate failed | python3 -I -c "import json,sys; print(len(json.load(sys.stdin)))")" = 3 ]' "$(cat "$tmp/dk5")"
run "$tmp/dk6" DW BOARD_WAIT_DISK_FREE_GB=28 BOARD_WAIT_DISK_REPEAT=0 BOARD_WAIT_LIMIT=2 "$W"
run "$tmp/dk7" DW BOARD_WAIT_DISK_FREE_GB=24 BOARD_WAIT_DISK_REPEAT=0 BOARD_WAIT_LIMIT=2 "$W"
ok "disk: nothing removable is not repeated, and comes again only after a 5 GB fall" '! grep -q "^DISK" "$tmp/dk6" && grep -q "^DISK LOW: 24 GB free.*nothing removable" "$tmp/dk7"' "$(cat "$tmp/dk6") / $(cat "$tmp/dk7")"
# a failed removal is offered again when HEAD changes or after the TTL
fhead=$(gitq -C "$WT/feature-tester-MrgdCard" rev-parse HEAD)
ok "disk: a failed entry stores the worktree's HEAD sha" '[ "$(dstate failed | python3 -I -c "import json,sys; print(json.load(sys.stdin)[sys.argv[1]][\"head\"])" "$WT/feature-tester-MrgdCard")" = "$fhead" ]' "$(dstate failed)"
gitq -C "$WT/feature-tester-MrgdCard" commit -q --allow-empty -m moved
gitq -C "$WT/feature-tester-MrgdCard" push -q origin HEAD:refs/heads/moved 2>/dev/null || gitq -C "$WT/feature-tester-MrgdCard" update-ref refs/remotes/origin/moved HEAD
run "$tmp/dk5b" DW BOARD_WAIT_DISK_FREE_GB=24 BOARD_WAIT_DISK_ROUTINE=0 BOARD_WAIT_DISK_REPEAT=0 BOARD_WAIT_LIMIT=5 "$W"
ok "disk: a failed worktree whose HEAD changed is offered again (only that one)" '[ "$(grep -c "^DISK REMOVE:" "$tmp/dk5b")" = 1 ] && grep -q "worktree remove $WT/feature-tester-MrgdCard\$" "$tmp/dk5b"' "$(cat "$tmp/dk5b")"
run "$tmp/dk5c" DW BOARD_WAIT_DISK_FREE_GB=24 BOARD_WAIT_DISK_ROUTINE=0 BOARD_WAIT_DISK_REPEAT=0 BOARD_WAIT_DISK_FAILED_TTL=0 BOARD_WAIT_LIMIT=5 "$W"
ok "disk: with BOARD_WAIT_DISK_FAILED_TTL expired the failed worktrees are offered again (the one just printed counts as failed again at once)" '[ "$(grep -c "^DISK REMOVE:" "$tmp/dk5c")" = 2 ]' "$(cat "$tmp/dk5c")"
run "$tmp/dk5d" DW BOARD_WAIT_DISK_FREE_GB=24 BOARD_WAIT_DISK_ROUTINE=0 BOARD_WAIT_DISK_REPEAT=0 BOARD_WAIT_LIMIT=5 "$W"
ok "disk: printed again after the TTL and still there, they are failed again and not offered a third time" '! grep -q "^DISK REMOVE:" "$tmp/dk5d"' "$(cat "$tmp/dk5d")"
# a calculation that finds candidates but emits no line (k=0, a 5 GB fall inside the repeat window) records no path as printed
run "$tmp/dk5e" DW BOARD_WAIT_DISK_FREE_GB=18 BOARD_WAIT_DISK_FAILED_TTL=0 BOARD_WAIT_LIMIT=5 "$W"
ok "disk: candidates found on a step-only calculation with no line due print nothing and are not recorded as printed" '! grep -q "^DISK" "$tmp/dk5e" && [ "$(dstate printed)" = "{}" ]' "$(cat "$tmp/dk5e") / $(dstate printed)"
run "$tmp/dk5f" DW BOARD_WAIT_DISK_FREE_GB=18 BOARD_WAIT_DISK_FAILED_TTL=0 BOARD_WAIT_DISK_REPEAT=0 BOARD_WAIT_LIMIT=5 "$W"
ok "disk: the next calculation still offers them (they were not hidden as failed removals)" '[ "$(grep -c "^DISK REMOVE:" "$tmp/dk5f")" = 3 ]' "$(cat "$tmp/dk5f")"
run "$tmp/dk8" DW BOARD_WAIT_DISK_FREE_GB=80 BOARD_WAIT_LIMIT=2 "$W"
ok "disk: back above the low mark: one DISK OK:, none after it" 'grep -qx "DISK OK: 80 GB free" "$tmp/dk8" && [ "$(dstate level)" = "\"ok\"" ]' "$(cat "$tmp/dk8")"
# CRITICAL: the hold is set, refreshed, lifted at the floor; 9 -> 11 -> 9 -> 4 GB prints two DISK CRITICAL: lines in all
rm -f "$tmp/dstate.json" "$tmp/hold.log" "$tmp/clean.ok"
run "$tmp/dc1" DW BOARD_WAIT_DISK_FREE_GB=9 BOARD_WAIT_LIMIT=5 "$W"
ok "disk: below the floor: DISK CRITICAL: with the removable lines, and the hold is set" 'grep -q "^DISK CRITICAL: 9 GB free (.*% used); the main session must act; no new BEFORE runs$" "$tmp/dc1" && grep -q "^DISK REMOVE:" "$tmp/dc1" && grep -qx "disk-hold set 9" "$tmp/hold.log"' "$(cat "$tmp/dc1") / $(cat "$tmp/hold.log")"
run "$tmp/dc1b" DW BOARD_WAIT_DISK_FREE_GB=9 BOARD_WAIT_DISK_REPEAT=0 BOARD_WAIT_LIMIT=5 "$W"
ok "disk: the critical level's repeat prints the DISK REMOVE: lines with no DISK LOW: or DISK CRITICAL: line" '[ "$(grep -c "^DISK REMOVE:" "$tmp/dc1b")" = 3 ] && ! grep -qE "^DISK (LOW|CRITICAL):" "$tmp/dc1b"' "$(cat "$tmp/dc1b")"
run "$tmp/dc2" DW BOARD_WAIT_DISK_FREE_GB=11 BOARD_WAIT_LIMIT=2 "$W"
ok "disk: back at or above the floor (11 GB, below the low mark) the hold is cleared and no DISK OK: prints" 'tail -n 1 "$tmp/hold.log" | grep -qx "disk-hold clear" && ! grep -q "DISK OK" "$tmp/dc2" && [ "$(dstate level)" = "\"low\"" ]' "$(cat "$tmp/dc2") / $(cat "$tmp/hold.log")"
run "$tmp/dc3" DW BOARD_WAIT_DISK_FREE_GB=9 BOARD_WAIT_LIMIT=2 "$W"
ok "disk: back below the floor in the same episode sets the hold again but prints no second DISK CRITICAL: (no 5 GB fall)" 'tail -n 1 "$tmp/hold.log" | grep -qx "disk-hold set 9" && ! grep -q "^DISK CRITICAL" "$tmp/dc3"' "$(cat "$tmp/dc3")"
run "$tmp/dc4" DW BOARD_WAIT_DISK_FREE_GB=4 BOARD_WAIT_LIMIT=2 "$W"
ok "disk: a fall of 5 GB below the last DISK CRITICAL: prints it again" 'grep -q "^DISK CRITICAL: 4 GB free" "$tmp/dc4"' "$(cat "$tmp/dc4")"
# a du reporting 10000000 KB is 10.2 decimal GB (10.0 GiB would print 9.5)
printf '#!/usr/bin/env bash\necho "10000000\t$2"\n' >"$tmp/fakebin/du-10g"; chmod +x "$tmp/fakebin/du-10g"
echo '{}' >"$tmp/dstate.json"
run "$tmp/dc1c" DW BOARD_WAIT_DISK_FREE_GB=30 BOARD_WAIT_DU="$tmp/fakebin/du-10g" BOARD_WAIT_LIMIT=5 "$W"
ok "disk: sizes are decimal GB (10000000 KB prints 10.2 GB)" 'grep -q "^DISK REMOVE: 10.2 GB:" "$tmp/dc1c"' "$(cat "$tmp/dc1c")"
# a disk-hold clear that fails is a warning on stderr
printf '#!/usr/bin/env bash\nif [ "${1:-}" = waiting ]; then exit 0; fi\nif [ "${1:-}" = disk-hold ]; then exit 1; fi\ncat %s/servers\n' "$tmp" >"$tmp/fakebin/card-test-server-badhold"; chmod +x "$tmp/fakebin/card-test-server-badhold"
echo '{}' >"$tmp/dstate.json"
run "$tmp/dc1d" DW BOARD_WAIT_CARD_TEST_SERVER="$tmp/fakebin/card-test-server-badhold" BOARD_WAIT_DISK_FREE_GB=9 BOARD_WAIT_LIMIT=2 "$W"
ok "disk: a failing disk-hold command is a warning on stderr, not a crash" 'grep -q "board-wait: .*card-test-server-badhold exited 1" "$tmp/dc1d"' "$(cat "$tmp/dc1d")"
run "$tmp/dc1e" DW BOARD_WAIT_CARD_TEST_SERVER="$tmp/fakebin/card-test-server-badhold" BOARD_WAIT_DISK_FREE_GB=11 BOARD_WAIT_LIMIT=2 "$W"
ok "disk: a failing disk-hold clear (critical to low) is a warning on stderr, not a crash" 'grep -q "board-wait: .*card-test-server-badhold exited 1" "$tmp/dc1e" && [ "$(dstate level)" = "\"low\"" ]' "$(cat "$tmp/dc1e")"
# START: while critical: a new card is not named; a returning card and a 🚨 card are
mkdir -p "$T/cards/Retn7777" "$T/cards/Newc8888" "$T/cards/Urg9999"
echo '[{"id":"b1","type":"commentCard","date":"'"$(iso $((now + 10)))"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"BEFORE: mobile card/x @ abc1234"}}]' >"$T/cards/Retn7777/actions"
echo '[]' >"$T/cards/Newc8888/actions"; echo '[]' >"$T/cards/Urg9999/actions"
cards '[{"id":"s5","name":"Returning","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"Retn7777"},
        {"id":"s6","name":"Brand new","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"Newc8888"},
        {"id":"s7","name":"🚨 Urgent new","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"Urg9999"}]'
run "$tmp/dc5" DW BOARD_WAIT_DISK_FREE_GB=4 BOARD_WAIT_LIMIT=2 "$W"
ok "disk: while critical START: names the returning card and the 🚨 card, not the new one" 'grep -q "^START: .*(Urg9999)" "$tmp/dc5" && grep -q "returning card (Retn7777)" "$tmp/dc5" && ! grep -q "Newc8888" "$tmp/dc5"' "$(cat "$tmp/dc5")"
run "$tmp/dc6" DW BOARD_WAIT_DISK_FREE_GB=15 BOARD_WAIT_LIMIT=2 "$W"
ok "disk: once free space is at the floor again the new card is in START: with no DISK OK:" 'grep -q "^START: .*Newc8888" "$tmp/dc6" && ! grep -q "DISK OK" "$tmp/dc6"' "$(cat "$tmp/dc6")"
dcards
# a disk that cannot be read: a note on stderr, no line, the state untouched
echo '{}' >"$tmp/dstate.json"   # an existing state without a holds key: the holds are complete (no HOLDS KNOWN: wake)
run "$tmp/dc7" DW BOARD_WAIT_DISK_PATH="$tmp/no/such/path" BOARD_WAIT_LIMIT=2 "$W"
ok "disk: an unreadable path is a note on stderr, no DISK line and no crash" '[ "$(rc "$tmp/dc7")" = 3 ] && grep -q "board-wait: disk read failed" "$tmp/dc7" && ! grep -q "^DISK" "$tmp/dc7"' "$(cat "$tmp/dc7")"
# a du that sleeps: sizes are ?, and the calculation ends inside its budget
printf '#!/usr/bin/env bash\nsleep 5\n' >"$tmp/fakebin/slow-du"; chmod +x "$tmp/fakebin/slow-du"
rm -f "$tmp/dstate.json"; sec=$SECONDS
run "$tmp/dc8" DW BOARD_WAIT_DISK_FREE_GB=30 BOARD_WAIT_DU="$tmp/fakebin/slow-du" BOARD_WAIT_DU_EACH=1 BOARD_WAIT_DU_BUDGET=2 BOARD_WAIT_LIMIT=20 "$W"
ok "disk: a du that is too slow gives ? GB and the whole calculation stays inside its budget" '[ "$(grep -c "^DISK REMOVE: ? GB:" "$tmp/dc8")" = 3 ] && [ $((SECONDS - sec)) -lt 10 ]' "$(cat "$tmp/dc8") ($((SECONDS - sec)) s)"
# git calls that take long: the loop stops before the limit and prints the candidates found so far
printf '#!/usr/bin/env bash\nsleep 0.7\nexec /usr/bin/git "$@"\n' >"$tmp/fakebin/git"; chmod +x "$tmp/fakebin/git"
echo '{}' >"$tmp/dstate.json"   # an existing state without a holds key: the holds are complete (no HOLDS KNOWN: wake)
run "$tmp/dc9" DW BOARD_WAIT_DISK_FREE_GB=30 BOARD_WAIT_LIMIT=4 BOARD_WAIT_SLOW_MARGIN=2 "$W"
rm -f "$tmp/fakebin/git"
ok "disk: with little time left before the limit the scan is unknown: no REMOVE line and no nothing-removable line" '[ "$(rc "$tmp/dc9")" = 3 ] && ! grep -q "^DISK" "$tmp/dc9"' "$(cat "$tmp/dc9")"
ok "disk: an unknown scan changes nothing in the state (no k, no free_sent)" '[ "$(dstate k)" = null ] && [ "$(dstate free_sent)" = null ]' "$(dstate k) $(dstate free_sent)"
# --worktrees: only the DISK REMOVE: lines, read only
rm -f "$tmp/dstate.json"
run "$tmp/dw1" DW "$W" --worktrees
ok "disk: board-wait.sh --worktrees prints only the DISK REMOVE: lines and writes no state" '[ "$(rc "$tmp/dw1")" = 0 ] && [ "$(grep -c "^DISK REMOVE:" "$tmp/dw1")" = 3 ] && [ "$(grep -v "^board-wait:" "$tmp/dw1" | grep -vc "^DISK REMOVE:")" = 0 ] && [ ! -e "$tmp/dstate.json" ]' "$(cat "$tmp/dw1")"
run "$tmp/dw2" "$W" --other
ok "disk: board-wait.sh refuses every other argument (exit 2)" '[ "$(rc "$tmp/dw2")" = 2 ] && grep -q "usage: board-wait.sh \[--worktrees|holds\]" "$tmp/dw2"' "$(cat "$tmp/dw2")"
# agent rows that cannot be read: no candidate
printf '#!/usr/bin/env bash\nexit 1\n' >"$tmp/fakebin/agent-state-bad"; chmod +x "$tmp/fakebin/agent-state-bad"
run "$tmp/dw3" DW BOARD_WAIT_AGENT_STATE="$tmp/fakebin/agent-state-bad" "$W" --worktrees
ok "disk: with agent rows that cannot be read nothing is a candidate (exit 1, no line)" '[ "$(rc "$tmp/dw3")" = 1 ] && ! grep -q "^DISK REMOVE" "$tmp/dw3"' "$(cat "$tmp/dw3")"
# the same on a slow check (not --worktrees): unreadable agent rows are unknown, not "nothing removable"
rm -f "$tmp/dstate.json"
run "$tmp/dw4" DW BOARD_WAIT_DISK_FREE_GB=30 BOARD_WAIT_AGENT_STATE="$tmp/fakebin/agent-state-bad" BOARD_WAIT_LIMIT=2 "$W"
ok "disk: unreadable agent rows on a slow check print no nothing-removable line and change nothing" '! grep -q "^DISK" "$tmp/dw4" && [ "$(dstate k)" = null ] && [ "$(dstate free_sent)" = null ]' "$(cat "$tmp/dw4")"
lists; cards '[]'; : >"$tmp/agents"

ok "default wait limit is 270 seconds (inside the 5-minute prompt cache)" 'grep -q "^LIMIT = float(env(\"BOARD_WAIT_LIMIT\", \"270\"))" "$(dirname "$W")/board-wait.py"'

# A card in WORKFLOW 🤖 with a live builder whose newest comment is BUILD PROGRESS: (its working note): only the Actively worked label
# (the live builder's), no other label and no wake line.
fresh_id=$(printf '%08x' $(date +%s))0000000000000000
cards '[{"id":"'"$fresh_id"'","name":"[AGENTS] Building (#99)","idList":"lw","idLabels":[],"idMembers":[],"shortLink":"WfBld1111"}]'
mkdir -p "$T/cards/WfBld1111"
echo '[{"date":"2026-10-18T11:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"BUILD PROGRESS: plan revision 1; done: step 1; next: step 2"}}]' >"$T/cards/WfBld1111/actions"
echo "running workflow-builder card=WfBld1111 id=w9 last=3s children=0 reqs=1 ctx=1 - /x" >"$tmp/agents"
mark workflow-work $((2 * 3600 + 60))
reset_writes
run "$tmp/o27b" env BOARD_WAIT_LIMIT=1 "$W"
ok "build progress: a card in WORKFLOW 🤖 whose newest comment is BUILD PROGRESS: of a live builder gets only the Actively worked label and no wake line" '! grep -q "WfBld1111" "$tmp/o27b" && ! grep -qv "$ACTIVE" <<<"$(gw idLabels)"' "rc=$(rc "$tmp/o27b") $(cat "$tmp/o27b") writes=$(writes)"
: >"$tmp/agents"

ok "build progress: BUILD PROGRESS: is in no phrase list of board-wait.py (it sets no label and wakes no turn)" '! grep -n "BUILD PROGRESS" "$(dirname "$W")/board-wait.py"'

# 11. Release holds, HOLD ENDED:, NOT URGENT: and the urgent deadline from URGENT ADDED: (card qtMtmwQe). Each case starts from a lost
# state file ($S2 removed), so the sweep after it reads the cards; comments live in $T/cards/<sl>/actions.
S2=$tmp/state2.json
hrun() { local out=$1; shift; run "$out" env BOARD_WAIT_STATE=$S2 BOARD_WAIT_LIMIT=2 "$@" "$W"; }
# deck <sl|name|list|labels|members>…: the board's cards (an id made now, or "old" for 10 days ago); labels and members comma separated ids
deck() {
  python3 -I - "$now" "$@" <<'PY' >"$T/boards/AbCd1234/cards"
import json, sys
now = int(sys.argv[1]); out = []
for spec in sys.argv[2:]:
    sl, name, lst, labels, members, *age = spec.split("|")
    out.append({"id": "%08x" % (now - int(age[0] if age else 600)) + "0" * 16, "name": name, "idList": lst,
                "idLabels": [x for x in labels.split(",") if x], "idMembers": [x for x in members.split(",") if x], "shortLink": sl})
print(json.dumps(out))
PY
}
# cm <sl> <text@secondsago>…: the card's comments (newest first by date), as a Claude comment
cm() {
  local sl=$1; shift; mkdir -p "$T/cards/$sl"
  python3 -I - "$now" "$CLAUDE" "$@" <<'PY' >"$T/cards/$sl/actions"
import json, sys, datetime
now = int(sys.argv[1]); out = []
for spec in sys.argv[3:]:
    text, _, ago = spec.rpartition("@")
    d = datetime.datetime.fromtimestamp(now - int(ago), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    out.append({"date": d, "idMemberCreator": sys.argv[2], "data": {"text": text}})
print(json.dumps(out))
PY
}
holds_out() { BOARD_WAIT_STATE=$S2 "$W" holds; }
: >"$tmp/reads.log"

# a lost state file, 8 cards in BUILDING and none holds the release: the sweep reads each card once, prints HOLDS KNOWN: 0 open once
rm -f "$S2"
specs=(); for i in 1 2 3 4 5 6 7 8; do specs+=("Hs00000$i|Plain card $i|lb||"); cm "Hs00000$i" "TEST PASSED: x@3000"; done
deck "${specs[@]}"
ok "holds: with no state file the holds are unknown" '[ "$(holds_out)" = "HOLDS UNKNOWN" ]' "$(holds_out)"
: >"$tmp/reads.log"
hrun "$tmp/h1"
ok "holds: the sweep after a lost state ends with HOLDS KNOWN: 0 open, once" '[ "$(grep -c "^HOLDS KNOWN: 0 open$" "$tmp/h1")" = 1 ]' "$(cat "$tmp/h1")"
ok "holds: the sweep reads no card twice" '[ -z "$(sort "$tmp/reads.log" | uniq -d)" ]' "$(sort "$tmp/reads.log" | uniq -c)"
ok "holds: after the sweep board-wait.sh holds prints NO HOLDS" '[ "$(holds_out)" = "NO HOLDS" ]' "$(holds_out)"
hrun "$tmp/h1b"
ok "holds: HOLDS KNOWN: is not printed again" '! grep -q "^HOLDS KNOWN" "$tmp/h1b"' "$(cat "$tmp/h1b")"

# a state file without a holds key is complete with no holds
python3 -I - "$S2" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); s.pop("holds", None); s.pop("holds_complete", None); json.dump(s, open(sys.argv[1], "w"))
PY
ok "holds: a state file without a holds key means NO HOLDS at once" '[ "$(holds_out)" = "NO HOLDS" ]' "$(holds_out)"

# a lost state file and a PROPOSED-less board: a QUESTIONS card with RELEASE BLOCKER: is an open hold
rm -f "$S2"
deck "Hd000001|Resolve the staging conflict|lq||"
cm Hd000001 "BLOCKED: which side wins?@600" "RELEASE BLOCKER: staging has a commit development lacks@900"
hrun "$tmp/h2"
ok "holds: the sweep records a RELEASE BLOCKER: card as an open hold" 'gho -qx "HOLD: \"Resolve the staging conflict\" \[Hd000001\] (QUESTIONS)" && ! gho -q "NO HOLDS"' "$(holds_out) / $(cat "$tmp/h2")"
ok "holds: HOLDS KNOWN: 1 open is printed" 'grep -qx "HOLDS KNOWN: 1 open" "$tmp/h2"' "$(cat "$tmp/h2")"

# a [AGENTS] fix card in PROPOSED with RELEASE BLOCKER: after a lost state: HOLDS UNKNOWN first, then HOLD:, never NO HOLDS
rm -f "$S2"
deck "Hp000001|[AGENTS] Fix the gate|lp||"
cm Hp000001 "RELEASE BLOCKER: the gate broke the release@900"
ok "holds: after a lost state a PROPOSED card is HOLDS UNKNOWN before the sweep" '[ "$(holds_out)" = "HOLDS UNKNOWN" ]' "$(holds_out)"
hrun "$tmp/h2p"
ok "holds: the sweep reads a PROPOSED card with RELEASE BLOCKER: and prints it as a HOLD:, never NO HOLDS" 'gho -qx "HOLD: \"\[AGENTS\] Fix the gate\" \[Hp000001\] (PROPOSED)" && ! gho -q "NO HOLDS"' "$(holds_out) / $(cat "$tmp/h2p")"
rm -f "$S2"
deck "Hd000001|Resolve the staging conflict|lq||"
hrun "$tmp/h2x"

# the hold ends when the card is in DONE: HOLD ENDED: once
deck "Hd000001|Resolve the staging conflict|lz||"
hrun "$tmp/h3"
ok "holds: a hold card in DONE ends the hold with HOLD ENDED:, once" '[ "$(grep -c "^HOLD ENDED: \"Resolve the staging conflict\" \[Hd000001\]" "$tmp/h3")" = 1 ] && [ "$(holds_out)" = "NO HOLDS" ]' "$(cat "$tmp/h3") / $(holds_out)"
# archived (gone from the board)
rm -f "$S2"; deck "Hd000001|Resolve the staging conflict|lq||"; hrun "$tmp/h4"
deck "Hd000009|Other card|lb||"; cm Hd000009 "TEST PASSED: x@100"
hrun "$tmp/h5"
ok "holds: an archived hold card ends the hold with HOLD ENDED: … archived" 'grep -q "^HOLD ENDED: \".*\" \[Hd000001\]: archived" "$tmp/h5"' "$(cat "$tmp/h5")"

# a manual-step card with RESOLVED: and no PR: HOLD ENDED: … RESOLVED: on every slow check until the card is in DONE
rm -f "$S2"
deck "Hr000001|Release blocked: log in to AWS|lt||"
cm Hr000001 "RESOLVED: the check passed@60" "WAITS FOR: you: log in. Check: aws sts get-caller-identity@500" "RELEASE BLOCKER: the release needs an AWS login@900"
hrun "$tmp/h6"
ok "holds: a RESOLVED: hold card with no PR prints HOLD ENDED: … RESOLVED:" 'grep -qx "HOLD ENDED: \"Release blocked: log in to AWS\" \[Hr000001\]: RESOLVED:" "$tmp/h6" && [ "$(holds_out)" = "NO HOLDS" ]' "$(cat "$tmp/h6") / $(holds_out)"
hrun "$tmp/h7"
ok "holds: that line is printed again on the next slow check (the card is not in DONE)" 'grep -qx "HOLD ENDED: \"Release blocked: log in to AWS\" \[Hr000001\]: RESOLVED:" "$tmp/h7"' "$(cat "$tmp/h7")"
deck "Hr000001|Release blocked: log in to AWS|lz||"
hrun "$tmp/h8"; hrun "$tmp/h9"
ok "holds: once the card is in DONE the line stops" '! grep -q "^HOLD ENDED" "$tmp/h9"' "$(cat "$tmp/h9")"

# a RESOLVED: card with a member: printed once, then never again
rm -f "$S2"
deck "Hr000002|Release blocked: log in to AWS|lt||$USER"
cm Hr000002 "RESOLVED: the check passed@60" "RELEASE BLOCKER: the release needs an AWS login@900"
hrun "$tmp/h10"; hrun "$tmp/h11"
ok "holds: a RESOLVED: card with a member prints HOLD ENDED: once and is not reprinted" 'grep -q "^HOLD ENDED: .*Hr000002" "$tmp/h10" && ! grep -q "^HOLD ENDED" "$tmp/h11"' "$(cat "$tmp/h10") / $(cat "$tmp/h11")"
# a RESOLVED: card with a PR in its description: no reprint
rm -f "$S2"
python3 -I - "$now" <<'PY' >"$T/boards/AbCd1234/cards"
import json, sys
print(json.dumps([{"id": "%08x" % (int(sys.argv[1]) - 600) + "0" * 16, "name": "Release blocked: x", "idList": "lt", "idLabels": [], "idMembers": [], "shortLink": "Hr000003", "desc": "**PR:** example-org/example-app#9"}]))
PY
cm Hr000003 "RESOLVED: the check passed@60" "RELEASE BLOCKER: x@900"
hrun "$tmp/h12"; hrun "$tmp/h13"
ok "holds: the sweep records a RESOLVED: card with a PR as neither a hold nor ended (the PR moves it)" '! grep -q "^HOLD ENDED" "$tmp/h12" "$tmp/h13" && [ "$(holds_out)" = "NO HOLDS" ]' "$(cat "$tmp/h12") / $(cat "$tmp/h13")"


# the stream: a RELEASE BLOCKER: comment makes a hold with no card read; the board watcher's RESOLVED: ends it
rm -f "$S2"; deck "Hs100001|Repair staging|lt||"; cm Hs100001 "TEST PASSED: x@3000"
hrun "$tmp/s0"
: >"$tmp/reads.log"
st_later=$(iso $((now + 30)))
actions '[{"id":"s1","type":"commentCard","date":"'"$st_later"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"RELEASE BLOCKER: staging is broken","card":{"name":"Repair staging","shortLink":"Hs100001"},"list":{"name":"TODO 📚"}}}]'
hrun "$tmp/s1"
ok "holds: a RELEASE BLOCKER: comment in the stream makes a hold" 'gho -qx "HOLD: \"Repair staging\" \[Hs100001\] (TODO)"' "$(holds_out) / $(cat "$tmp/s1")"
st_later=$(iso $((now + 60)))
actions '[{"id":"s2","type":"commentCard","date":"'"$st_later"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"RESOLVED: fixed","card":{"name":"Repair staging","shortLink":"Hs100001"},"list":{"name":"TODO 📚"}}}]'
hrun "$tmp/s2"
ok "holds: a RESOLVED: comment in the stream ends the hold" '[ "$(holds_out)" = "NO HOLDS" ] && grep -q "^HOLD ENDED: .*Hs100001" "$tmp/s2"' "$(holds_out) / $(cat "$tmp/s2")"
actions '[]'; cards '[]'

# NOT URGENT:
nu() { grep -c "^NOT URGENT: \"$1\"" "$2"; }
W1='WAITS FOR: https://trello.com/c/NuTgt001'
rm -f "$S2"
deck "NuTgt001|Fix the thing|lw||" "NuTgt002|Fix the other thing|lw||" "NuWt0001|Waits one|lb||" "NuWt0002|Waits two|lb||" "NuWt0003|Waits three|lb||"
cm NuTgt001 "TEST PASSED: x@3000"; cm NuTgt002 "TEST PASSED: x@3000"
cm NuWt0001 "$W1 (Fix the thing)@1000"
cm NuWt0002 "$W1 (Fix the thing)@1000"
cm NuWt0003 "WAITS FOR: https://trello.com/c/NuTgt002 (Fix the other thing)@1000"
hrun "$tmp/n1"
ok "not urgent: a plain card named by 2 waiting cards is NOT URGENT:, once" '[ "$(nu "Fix the thing" "$tmp/n1")" = 1 ]' "$(cat "$tmp/n1")"
ok "not urgent: a card named by 1 waiting card is silent" '[ "$(nu "Fix the other thing" "$tmp/n1")" = 0 ]' "$(cat "$tmp/n1")"
hrun "$tmp/n1b"
ok "not urgent: not printed again" '[ "$(nu "Fix the thing" "$tmp/n1b")" = 0 ]' "$(cat "$tmp/n1b")"
# one of the 2 waits cleared by UNBLOCKED:
rm -f "$S2"
cm NuWt0002 "UNBLOCKED: done@100" "$W1 (Fix the thing)@1000"
hrun "$tmp/n2"
ok "not urgent: 2 waits with one cleared by UNBLOCKED: is silent" '[ "$(nu "Fix the thing" "$tmp/n2")" = 0 ]' "$(cat "$tmp/n2")"
# a RELEASE BLOCKER: card fires; with WAITS FOR: you: it is silent
rm -f "$S2"
deck "NuRb0001|Repair staging|lt||" "NuRb0002|Release blocked: log in|lt||"
cm NuRb0001 "RELEASE BLOCKER: staging is broken@900"
cm NuRb0002 "WAITS FOR: you: log in. Check: true@500" "RELEASE BLOCKER: needs a login@900"
hrun "$tmp/n3"
ok "not urgent: a RELEASE BLOCKER: card without 🚨 is NOT URGENT:" '[ "$(nu "Repair staging" "$tmp/n3")" = 1 ]' "$(cat "$tmp/n3")"
ok "not urgent: a RELEASE BLOCKER: card that waits for the user is silent" '[ "$(nu "Release blocked: log in" "$tmp/n3")" = 0 ]' "$(cat "$tmp/n3")"
# silent kinds: 🚨, status, QUESTIONS, [AGENTS], member, URGENT ADDED:
rm -f "$S2"
deck "NuSi0001|🚨 Already urgent|lt||" "NuSi0002|⛔ BLOCKED: held stage|lt||" "NuSi0003|A question|lq||" "NuSi0004|[AGENTS] Workflow fix|lw||" \
  "NuSi0005|Person owned|lt||$USER" "NuSi0006|Added before|lt||"
for sl in NuSi0001 NuSi0002 NuSi0003 NuSi0004 NuSi0005; do cm "$sl" "RELEASE BLOCKER: x@900"; done
cm NuSi0006 "URGENT ADDED: it held the release@100" "RELEASE BLOCKER: x@900"
hrun "$tmp/n4"
ok "not urgent: 🚨, status, QUESTIONS, [AGENTS], member and URGENT ADDED: cards are silent" '! grep -q "^NOT URGENT" "$tmp/n4"' "$(cat "$tmp/n4")"

# the release status card's RELEASE FIX: names a card: NOT URGENT:; a RELEASE FIX: older than the newest PROMOTING: does not count
rm -f "$S2"
deck "NuFx0001|Fix the failed release|lt||" "NuFx0002|Fix from an earlier release|lt||" "NuRel001|🚀 RELEASE: v9|lx||"
cm NuFx0001 "TEST PASSED: x@3000"; cm NuFx0002 "TEST PASSED: x@3000"
cm NuRel001 "RELEASE FIX: https://trello.com/c/NuFx0001 (Fix the failed release)@100" "PROMOTING: pair@500" "RELEASE FIX: https://trello.com/c/NuFx0002 (Fix from an earlier release)@900"
hrun "$tmp/n5"
ok "not urgent: a card named by the release status card's newest RELEASE FIX: is NOT URGENT:" '[ "$(nu "Fix the failed release" "$tmp/n5")" = 1 ] && grep -q "RELEASE FIX:" "$tmp/n5"' "$(cat "$tmp/n5")"
ok "not urgent: a RELEASE FIX: from before the newest PROMOTING: is silent" '[ "$(nu "Fix from an earlier release" "$tmp/n5")" = 0 ]' "$(cat "$tmp/n5")"

# a card that lost its 🚨 stays silent: the user's removal sticks
rm -f "$S2"
deck "NuDr0001|🚨 Repair staging|lt||"
cm NuDr0001 "RELEASE BLOCKER: staging is broken@900"
hrun "$tmp/n6"
deck "NuDr0001|Repair staging|lt||"
hrun "$tmp/n7"; hrun "$tmp/n8"
ok "not urgent: a hold card whose 🚨 was removed gets no NOT URGENT:, now or later" '! grep -q "^NOT URGENT" "$tmp/n6" "$tmp/n7" "$tmp/n8"' "$(cat "$tmp/n6") / $(cat "$tmp/n7") / $(cat "$tmp/n8")"
cards '[]'

# the slow check's card reads are shared: the sweep, the Blocked bootstrap and the WAITS FOR: texts read at most 6 different cards in all
rm -f "$S2"
specs=(); for i in 1 2 3 4 5 6; do specs+=("Bd00000$i|Waiting card $i|lb||"); cm "Bd00000$i" "WAITS FOR: https://trello.com/c/Bd000099 (a card)@1000"; done
for i in 7 8 9 10 11 12; do specs+=("Bd00000$(printf '%x' $i)|Plain card $i|lb||"); cm "Bd00000$(printf '%x' $i)" "TEST PASSED: x@3000"; done
deck "${specs[@]}"
: >"$tmp/reads.log"
run "$tmp/b1" env BOARD_WAIT_STATE=$S2 BOARD_WAIT_LIMIT=1 BOARD_WAIT_POLL=100 "$W"
ok "reads: one slow check reads at most 6 different cards for the sweep, the bootstrap and the WAITS FOR: texts together" '[ "$(sort -u "$tmp/reads.log" | wc -l)" -le 6 ] && [ "$(sort -u "$tmp/reads.log" | wc -l)" -ge 1 ] && ! grep -q "^HOLDS KNOWN" "$tmp/b1"' "$(sort "$tmp/reads.log" | uniq -c) / $(cat "$tmp/b1")"

# the urgent deadline counts from URGENT ADDED:
rm -f "$S2"
old_id=$(printf '%08x' $((now - 3 * 86400)))0000000000000000
cards '[{"id":"'"$old_id"'","name":"🚨 Repair staging","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"UaFix001"}]'
cm UaFix001 "URGENT ADDED: it held the release@3600"
hrun "$tmp/u1"
ok "urgent deadline: a 3 day old card whose URGENT ADDED: is 1 hour old has no DEADLINE:" '! grep -q "^DEADLINE: urgent fix deadline passed" "$tmp/u1"' "$(cat "$tmp/u1")"
rm -f "$S2"
cm UaFix001 "URGENT ADDED: it held the release@$((25 * 3600))"
hrun "$tmp/u2"
ok "urgent deadline: URGENT ADDED: 25 hours ago gives the DEADLINE:" 'grep -qx "DEADLINE: urgent fix deadline passed: \"🚨 Repair staging\" (UaFix001)" "$tmp/u2"' "$(cat "$tmp/u2")"
cards '[]'

# The compaction windows and CEILING_TYPES are checked in test-board-content.sh.

# 11. Wake lines that start an agent come back while the work holds and no matching agent is alive (card NzbZtBDt).
# Its own state file; BOARD_WAIT_REARM is the 10-minute default (600 s); the marks are aged with markf.
W4() { env BOARD_WAIT_STATE=$tmp/state-rearm.json "$@"; }
markf() { python3 -I - "$tmp/state-rearm.json" "$1" "$2" <<'PY'
import json, sys, time
s = json.load(open(sys.argv[1])); s["marks"][sys.argv[2]] = time.time() - float(sys.argv[3])
json.dump(s, open(sys.argv[1], "w"))
PY
}
stset() { python3 -I - "$tmp/state-rearm.json" "$1" <<'PY'
import json, sys, time
s = json.load(open(sys.argv[1])); exec(sys.argv[2], {"s": s, "time": time})
json.dump(s, open(sys.argv[1], "w"))
PY
}
OLD=$((31 * 60))
lists_testing
: >"$tmp/agents"; : >"$tmp/waiting"; rm -f "$tmp/state-rearm.json"
mkdir -p "$T/cards/ReAr1111" && echo '[]' >"$T/cards/ReAr1111/actions"
cards '[{"id":"r1","name":"[AGENTS] Re-arm (#70)","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"ReAr1111",
         "desc":"**PR:** example-org/example-app#70, https://github.com/example-org/example-app/pull/70 (x)"}]'
echo '{"headRefOid":"hhhh1111","mergeable":"MERGEABLE","reviews":[]}' >"$tmp/gh/example-org_example-app-70.json"
VK="verify:ReAr1111:example-org/example-app#70:hhhh1111"
VL='VERIFY: "[AGENTS] Re-arm (#70)" [ReAr1111] example-org/example-app#70 @ hhhh1111'
run "$tmp/ra1" W4 BOARD_WAIT_LIMIT=2 "$W"
ok "re-arm: VERIFY: is printed the first time" 'grep -qxF "$VL" "$tmp/ra1"' "$(cat "$tmp/ra1")"
markf "$VK" 300
run "$tmp/ra2" W4 BOARD_WAIT_LIMIT=1 "$W"
ok "re-arm: a VERIFY: mark 5 minutes old with no verifier prints nothing" '! grep -qF "VERIFY:" "$tmp/ra2"' "$(cat "$tmp/ra2")"
markf "$VK" $OLD
echo "running workflow-verifier card=ReAr1111 id=v1 last=5s children=0 reqs=1 ctx=1 - /x" >"$tmp/agents"
run "$tmp/ra3" W4 BOARD_WAIT_LIMIT=1 "$W"
ok "re-arm: a mark 31 minutes old with a verifier alive on the card prints nothing" '! grep -qF "VERIFY:" "$tmp/ra3"' "$(cat "$tmp/ra3")"
: >"$tmp/agents"
run "$tmp/ra4" W4 BOARD_WAIT_LIMIT=2 "$W"
ok "re-arm: a mark 31 minutes old with no verifier prints VERIFY: again" 'grep -qxF "$VL" "$tmp/ra4"' "$(cat "$tmp/ra4")"
run "$tmp/ra5" W4 BOARD_WAIT_LIMIT=1 "$W"
ok "re-arm: the mark is renewed (not printed on the next pass)" '! grep -qF "VERIFY:" "$tmp/ra5"' "$(cat "$tmp/ra5")"
markf "$VK" $OLD
cards '[{"id":"r1","name":"[AGENTS] Re-arm (#70)","idList":"lm","idLabels":["'"$ORANGE"'"],"idMembers":[],"shortLink":"ReAr1111",
         "desc":"**PR:** example-org/example-app#70, https://github.com/example-org/example-app/pull/70 (x)"}]'
run "$tmp/ra6" W4 BOARD_WAIT_LIMIT=1 "$W"
ok "re-arm: an orange MERGING card gets no VERIFY: and no STUCK: for a verifier" '! grep -qF "VERIFY:" "$tmp/ra6" && ! grep -q "^STUCK" "$tmp/ra6"' "$(cat "$tmp/ra6")"

# The WORKFLOW 🤖 site.
cards '[{"id":"r2","name":"[AGENTS] Re-arm wf (#71)","idList":"lw","idLabels":[],"idMembers":[],"shortLink":"ReAr2222",
         "desc":"**PR:** example-org/example-app#71, https://github.com/example-org/example-app/pull/71 (x)"}]'
echo '{"headRefOid":"hhhh2222","mergeable":"MERGEABLE","reviews":[]}' >"$tmp/gh/example-org_example-app-71.json"
mkdir -p "$T/cards/ReAr2222"
echo '[{"date":"2026-10-15T11:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"AWAITING VERIFIED: example-org/example-app#71 @ hhhh2222"}}]' >"$T/cards/ReAr2222/actions"
VK2="verify:ReAr2222:example-org/example-app#71:hhhh2222"
run "$tmp/ra7" W4 BOARD_WAIT_LIMIT=2 "$W"
ok "re-arm: the WORKFLOW VERIFY: is printed the first time" 'grep -q "^VERIFY: .*ReAr2222.* @ hhhh2222" "$tmp/ra7"' "$(cat "$tmp/ra7")"
markf "$VK2" $OLD
run "$tmp/ra8" W4 BOARD_WAIT_LIMIT=2 "$W"
ok "re-arm: the WORKFLOW VERIFY: comes back after 31 minutes with no verifier" 'grep -q "^VERIFY: .*ReAr2222.* @ hhhh2222" "$tmp/ra8"' "$(cat "$tmp/ra8")"

# AGENT: dead comes back while the work holds.
cards '[{"id":"r3","name":"Dead manager","idList":"lb","idLabels":[],"idMembers":[],"shortLink":"ReAr3333"}]'
echo "dead card-manager card=ReAr3333 id=cmx last=1200s children=0 interrupted /x" >"$tmp/agents"
run "$tmp/rd1" W4 BOARD_WAIT_LIMIT=2 "$W"
ok "re-arm: AGENT: dead is printed the first time" 'grep -qx "AGENT: dead card-manager card=ReAr3333 id=cmx" "$tmp/rd1"' "$(cat "$tmp/rd1")"
markf dead:cmx $OLD
run "$tmp/rd2" W4 BOARD_WAIT_LIMIT=2 "$W"
ok "re-arm: AGENT: dead comes back after 31 minutes while the card is in BUILDING with no live agent" 'grep -qx "AGENT: dead card-manager card=ReAr3333 id=cmx" "$tmp/rd2"' "$(cat "$tmp/rd2")"
markf dead:cmx $OLD
echo "dead card-manager card=ReAr3333 id=cmx last=1200s children=0 interrupted /x" >"$tmp/agents"
echo "running card-manager card=ReAr3333 id=cmy last=5s children=0 reqs=1 ctx=1 - /x" >>"$tmp/agents"
run "$tmp/rd3" W4 BOARD_WAIT_LIMIT=1 "$W"
ok "re-arm: not while an agent of that type is alive on the card" '! grep -q "AGENT: dead" "$tmp/rd3"' "$(cat "$tmp/rd3")"
cards '[{"id":"r3","name":"Dead manager","idList":"lb","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"ReAr3333"}]'
echo "dead card-manager card=ReAr3333 id=cmx last=1200s children=0 interrupted /x" >"$tmp/agents"
run "$tmp/rd4" W4 BOARD_WAIT_LIMIT=1 "$W"
ok "re-arm: not for a Blocked card" '! grep -q "AGENT: dead" "$tmp/rd4"' "$(cat "$tmp/rd4")"
# a workflow-verifier that died after its verdict: no work left
cards '[{"id":"r2","name":"[AGENTS] Re-arm wf (#71)","idList":"lw","idLabels":[],"idMembers":[],"shortLink":"ReAr2222",
         "desc":"**PR:** example-org/example-app#71, https://github.com/example-org/example-app/pull/71 (x)"}]'
echo '[{"date":"2026-10-15T12:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"VERIFIED: example-org/example-app#71 @ hhhh2222"}},{"date":"2026-10-15T11:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"AWAITING VERIFIED: example-org/example-app#71 @ hhhh2222"}}]' >"$T/cards/ReAr2222/actions"
echo "dead workflow-verifier card=ReAr2222 id=vdd last=1200s children=0 interrupted /x" >"$tmp/agents"
run "$tmp/rd5" W4 BOARD_WAIT_LIMIT=2 "$W"
markf dead:vdd $OLD
run "$tmp/rd6" W4 BOARD_WAIT_LIMIT=1 "$W"
ok "re-arm: a verifier that died after posting its verdict is not named again" '! grep -q "AGENT: dead workflow-verifier" "$tmp/rd6"' "$(cat "$tmp/rd6")"
# the merger is board-wide: its card is only its newest Trello call
cards '[{"id":"r4","name":"[AGENTS] Ready one (#72)","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"ReAr4444"}]'
stset 's["ready"] = {"ReAr4444": True}'
echo "dead merger card=ReAr9999 id=mg1 last=1200s children=0 interrupted /x" >"$tmp/agents"
run "$tmp/rm1" W4 BOARD_WAIT_LIMIT=2 "$W"
stset 's["ready"] = {"ReAr4444": True}'
markf dead:mg1 $OLD
echo "running merger card=ReAr4444 id=mg2 last=5s children=0 reqs=1 ctx=1 - /x" >>"$tmp/agents"
run "$tmp/rm2" W4 BOARD_WAIT_LIMIT=1 "$W"
ok "re-arm: a merger dead on one card is not named while another merger is alive on a different card" '! grep -q "AGENT: dead merger" "$tmp/rm2"' "$(cat "$tmp/rm2")"
echo "dead merger card=- id=mg1 last=1200s children=0 interrupted /x" >"$tmp/agents"
stset 's["ready"] = {"ReAr4444": True}'
markf dead:mg1 $OLD
run "$tmp/rm3" W4 BOARD_WAIT_LIMIT=2 "$W"
ok "re-arm: a dead merger whose card is - comes back while a ready card waits and no merger is alive" 'grep -qx "AGENT: dead merger card=- id=mg1" "$tmp/rm3"' "$(cat "$tmp/rm3")"
: >"$tmp/agents"

# VERIFY PLAN: comes back too.
cards '[{"id":"r5","name":"[AGENTS] Plan re-arm","idList":"lw","idLabels":[],"idMembers":[],"shortLink":"ReAr5555"}]'
mkdir -p "$T/cards/ReAr5555"
echo '[{"date":"'"$(ago 40)"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"PLAN: revision 1"}}]' >"$T/cards/ReAr5555/actions"
run "$tmp/rp1" W4 BOARD_WAIT_LIMIT=2 "$W"
ok "re-arm: VERIFY PLAN: is printed once an old PLAN: has no verifier" 'grep -q "^VERIFY PLAN: .*ReAr5555.* plan revision 1" "$tmp/rp1"' "$(cat "$tmp/rp1")"
python3 -I - "$tmp/state-rearm.json" "$OLD" <<'PY'
import json, sys, time
s = json.load(open(sys.argv[1]))
for k in list(s["marks"]):
    if k.startswith("verifyplan:ReAr5555"): s["marks"][k] = time.time() - float(sys.argv[2])
json.dump(s, open(sys.argv[1], "w"))
PY
run "$tmp/rp2" W4 BOARD_WAIT_LIMIT=2 "$W"
ok "re-arm: VERIFY PLAN: comes back after 31 minutes with no verifier" 'grep -q "^VERIFY PLAN: .*ReAr5555.* plan revision 1" "$tmp/rp2"' "$(cat "$tmp/rp2")"

# The STUCK check for an [AGENTS] card in MERGING waiting for VERIFIED: with no verifier alive.
W5() { env BOARD_WAIT_STATE=$tmp/state-nov.json BOARD_WAIT_STUCK_GRACE=0 BOARD_WAIT_STUCK_REPEAT=0 "$@"; }
rm -f "$tmp/state-nov.json"
mkdir -p "$T/cards/NoVe1111" && echo '[]' >"$T/cards/NoVe1111/actions"
nv_cards() { cards '[{"id":"n1","name":"[AGENTS] No verifier (#73)","idList":"lm","idLabels":['"$1"'],"idMembers":[],"shortLink":"NoVe1111",
         "desc":"**PR:** example-org/example-app#73, https://github.com/example-org/example-app/pull/73 (x)"}]'; }
nv_cards ''
echo '{"headRefOid":"nnnn1111","mergeable":"MERGEABLE","reviews":[]}' >"$tmp/gh/example-org_example-app-73.json"
: >"$tmp/agents"
run "$tmp/nv1" W5 BOARD_WAIT_LIMIT=2 "$W"
ok "stuck: an unverified [AGENTS] card in MERGING with no verifier alive" 'grep -qx "STUCK: \"\[AGENTS\] No verifier (#73)\" \[NoVe1111\] (MERGING): \[AGENTS\] PR example-org/example-app#73 @ nnnn1111 has no VERIFIED: and no workflow verifier is alive; start the workflow verifier" "$tmp/nv1"' "$(cat "$tmp/nv1")"
echo "running workflow-verifier card=NoVe1111 id=v9 last=5s children=0 reqs=1 ctx=1 - /x" >"$tmp/agents"
run "$tmp/nv2" W5 BOARD_WAIT_LIMIT=1 "$W"
ok "stuck: not when a workflow verifier is alive on the card" '! grep -q "^STUCK" "$tmp/nv2"' "$(cat "$tmp/nv2")"
: >"$tmp/agents"
nv_cards '"'"$BLOCKED"'"'
run "$tmp/nv3" W5 BOARD_WAIT_LIMIT=1 "$W"
ok "stuck: not for a Blocked card" '! grep -q "^STUCK" "$tmp/nv3"' "$(cat "$tmp/nv3")"
nv_cards '"'"$ORANGE"'"'
run "$tmp/nv4" W5 BOARD_WAIT_LIMIT=1 "$W"
ok "stuck: not for an orange card" '! grep -q "^STUCK" "$tmp/nv4"' "$(cat "$tmp/nv4")"
nv_cards ''
echo '[{"date":"2026-10-15T12:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"VERIFIED: example-org/example-app#73 @ nnnn1111"}}]' >"$T/cards/NoVe1111/actions"
run "$tmp/nv5" W5 BOARD_WAIT_LIMIT=1 "$W"
ok "stuck: not for a card already verified at its head" '! grep -q "no VERIFIED:" "$tmp/nv5"' "$(cat "$tmp/nv5")"
echo '[]' >"$T/cards/NoVe1111/actions"
echo '{"headRefOid":"nnnn1111","mergeable":"CONFLICTING","reviews":[]}' >"$tmp/gh/example-org_example-app-73.json"
run "$tmp/nv6" W5 BOARD_WAIT_LIMIT=2 "$W"
ok "stuck: a conflicting unverified head with no merger names the merger" 'grep -q "^STUCK: .*NoVe1111.* conflicts with main and no merger is alive; start the merger" "$tmp/nv6"' "$(cat "$tmp/nv6")"
echo "running merger card=- id=m3 last=5s children=0 reqs=1 ctx=1 - /x" >"$tmp/agents"
run "$tmp/nv7" W5 BOARD_WAIT_LIMIT=1 "$W"
ok "stuck: a conflicting unverified head with a merger alive prints nothing" '! grep -q "^STUCK" "$tmp/nv7"' "$(cat "$tmp/nv7")"
: >"$tmp/agents"

# Builders: s["workflowwork"] decides the AGENT: dead re-arm from stored state.
rm -f "$tmp/state-rearm.json"
cards '[{"id":"r6","name":"[AGENTS] Builder card","idList":"lw","idLabels":[],"idMembers":[],"shortLink":"ReAr6666"}]'
mkdir -p "$T/cards/ReAr6666" && echo '[]' >"$T/cards/ReAr6666/actions"
echo "dead workflow-builder card=ReAr6666 id=wbd last=1200s children=0 interrupted /x" >"$tmp/agents"
run "$tmp/rw1" W4 BOARD_WAIT_LIMIT=2 "$W"
markf dead:wbd $OLD
run "$tmp/rw2" W4 BOARD_WAIT_LIMIT=2 "$W"
ok "re-arm: a dead workflow builder on a card with workflow work waiting is named again" 'grep -q "AGENT: dead workflow-builder card=ReAr6666 id=wbd" "$tmp/rw2"' "$(cat "$tmp/rw2")"
cards '[{"id":"r6","name":"[AGENTS] Builder card","idList":"lw","idLabels":[],"idMembers":["u1"],"shortLink":"ReAr6666"}]'
markf dead:wbd $OLD
run "$tmp/rw3" W4 BOARD_WAIT_LIMIT=1 "$W"
ok "re-arm: not for a person-owned card" '! grep -q "AGENT: dead" "$tmp/rw3"' "$(cat "$tmp/rw3")"
: >"$tmp/agents"

# RESUME: for agents that died on a usage limit.
rm -f "$tmp/state-rearm.json"
cards '[{"id":"r7","name":"[AGENTS] Limit card","idList":"lw","idLabels":[],"idMembers":[],"shortLink":"ReAr7777"}]'
mkdir -p "$T/cards/ReAr7777" && echo '[]' >"$T/cards/ReAr7777/actions"
W6() { env BOARD_WAIT_STATE=$tmp/state-rearm.json BOARD_WAIT_STUCK_GRACE=0 BOARD_WAIT_STUCK_REPEAT=0 "$@"; }
echo "dead workflow-builder card=ReAr7777 id=wbl last=60s children=0 limit_reset=Dec_31_at_11pm_(America/Chicago) /x" >"$tmp/agents"
run "$tmp/rr1" W6 BOARD_WAIT_LIMIT=2 "$W"
ok "resume: an agent that died on a usage limit gives no AGENT: dead and no RESUME: before the reset" '! grep -q "AGENT: dead\|^RESUME" "$tmp/rr1"' "$(cat "$tmp/rr1")"
ok "resume: the limit is saved with its reset time" 'python3 -I -c "import json,time; l=json.load(open(\"$tmp/state-rearm.json\"))[\"limits\"][\"wbl\"]; assert l[\"type\"]==\"workflow-builder\" and l[\"card\"]==\"ReAr7777\" and l[\"reset\"]>time.time()"' "$(python3 -I -c "import json;print(json.load(open('$tmp/state-rearm.json')).get('limits'))")"
stset 's["limits"]["wbl"]["reset"] = time.time() - 10'
: >"$tmp/agents"
run "$tmp/rr2" W6 BOARD_WAIT_LIMIT=2 "$W"
ok "resume: after the reset, with the row gone from agent-state.sh, RESUME: names the agent" 'grep -qx "RESUME: usage limit over; restart: workflow-builder card=ReAr7777 id=wbl" "$tmp/rr2"' "$(cat "$tmp/rr2")"
echo "running workflow-builder card=ReAr7777 id=wb2 last=5s children=0 reqs=1 ctx=1 - /x" >"$tmp/agents"
run "$tmp/rr3" W6 BOARD_WAIT_LIMIT=1 "$W"
ok "resume: a replacement alive on the card drops the entry and the line" '! grep -q "^RESUME" "$tmp/rr3" && [ "$(python3 -I -c "import json;print(len(json.load(open(\"$tmp/state-rearm.json\"))[\"limits\"]))")" = 0 ]' "$(cat "$tmp/rr3")"
: >"$tmp/agents"
cat >"$tmp/reset_epoch_check.py" <<'PY'
import importlib.util, sys, datetime, zoneinfo
spec = importlib.util.spec_from_file_location("bw", sys.argv[1]); bw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bw)
z = zoneinfo.ZoneInfo("America/Chicago")
death = datetime.datetime(2026, 10, 18, 22, 0, tzinfo=z).timestamp()
at = lambda r: datetime.datetime.fromtimestamp(bw.reset_epoch(r, death), z)
assert at("Oct_19_at_7am_(America/Chicago)") == datetime.datetime(2026, 10, 19, 7, 0, tzinfo=z)
assert at("7am_(America/Chicago)") == datetime.datetime(2026, 10, 19, 7, 0, tzinfo=z)
assert at("11pm_(America/Chicago)") == datetime.datetime(2026, 10, 18, 23, 0, tzinfo=z)
assert at("Oct_18_at_9:30pm_(America/Chicago)") == datetime.datetime(2027, 10, 18, 21, 30, tzinfo=z)
assert bw.reset_epoch("soon", death) == death + 3600
PY
ok "resume: reset_epoch reads dated, undated, passed and unreadable forms" 'python3 -I "$tmp/reset_epoch_check.py" "$bin/board-wait.py"' "$(python3 -I "$tmp/reset_epoch_check.py" "$bin/board-wait.py" 2>&1)"

# A usage limit that has not reset holds the wake lines and the STUCK lines that start that agent type (card NzbZtBDt).
W8() { env BOARD_WAIT_STATE=$tmp/state-lim.json BOARD_WAIT_STUCK_GRACE=0 BOARD_WAIT_STUCK_REPEAT=0 "$@"; }
limset() { python3 -I - "$tmp/state-lim.json" "$1" "$2" "$3" "$4" <<'PY'
import json, os, sys, time
s = json.load(open(sys.argv[1])) if os.path.exists(sys.argv[1]) else {}
s.setdefault("limits", {})[sys.argv[2]] = {"type": sys.argv[3], "card": sys.argv[4], "seen": time.time(), "reset": time.time() + float(sys.argv[5] if len(sys.argv) > 5 else 0)}
json.dump(s, open(sys.argv[1], "w"))
PY
}
limit_card() { cards '[{"id":"l1","name":"[AGENTS] Limit hold (#74)","idList":"lm","idLabels":['"$1"'],"idMembers":[],"shortLink":"LiM11111",
         "desc":"**PR:** example-org/example-app#74, https://github.com/example-org/example-app/pull/74 (x)"}]'; }
rm -f "$tmp/state-lim.json"; : >"$tmp/agents"
mkdir -p "$T/cards/LiM11111" && echo '[]' >"$T/cards/LiM11111/actions"
echo '{"headRefOid":"llll1111","mergeable":"MERGEABLE","reviews":[]}' >"$tmp/gh/example-org_example-app-74.json"
limit_card ''
run "$tmp/li0" W8 BOARD_WAIT_LIMIT=1 "$W"
ok "limit: a first VERIFY: and the noverifier STUCK print with no limit entry" 'grep -q "^VERIFY: .*LiM11111" "$tmp/li0" && grep -q "^STUCK: .*LiM11111.*no workflow verifier is alive" "$tmp/li0"' "$(cat "$tmp/li0")"
python3 -I - "$tmp/state-lim.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); s["marks"] = {k: v for k, v in s["marks"].items() if not k.startswith("verify:")}; s["stuck"] = {}
json.dump(s, open(sys.argv[1], "w"))
PY
limset wvl workflow-verifier LiM11111 7200
run "$tmp/li1" W8 BOARD_WAIT_LIMIT=1 "$W"
ok "limit: with a workflow-verifier limit not reset: no first VERIFY:, no STUCK to start a verifier, and no mark" '! grep -q "VERIFY:\|^STUCK" "$tmp/li1" && ! python3 -I -c "import json,sys; sys.exit(0 if any(k.startswith(\"verify:LiM11111\") for k in json.load(open(\"$tmp/state-lim.json\"))[\"marks\"]) else 1)"' "$(cat "$tmp/li1")"
python3 -I - "$tmp/state-lim.json" <<'PY'
import json, sys, time
s = json.load(open(sys.argv[1])); s["marks"]["verify:LiM11111:example-org/example-app#74:llll1111"] = time.time() - 4000
json.dump(s, open(sys.argv[1], "w"))
PY
run "$tmp/li2" W8 BOARD_WAIT_LIMIT=1 "$W"
ok "limit: an old VERIFY: mark is not re-armed while the limit holds" '! grep -q "VERIFY:" "$tmp/li2"' "$(cat "$tmp/li2")"
limset mgl merger LiM11111 7200
python3 -I - "$tmp/state-lim.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); del s["limits"]["wvl"]
json.dump(s, open(sys.argv[1], "w"))
PY
run "$tmp/li3" W8 BOARD_WAIT_LIMIT=1 "$W"
ok "limit: a limit on another agent type (merger) does not hold the verifier lines" 'grep -q "^VERIFY: .*LiM11111" "$tmp/li3" && grep -q "^STUCK: .*LiM11111.*no workflow verifier is alive" "$tmp/li3"' "$(cat "$tmp/li3")"
echo '{"headRefOid":"llll1111","mergeable":"CONFLICTING","reviews":[]}' >"$tmp/gh/example-org_example-app-74.json"
run "$tmp/li4" W8 BOARD_WAIT_LIMIT=1 "$W"
ok "limit: with a merger limit not reset, the conflicting STUCK (start the merger) is held" '! grep -q "^STUCK: .*start the merger" "$tmp/li4"' "$(cat "$tmp/li4")"
python3 -I - "$tmp/state-lim.json" <<'PY'
import json, sys, time
s = json.load(open(sys.argv[1])); s["limits"]["mgl"]["reset"] = time.time() - 5
json.dump(s, open(sys.argv[1], "w"))
PY
run "$tmp/li5" W8 BOARD_WAIT_LIMIT=1 "$W"
ok "limit: once the merger limit has reset, the conflicting STUCK prints again" 'grep -q "^STUCK: .*LiM11111.*start the merger" "$tmp/li5"' "$(cat "$tmp/li5")"
echo '{"headRefOid":"llll1111","mergeable":"MERGEABLE","reviews":[]}' >"$tmp/gh/example-org_example-app-74.json"
# no work before the reset: the entry stays; after the reset it goes
rm -f "$tmp/state-lim.json"; limset wvl workflow-verifier LiM11111 7200
limit_card '"'"$ORANGE"'"'
run "$tmp/li6" W8 BOARD_WAIT_LIMIT=1 "$W"
ok "limit: an entry whose card has no work (orange) is kept until its reset" 'python3 -I -c "import json,sys; sys.exit(0 if \"wvl\" in json.load(open(\"$tmp/state-lim.json\"))[\"limits\"] else 1)"' "$(cat "$tmp/li6")"
ok "limit: an orange card with a new head gets no first VERIFY:" '! grep -q "VERIFY:" "$tmp/li6"' "$(cat "$tmp/li6")"
rm -f "$tmp/state-lim.json"
limit_card '"'"$ORANGE"'"'
run "$tmp/li7" W8 BOARD_WAIT_LIMIT=1 "$W"
ok "orange: a new head on an orange MERGING card gets no VERIFY: and writes no mark" '! grep -q "VERIFY:" "$tmp/li7"' "$(cat "$tmp/li7")"
limit_card ''
run "$tmp/li8" W8 BOARD_WAIT_LIMIT=1 "$W"
ok "orange: with the label off the VERIFY: for that head prints" 'grep -q "^VERIFY: .*LiM11111" "$tmp/li8"' "$(cat "$tmp/li8")"
# after the reset passes the entry is dropped when its work is gone
rm -f "$tmp/state-lim.json"; limset wvl workflow-verifier LiM11111 -5
limit_card '"'"$ORANGE"'"'
run "$tmp/li9" W8 BOARD_WAIT_LIMIT=1 "$W"
ok "limit: after the reset an entry with no work is dropped" '! python3 -I -c "import json,sys; sys.exit(0 if \"wvl\" in json.load(open(\"$tmp/state-lim.json\"))[\"limits\"] else 1)"' "$(cat "$tmp/li9")"

# The WORKFLOW 🤖 VERIFY:, VERIFY PLAN: and the AGENT: dead re-arm.
rm -f "$tmp/state-lim.json"
cards '[{"id":"l2","name":"[AGENTS] Limit wf (#75)","idList":"lw","idLabels":[],"idMembers":[],"shortLink":"LiM22222",
         "desc":"**PR:** example-org/example-app#75, https://github.com/example-org/example-app/pull/75 (x)"},
        {"id":"l3","name":"[AGENTS] Limit plan","idList":"lw","idLabels":[],"idMembers":[],"shortLink":"LiM33333"}]'
echo '{"headRefOid":"llll2222","mergeable":"MERGEABLE","reviews":[]}' >"$tmp/gh/example-org_example-app-75.json"
mkdir -p "$T/cards/LiM22222" "$T/cards/LiM33333"
echo '[{"date":"2026-10-15T11:00:00.000Z","idMemberCreator":"'"$CLAUDE"'","data":{"text":"AWAITING VERIFIED: example-org/example-app#75 @ llll2222"}}]' >"$T/cards/LiM22222/actions"
echo '[{"date":"'"$(ago 40)"'","idMemberCreator":"'"$CLAUDE"'","data":{"text":"PLAN: revision 1"}}]' >"$T/cards/LiM33333/actions"
limset wvl workflow-verifier LiM22222 7200
run "$tmp/li10" W8 BOARD_WAIT_LIMIT=1 "$W"
ok "limit: the WORKFLOW VERIFY: and VERIFY PLAN: are held while the limit holds" '! grep -q "VERIFY" "$tmp/li10"' "$(cat "$tmp/li10")"
python3 -I - "$tmp/state-lim.json" <<'PY'
import json, sys, time
s = json.load(open(sys.argv[1])); s["limits"]["wvl"]["reset"] = time.time() - 5
json.dump(s, open(sys.argv[1], "w"))
PY
run "$tmp/li11" W8 BOARD_WAIT_LIMIT=2 "$W"
ok "limit: once the limit has reset, VERIFY: and VERIFY PLAN: print and RESUME: names the agent" 'grep -q "^VERIFY: .*LiM22222" "$tmp/li11" && grep -q "^VERIFY PLAN: .*LiM33333" "$tmp/li11" && grep -q "^RESUME: .*workflow-verifier card=LiM22222 id=wvl" "$tmp/li11"' "$(cat "$tmp/li11")"
# AGENT: dead re-arm held while a limit on that type holds
rm -f "$tmp/state-lim.json"
cards '[{"id":"l4","name":"Dead manager lim","idList":"lb","idLabels":[],"idMembers":[],"shortLink":"LiM44444"}]'
echo "dead card-manager card=LiM44444 id=cml last=1200s children=0 interrupted /x" >"$tmp/agents"
run "$tmp/li12" W8 BOARD_WAIT_LIMIT=2 "$W"
python3 -I - "$tmp/state-lim.json" <<'PY'
import json, sys, time
s = json.load(open(sys.argv[1])); s["marks"]["dead:cml"] = time.time() - 2400
s.setdefault("limits", {})["other"] = {"type": "card-manager", "card": "LiM99999", "seen": time.time(), "reset": time.time() + 7200}
json.dump(s, open(sys.argv[1], "w"))
PY
run "$tmp/li13" W8 BOARD_WAIT_LIMIT=1 "$W"
ok "limit: the AGENT: dead re-arm is held while a limit on that agent type has not reset" '! grep -q "AGENT: dead" "$tmp/li13"' "$(cat "$tmp/li13")"
: >"$tmp/agents"

# The top-card gate (rules.md, List order) also covers the noverifier STUCK and has_work("workflow-verifier") of a lower MERGING card.
rm -f "$tmp/state-lim.json"; : >"$tmp/agents"
cards '[{"id":"vt1","name":"[AGENTS] Top verify (#90)","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"VgT11111","pos":100,
         "desc":"**PR:** example-org/example-app#90, https://github.com/example-org/example-app/pull/90 (rule)"},
        {"id":"vt2","name":"[AGENTS] Lower verify (#91)","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"VgL22222","pos":200,
         "desc":"**PR:** example-org/example-app#91, https://github.com/example-org/example-app/pull/91 (rule)"}]'
run "$tmp/tg1" W8 BOARD_WAIT_LIMIT=2 "$W"
ok "order: the noverifier STUCK names the top [AGENTS] card in MERGING and not the lower one" 'grep -q "^STUCK: .*VgT11111.*no workflow verifier is alive" "$tmp/tg1" && ! grep -q "STUCK: .*VgL22222" "$tmp/tg1"' "$(cat "$tmp/tg1")"
cat >"$tmp/hw_check.py" <<'PY'
import importlib.machinery, importlib.util, json, sys
loader = importlib.machinery.SourceFileLoader("bw", sys.argv[1]); spec = importlib.util.spec_from_loader("bw", loader); bw = importlib.util.module_from_spec(spec); loader.exec_module(bw)
w = bw.Wait.__new__(bw.Wait)
cards = [{"shortLink": "A", "list": "MERGING", "pos": 100, "idLabels": [], "idMembers": [], "name": "[AGENTS] a (#1)", "desc": ""},
         {"shortLink": "B", "list": "MERGING", "pos": 200, "idLabels": [], "idMembers": [], "name": "[AGENTS] b (#2)", "desc": ""}]
w.bysl = {c["shortLink"]: c for c in cards}
w.s = {"unverified": {"A": [{"head": "x"}], "B": [{"head": "y"}]}, "planwait": []}
w.top_cache = (cards[0],)
assert w.has_work("workflow-verifier", "A", cards) and not w.has_work("workflow-verifier", "B", cards)
PY
ok "order: has_work(workflow-verifier) is true for the top MERGING card and false for a lower one" 'python3 -I "$tmp/hw_check.py" "$bin/board-wait.py"' "$(python3 -I "$tmp/hw_check.py" "$bin/board-wait.py" 2>&1)"
cat >"$tmp/hw_promoter.py" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("bw", sys.argv[1]); spec = importlib.util.spec_from_loader("bw", loader); bw = importlib.util.module_from_spec(spec); loader.exec_module(bw)
w = bw.Wait.__new__(bw.Wait)
rel = {"shortLink": "R", "list": "RELEASING", "pos": 1, "idLabels": [], "idMembers": [], "name": "🚀 RELEASE: running: SMOKE", "desc": ""}
card = {"shortLink": "C", "list": "RELEASING", "pos": 2, "idLabels": [], "idMembers": [], "name": "a card (#3)", "desc": ""}
w.s = {}
assert w.has_work("promoter", None, [rel, card])
rel["idLabels"] = [bw.BLOCKED]
assert not w.has_work("promoter", None, [rel, card])
rel["idLabels"] = []
assert w.has_work("promoter", None, [rel, card])
PY
ok "has_work(promoter) is false while the release status card carries the Blocked label and true again after" 'python3 -I "$tmp/hw_promoter.py" "$bin/board-wait.py"' "$(python3 -I "$tmp/hw_promoter.py" "$bin/board-wait.py" 2>&1)"
: >"$tmp/agents"

# gw is not fooled by a reader that stops early: 200 KB of output with the match first, SIGPIPE ignored as in
# the agents' shells; a pipe into grep -q fails this every run (the old form), the here-string never does.
pipe_case() (
  trap '' PIPE
  writes() { printf 'MATCH\n'; head -c 204800 /dev/zero | tr '\0' x; echo; }
  bad=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    gw -q MATCH || bad=$((bad + 1))
    gw -q NOSUCH && bad=$((bad + 1))
  done
  echo "$bad"
)
pipe_bad=$(pipe_case 2>"$tmp/pipe.err")
ok "gw: a here-string read is not fooled by a reader that stops early (200 KB, 20 runs)" '[ "$pipe_bad" = 0 ] && [ ! -s "$tmp/pipe.err" ]' "wrong=$pipe_bad stderr=$(cat "$tmp/pipe.err")"


# 12. Stuck resources (card dApvrFkP): SERVER LOST:, CI STUCK: as a STUCK: line, WAIT OVER:, CHECK WAIT?:, the new defaults.
W5() { env BOARD_WAIT_STATE=$tmp/state-res.json "$@"; }
rm -f "$tmp/state-res.json"; lists_testing
ok "defaults: the wake re-arm is 600 and the idle agent limit 900" '[ "$(sed -n "s/^REARM = float(env(\"BOARD_WAIT_REARM\", \"\([0-9]*\)\")).*/\1/p" "$bin/board-wait.py")" = 600 ] && [ "$(sed -n "s/^IDLE = float(env(\"BOARD_WAIT_IDLE\", \"\([0-9]*\)\")).*/\1/p" "$bin/board-wait.py")" = 900 ]'
cards '[]'
echo 'SERVER LOST: test-server-2 [Lost1111]: host 100.1.2.3 offline on Tailscale; Probe: 2 reads since 10:00' >"$tmp/server-probe.out"
run "$tmp/res1" W5 BOARD_WAIT_LIMIT=2 "$W"
ok "resources: the probe's SERVER LOST: line is a wake line" 'grep -qxF "SERVER LOST: test-server-2 [Lost1111]: host 100.1.2.3 offline on Tailscale; Probe: 2 reads since 10:00" "$tmp/res1"' "$(cat "$tmp/res1")"
: >"$tmp/server-probe.out"
printf '%s\n' 'CI STUCK: o/r run 55 branch card/CiSt1111-x: CI job t of https://x/55 is still queued after one cancel and re-run. Tried: cancel at 10:00:00Z; re-run at 10:05:00Z' >"$tmp/ci-unstick.out"
mkdir -p "$T/cards/CiSt1111" && echo '[]' >"$T/cards/CiSt1111/actions"
cards '[{"id":"s1","name":"Stuck CI card","idList":"lb","idLabels":[],"idMembers":[],"shortLink":"CiSt1111"}]'
run "$tmp/res2" W5 BOARD_WAIT_LIMIT=2 "$W"
ok "resources: a CI STUCK: line becomes a STUCK: line naming the card of its branch" 'grep -q "^STUCK: \"Stuck CI card\" \[CiSt1111\] (BUILDING): CI is stuck: CI job t of https://x/55 is still queued" "$tmp/res2"' "$(cat "$tmp/res2")"
echo 'CI UNSTICK FAILED: could not read GitHub runs (HTTP 500)' >"$tmp/ci-unstick.out"
run "$tmp/res3" W5 BOARD_WAIT_LIMIT=2 "$W"
ok "resources: CI UNSTICK FAILED: becomes one STUCK: line" 'grep -q "^STUCK: CI recovery is blind: could not read GitHub runs" "$tmp/res3"' "$(cat "$tmp/res3")"
: >"$tmp/ci-unstick.out"
# WAIT OVER:
mkdir -p "$T/cards/WovR1111" "$T/cards/WovR2222" "$T/cards/WovR3333"
echo '[{"date":"2026-10-27T09:00:00.000Z","data":{"text":"WAITS FOR: CI of o/r#9 to finish. Auto-check: ci o/r#9"}}]' >"$T/cards/WovR1111/actions"
echo '[{"date":"2026-10-27T09:00:00.000Z","data":{"text":"RELEASE BLOCKER: the deploy stuck"}},{"date":"2026-10-27T09:05:00.000Z","data":{"text":"WAITS FOR: you: look at the hosts. Auto-check: run o/r 77"}}]' >"$T/cards/WovR2222/actions"
echo '[{"date":"2026-10-27T09:00:00.000Z","data":{"text":"WAITS FOR: you: CI of o/r#10 is stuck, look at it"}}]' >"$T/cards/WovR3333/actions"
cards '[{"id":"w1","name":"Waits for CI","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"WovR1111"},
        {"id":"w2","name":"Release blocked: deploy","idList":"lm","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"WovR2222"},
        {"id":"w3","name":"Legacy CI wait","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"WovR3333"}]'
echo '[{"name":"flutter-test","bucket":"pending"}]' >"$tmp/gh/checks-o_r-9.json"
echo '{"status":"in_progress","conclusion":"","jobs":[]}' >"$tmp/gh/run-o_r-77.json"
echo '[{"name":"flutter-test","bucket":"pending"}]' >"$tmp/gh/checks-o_r-10.json"
run "$tmp/res4" W5 BOARD_WAIT_LIMIT=2 "$W"
ok "wait over: nothing while the checks are pending" '! grep -q "WAIT OVER:\|CHECK WAIT?:" "$tmp/res4"' "$(cat "$tmp/res4")"
echo '[{"name":"flutter-test","bucket":"fail"},{"name":"lint","bucket":"pass"}]' >"$tmp/gh/checks-o_r-9.json"
echo '{"status":"completed","conclusion":"cancelled","jobs":[{"name":"deploy","conclusion":"cancelled"}]}' >"$tmp/gh/run-o_r-77.json"
echo '[{"name":"flutter-test","bucket":"pass"}]' >"$tmp/gh/checks-o_r-10.json"
run "$tmp/res5" W5 BOARD_WAIT_LIMIT=2 "$W"
ok "wait over: Auto-check: ci with completed checks is WAIT OVER: with the verdict (any conclusion), UNBLOCKED:" 'grep -qxF "WAIT OVER: \"Waits for CI\" [WovR1111] (TODO): o/r#9 checks completed (RED flutter-test); post UNBLOCKED:" "$tmp/res5"' "$(cat "$tmp/res5")"
ok "wait over: a release hold card's Auto-check: run ends with RESOLVED:" 'grep -qxF "WAIT OVER: \"Release blocked: deploy\" [WovR2222] (MERGING): o/r run 77 checks completed (RED deploy); post RESOLVED:" "$tmp/res5"' "$(cat "$tmp/res5")"
ok "wait over: a legacy WAITS FOR: you naming CI is CHECK WAIT?:, not WAIT OVER:" 'grep -qxF "CHECK WAIT?: \"Legacy CI wait\" [WovR3333] (TODO): o/r#10 checks completed (GREEN); its WAITS FOR: may be over, the main session confirms" "$tmp/res5"' "$(cat "$tmp/res5")"
run "$tmp/res6" W5 BOARD_WAIT_LIMIT=2 "$W"
ok "wait over: printed once; CHECK WAIT?: not again within 2 hours" '! grep -q "WAIT OVER:\|CHECK WAIT?:" "$tmp/res6"' "$(cat "$tmp/res6")"
python3 -I - "$tmp/state-res.json" <<'PY'
import json, sys, time
s = json.load(open(sys.argv[1]))
for k in list(s["marks"]):
    if k.startswith("checkwait:"): s["marks"][k] = time.time() - 7300
json.dump(s, open(sys.argv[1], "w"))
PY
run "$tmp/res7" W5 BOARD_WAIT_LIMIT=2 "$W"
ok "wait over: CHECK WAIT?: comes again after 2 hours with no newer comment, WAIT OVER: does not" 'grep -q "CHECK WAIT?:" "$tmp/res7" && ! grep -q "WAIT OVER:" "$tmp/res7"' "$(cat "$tmp/res7")"
cards '[]'


# 12b. A merger branch's stuck job names its card; a run ci-unstick cancelled is not a finished wait.
cards '[{"id":"m1","name":"Merger card","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"Mrg11111","desc":"**PR:** o/r#55"}]'
printf '%s\n' 'CI STUCK: o/r run 99 branch merger/55-pr: CI job t of https://x/99 is queued. Tried: nothing' >"$tmp/ci-unstick.out"
run "$tmp/res8" W5 BOARD_WAIT_LIMIT=2 "$W"
ok "resources: a merger/<pr>- branch names the card whose description lists the PR" 'grep -q "^STUCK: \"Merger card\" \[Mrg11111\] (MERGING): CI is stuck:" "$tmp/res8"' "$(cat "$tmp/res8")"
: >"$tmp/ci-unstick.out"
mkdir -p "$T/cards/WovR4444"; echo '[{"date":"2026-10-27T09:00:00.000Z","data":{"text":"WAITS FOR: CI of o/r#11. Auto-check: ci o/r#11"}}]' >"$T/cards/WovR4444/actions"
cards '[{"id":"w4","name":"Waits for recovery","idList":"lt","idLabels":["'"$BLOCKED"'"],"idMembers":[],"shortLink":"WovR4444"}]'
echo '[{"name":"flutter-test","bucket":"cancel"}]' >"$tmp/gh/checks-o_r-11.json"
printf 'state=cancelled\nrepo=o/r\nrun=123\npr=11\ncancelled_at=%s\n' "$(date +%s)" >"$tmp/cistate/o_r-123.state"
run "$tmp/res9" W5 BOARD_WAIT_LIMIT=2 "$W"
ok "wait over: a run ci-unstick cancelled for recovery is still pending" '! grep -q "WAIT OVER:" "$tmp/res9"' "$(cat "$tmp/res9")"
# The state carries the head it recovers (head_sha): the current head still holds the wait, an older head does not.
printf 'state=cancelled\nrepo=o/r\nrun=123\npr=11\nhead_sha=oldhead\ncancelled_at=%s\n' "$(date +%s)" >"$tmp/cistate/o_r-123.state"
echo '{"headRefOid":"oldhead"}' >"$tmp/gh/o_r-11.json"
run "$tmp/res9b" W5 BOARD_WAIT_LIMIT=2 "$W"
ok "wait over: a recovery state for the current head of the PR still holds the wait" '! grep -q "WAIT OVER:" "$tmp/res9b"' "$(cat "$tmp/res9b")"
echo '{"headRefOid":"newhead"}' >"$tmp/gh/o_r-11.json"
run "$tmp/res10" W5 BOARD_WAIT_LIMIT=2 "$W"
rm -f "$tmp/gh/o_r-11.json"
ok "wait over: a recovery state for an older head of the PR does not hold the wait; the cancelled checks end it" 'grep -q "WAIT OVER: .*\[WovR4444\]" "$tmp/res10"' "$(cat "$tmp/res10")"
rm -f "$tmp/cistate/o_r-123.state"
cards '[]'


# 12c. A probe and a ci-unstick that sleep past their budget end the call on time with no line.
cp "$tmp/fakebin/server-probe" "$tmp/sp.keep"; cp "$tmp/fakebin/ci-unstick" "$tmp/cu.keep"
printf '#!/usr/bin/env bash\nsleep 30\necho "SERVER LOST: late"\n' >"$tmp/fakebin/server-probe"
printf '#!/usr/bin/env bash\nsleep 30\necho "CI UNSTICK FAILED: late"\n' >"$tmp/fakebin/ci-unstick"
t0=$SECONDS
run "$tmp/res11" W5 BOARD_WAIT_LIMIT=2 BOARD_WAIT_RESOURCE_BUDGET=1 "$W"
ok "resources: slow scripts are cut at their budget; the call still ends and prints no late line" '[ $((SECONDS - t0)) -lt 20 ] && ! grep -q "late" "$tmp/res11"' "took $((SECONDS - t0))s: $(cat "$tmp/res11")"
cp "$tmp/sp.keep" "$tmp/fakebin/server-probe"; cp "$tmp/cu.keep" "$tmp/fakebin/ci-unstick"

# 13. The main checkout follows origin/main (card HWd2DhDL): fake repos in temporary directories, no network.
W6() { env BOARD_WAIT_STATE=$tmp/state-mc.json BOARD_WAIT_MAIN_FF=1 BOARD_WAIT_MAIN_REPO=$tmp/mc/co BOARD_WAIT_MAIN_HOLD=$tmp/mc/hold BOARD_WAIT_WATCHER_RELOAD=$tmp/mc/reload "$@"; }
gi() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
mc_new() { # fresh bare origin, a checkout on main and a pusher clone; no state, no hold
  rm -rf "$tmp/mc" "$tmp/state-mc.json"; mkdir -p "$tmp/mc"
  gi init -q --bare -b main "$tmp/mc/origin.git"
  gi clone -q "$tmp/mc/origin.git" "$tmp/mc/co" 2>/dev/null; gi clone -q "$tmp/mc/origin.git" "$tmp/mc/push" 2>/dev/null
  (cd "$tmp/mc/push" && git checkout -q -b main 2>/dev/null; echo a >a.txt; echo b >b.txt; gi add .; gi commit -qm one; git push -q origin main 2>/dev/null)
  (cd "$tmp/mc/co" && git fetch -q origin && git checkout -q -B main origin/main)
  printf '#!/usr/bin/env bash\necho "${FAKE_RELOAD:-NONE}"\n' >"$tmp/mc/reload"; chmod +x "$tmp/mc/reload"
}
mc_push() { # mc_push <file> <message>: a new commit on origin/main
  (cd "$tmp/mc/push" && echo "$RANDOM" >"$1" && gi add . && gi commit -qm "$2" && git push -q origin main 2>/dev/null)
}
mc_head() { git -C "$tmp/mc/co" rev-parse HEAD; }
mc_age() { # make the recorded refusal older by 200 s
  python3 -I - "$tmp/state-mc.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); f = s["maincheckout"]["fail"]; f["since"] -= 200; f.pop("printed", None)
json.dump(s, open(sys.argv[1], "w"))
PY
}
cards '[]'
mc_new; mc_push a.txt two
run "$tmp/mc1" W6 FAKE_RELOAD="INPLACE: rules.md x..y +1/-0" BOARD_WAIT_LIMIT=2 "$W"
ok "main checkout: origin/main ahead and a clean checkout: HEAD is fast-forwarded and an INPLACE check line is a wake line" '[ "$(mc_head)" = "$(git -C "$tmp/mc/push" rev-parse HEAD)" ] && grep -q "^MAIN CHECKOUT: fast-forwarded to .*; watcher-reload: INPLACE:" "$tmp/mc1"' "$(cat "$tmp/mc1")"
run "$tmp/mc2" W6 BOARD_WAIT_LIMIT=1 "$W"
ok "main checkout: already current: nothing printed" '! grep -q "main checkout\|MAIN CHECKOUT" "$tmp/mc2"' "$(cat "$tmp/mc2")"
mc_new; mc_push a.txt two; echo dirty >>"$tmp/mc/co/b.txt"; echo x >"$tmp/mc/co/untracked.bak"
run "$tmp/mc3" W6 BOARD_WAIT_LIMIT=2 "$W"
ok "main checkout: an unrelated modified file and an untracked file do not block it, and stay" '[ "$(mc_head)" = "$(git -C "$tmp/mc/push" rev-parse HEAD)" ] && grep -q dirty "$tmp/mc/co/b.txt" && [ -f "$tmp/mc/co/untracked.bak" ] && ! grep -q "MAIN CHECKOUT" "$tmp/mc3"' "$(cat "$tmp/mc3")"
mc_new; mc_push a.txt two; echo local >>"$tmp/mc/co/a.txt"; before=$(mc_head)
run "$tmp/mc4" W6 BOARD_WAIT_LIMIT=1 "$W"
ok "main checkout: a refused fast-forward is not reported on its first sighting (a passing lock)" '! grep -q "^STUCK: main checkout" "$tmp/mc4" && [ "$(mc_head)" = "$before" ]' "$(cat "$tmp/mc4")"
mc_age
run "$tmp/mc5" W6 BOARD_WAIT_LIMIT=2 "$W"
ok "main checkout: the same refusal 120 s later is a STUCK: line and the checkout is untouched" 'grep -q "^STUCK: main checkout cannot fast-forward to origin/main (.*): .*a.txt" "$tmp/mc5" && [ "$(mc_head)" = "$before" ] && grep -q local "$tmp/mc/co/a.txt"' "$(cat "$tmp/mc5")"
run "$tmp/mc6" W6 BOARD_WAIT_LIMIT=1 "$W"
ok "main checkout: the same STUCK: line is not repeated inside the re-arm" '! grep -q "^STUCK: main checkout" "$tmp/mc6"' "$(cat "$tmp/mc6")"
git -C "$tmp/mc/co" checkout -q -- a.txt
run "$tmp/mc7" W6 BOARD_WAIT_LIMIT=2 "$W"
ok "main checkout: once the refusal is gone the next check fast-forwards and clears it" '[ "$(mc_head)" = "$(git -C "$tmp/mc/push" rev-parse HEAD)" ] && [ "$(python3 -I -c "import json,sys; print(json.load(open(sys.argv[1]))[\"maincheckout\"].get(\"fail\"))" "$tmp/state-mc.json")" = None ]' "$(cat "$tmp/mc7")"
mc_new; mc_push a.txt two; git -C "$tmp/mc/co" checkout -q -b other; before=$(mc_head)
run "$tmp/mc8" W6 BOARD_WAIT_LIMIT=1 "$W"; mc_age
run "$tmp/mc9" W6 BOARD_WAIT_LIMIT=2 "$W"
ok "main checkout: a checkout on another branch is a STUCK: line after two sightings and is not moved" 'grep -q "^STUCK: main checkout cannot fast-forward .*on branch other" "$tmp/mc9" && [ "$(mc_head)" = "$before" ]' "$(cat "$tmp/mc9")"
mc_new; mc_push a.txt two; before=$(mc_head); rm -rf "$tmp/mc/origin.git"
run "$tmp/mc10" W6 BOARD_WAIT_LIMIT=1 "$W"
ok "main checkout: a failed fetch prints no STUCK: and changes nothing" '! grep -q "^STUCK: main checkout\|MAIN CHECKOUT" "$tmp/mc10" && [ "$(mc_head)" = "$before" ]' "$(cat "$tmp/mc10")"
mc_new; mc_push a.txt two; before=$(mc_head)
run "$tmp/mc11" W6 BOARD_WAIT_MAIN_FF=0 BOARD_WAIT_LIMIT=1 "$W"
ok "main checkout: BOARD_WAIT_MAIN_FF=0 skips it" '[ "$(mc_head)" = "$before" ]' "$(cat "$tmp/mc11")"
# the hold file
mc_new; mc_push a.txt two; before=$(mc_head); echo "waiting for section 22" >"$tmp/mc/hold"
run "$tmp/mc12" W6 BOARD_WAIT_LIMIT=2 "$W"
run "$tmp/mc13" W6 BOARD_WAIT_LIMIT=1 "$W"
ok "main checkout: a hold file stops the fast-forward and prints one STUCK: held line per origin/main sha" '[ "$(mc_head)" = "$before" ] && [ "$(grep -c "^STUCK: main checkout held (waiting for section 22): origin/main" "$tmp/mc12")" = 1 ] && ! grep -q "^STUCK: main checkout" "$tmp/mc13"' "$(cat "$tmp/mc12") / $(cat "$tmp/mc13")"
mc_push a.txt three
run "$tmp/mc14" W6 BOARD_WAIT_LIMIT=2 "$W"
ok "main checkout: a new origin/main sha under a hold prints one more line" '[ "$(grep -c "^STUCK: main checkout held" "$tmp/mc14")" = 1 ] && [ "$(mc_head)" = "$before" ]' "$(cat "$tmp/mc14")"
rm "$tmp/mc/hold"
run "$tmp/mc15" W6 BOARD_WAIT_LIMIT=2 "$W"
ok "main checkout: with the hold removed the next check fast-forwards" '[ "$(mc_head)" = "$(git -C "$tmp/mc/push" rev-parse HEAD)" ]' "$(cat "$tmp/mc15")"
# the trailer
mc_new; mc_push a.txt two; mc_push a.txt "$(printf 'repo move\n\nMain checkout: hold until section 22')"; mc_push b.txt "$(printf 'quotes it\n\nsee Main checkout: hold in the text')"; before=$(mc_head)
run "$tmp/mc16" W6 BOARD_WAIT_LIMIT=2 "$W"
ok "main checkout: a commit with the trailer line writes the hold file, merges nothing and prints one STUCK: held line" '[ "$(mc_head)" = "$before" ] && grep -q "^held for .*: Main checkout: hold until section 22" "$tmp/mc/hold" && [ "$(grep -c "^STUCK: main checkout held (held for" "$tmp/mc16")" = 1 ]' "$(cat "$tmp/mc16") $(cat "$tmp/mc/hold" 2>&1)"
rm "$tmp/mc/hold"
run "$tmp/mc17" W6 BOARD_WAIT_LIMIT=2 "$W"
ok "main checkout: clearing the hold does not bring it back: the next check merges (a commit quoting the words mid-line never held)" '[ "$(mc_head)" = "$(git -C "$tmp/mc/push" rev-parse HEAD)" ] && [ ! -e "$tmp/mc/hold" ]' "$(cat "$tmp/mc17")"
# two trailer commits, and a lost state file
mc_new; mc_push a.txt "$(printf 'first\n\nMain checkout: hold')"; mc_push b.txt "$(printf 'second\n\nMain checkout: hold')"; before=$(mc_head)
run "$tmp/mc18" W6 BOARD_WAIT_LIMIT=2 "$W"; h1=$(cat "$tmp/mc/hold"); rm "$tmp/mc/hold"
run "$tmp/mc19" W6 BOARD_WAIT_LIMIT=2 "$W"; h2=$(cat "$tmp/mc/hold" 2>/dev/null); rm -f "$tmp/mc/hold"
ok "main checkout: two trailer commits are held one after the other, each by its own sha" '[ -n "$h1" ] && [ -n "$h2" ] && [ "$h1" != "$h2" ] && [ "$(mc_head)" = "$before" ]' "$h1 / $h2"
run "$tmp/mc20" W6 BOARD_WAIT_LIMIT=2 "$W"
ok "main checkout: after both holds are cleared the checkout moves" '[ "$(mc_head)" = "$(git -C "$tmp/mc/push" rev-parse HEAD)" ]' "$(cat "$tmp/mc20")"
mc_new; mc_push a.txt "$(printf 'x\n\nMain checkout: hold')"; before=$(mc_head)
run "$tmp/mc21" W6 BOARD_WAIT_LIMIT=2 "$W"; rm -f "$tmp/mc/hold" "$tmp/state-mc.json"
run "$tmp/mc22" W6 BOARD_WAIT_LIMIT=2 "$W"
ok "main checkout: a lost state file holds a trailer commit still ahead of HEAD once more" '[ -f "$tmp/mc/hold" ] && [ "$(mc_head)" = "$before" ]' "$(cat "$tmp/mc22")"
cards '[]'

# The wording cases that read the live agent files and rules.md (promoter gate and pin step, compaction windows and CEILING_TYPES).
"$root/tests/test-board-content.sh" >"$tmp/board-content.out" 2>&1; bc_rc=$?
ok "board content: test-board-content.sh passes" '[ "$bc_rc" = 0 ]' "$(grep '^FAIL' "$tmp/board-content.out")"

echo
if [ "$failures" -eq 0 ]; then echo "All cases passed"; exit 0; fi
echo "$failures case(s) failed"; exit 1
