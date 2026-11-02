#!/bin/bash
# Tests the Trello retry, the deadline, the read window and the crash path of the three gates
# (merge-gate.sh, staging-gate.sh, merged-comment-gate.sh). No network: curl, gh and git are fakes
# on PATH; the review policy is a stub. Usage: test-hook-trello-retry.sh [<hooks folder>]
# (default: this checkout's .claude/hooks).
#
# The fake curl serves the board (board.json, newest first, honoring limit= and before=), a card
# (card-<id>.json) and its comments (comments-<id>.json). A line in $FD/seq makes the next request
# fail as it says: 200, 429, 503, 404, exit6 or exit22 (one line is used up per request). $FD/sleep
# makes every request hang for its --max-time (as a stuck network would) and exit 28.
set -u -o pipefail
export KOURAI_CONFIG=${KOURAI_CONFIG:-$(cd "$(dirname "$0")" && pwd)/fixtures/config.toml}
export KOURAI_BIN=${KOURAI_BIN:-$(cd "$(dirname "$0")/../bin" && pwd)}

here=$(cd "$(dirname "$0")/../bin" && pwd)
hooks=${1:-$(cd "$here/../hooks" && pwd)}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
FD=$T/fd; mkdir -p "$T/bin" "$T/home/Development/example_files" "$FD"
printf 'TRELLO_KEY=k\nTRELLO_TOKEN=t\n' >"$T/home/Development/example_files/trello.env"

cat >"$T/bin/curl" <<'EOF'
#!/bin/bash
url="" mt=30 limit="" before="" prev=""
for a in "$@"; do
  case "$a" in https://api.trello.com/1/*) url=${a#https://api.trello.com/1} ;; esac
  case "$prev" in --max-time) mt=$a ;; esac
  case "$a" in limit=*) limit=${a#limit=} ;; before=*) before=${a#before=} ;; esac
  prev=$a
done
echo "$url limit=$limit before=$before" >>"$FD/req.log"
if [ -f "$FD/sleep" ]; then [ "$mt" -gt 30 ] && mt=30; sleep "$mt"; exit 28; fi
if [ -s "$FD/seq" ]; then
  first=$(head -1 "$FD/seq"); sed -i.bak 1d "$FD/seq"; rm -f "$FD/seq.bak"
  case "$first" in
    exit*) exit "${first#exit}" ;;
    200) ;;
    *) printf '[]\n%s' "$first"; exit 0 ;;
  esac
fi
case "$url" in
  /boards/*/actions)
    jq -c --arg b "$before" --argjson n "${limit:-1000}" \
      '(if $b == "" then . else (map(.id) | index($b)) as $i | .[($i + 1):] end) | .[:$n]' "$FD/board.json" ;;
  /cards/*/actions) id=${url#/cards/}; id=${id%%/*}; cat "$FD/comments-$id.json" || exit 22 ;;
  /cards/*) cat "$FD/card-${url#/cards/}.json" || exit 22 ;;
  *) exit 22 ;;
esac
printf '\n200'
EOF
cat >"$T/bin/gh" <<'EOF'
#!/bin/bash
[ "$1 $2" = "pr view" ] && { echo "${FAKE_GH_PR_VIEW:-MERGED aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"; exit 0; }
[ "$1" = api ] && { echo; exit 0; }
exit 1
EOF
cat >"$T/bin/git" <<'EOF'
#!/bin/bash
while [ "${1:-}" = -C ]; do shift 2; done
case "$1" in
  fetch) exit 0 ;;
  rev-parse) echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
  merge-base) exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/"*
mkdir -p "$T/hooks"
cp "$hooks/merge-gate.sh" "$hooks/staging-gate.sh" "$hooks/merged-comment-gate.sh" "$T/hooks/"
printf '#!/bin/bash\necho "NO REVIEW NEEDED"\nexit 0\n' >"$T/hooks/review-policy.sh"
hv=$("$KOURAI_BIN/kourai-config" get install.version); mkdir -p "$T/hooksdir/$hv"; cp "$T/hooks/review-policy.sh" "$T/hooksdir/$hv/"
{ cat "$KOURAI_CONFIG"; printf '\n[paths]\nhooks_dir = "%s"\ntrello_env = "%s"\n' "$T/hooksdir" "$T/home/Development/example_files/trello.env"; } >"$T/config.toml"; export KOURAI_CONFIG=$T/config.toml
chmod +x "$T/hooks/"*
# merge-gate runs ../bin/verified-carry.sh from its own folder
cp -R "$KOURAI_BIN" "$T/kbin"; export KOURAI_DEFAULTS=$KOURAI_BIN/../config/defaults.toml KOURAI_BIN=$T/kbin
printf '#!/bin/bash\necho "NOT CARRIED: x"\nexit 1\n' >"$T/kbin/verified-carry.sh"; chmod +x "$T/kbin/verified-carry.sh"

export PATH="$T/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
export HOME=$T/home FD
export RC_RETRY_SLEEP=0
pass=0 fail=0
ok() { # ok <name> <condition…>
  local name=$1; shift
  if "$@"; then pass=$((pass+1)); echo "PASS $name"; else fail=$((fail+1)); echo "FAIL $name"; fi
}

SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
PRURL=https://github.com/example-org/example-app/pull/12
CARD=111111111111111111111111
OLD=222222222222222222222222
now=$(date -u +%s)
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z; }
# mkboard <total> <days apart per 100 comments> <idx:card:text>…: a board of comments, newest first
mkboard() {
  local total=$1 per100=$2; shift 2
  python3 - "$FD/board.json" "$total" "$per100" "$now" "$@" <<'PY'
import json, sys, time
out, total, per100, now = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), int(sys.argv[4])
special = {}
for a in sys.argv[5:]:
    i, card, text = a.split(":", 2)
    special[int(i)] = (card, text)
items = []
for i in range(total):
    card, text = special.get(i, ("%024x" % (0xabc000 + i), "chatter %d" % i))
    t = now - int(i * per100 * 86400 / 100)
    items.append({"id": "%024x" % (0x5000000 + total - i), "idMemberCreator": "m1",
                  "date": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(t)),
                  "data": {"text": text, "card": {"id": card}}})
json.dump(items, open(out, "w"))
PY
}
card_json() { echo "{\"name\":\"$2\",\"shortUrl\":\"https://trello.com/c/$1\",\"idList\":\"000000000000000000000011\"}" >"$FD/card-$1.json"; }
comments_json() { echo "[{\"date\":\"2026-11-01T10:00:00.000Z\",\"data\":{\"text\":\"$2\"}}]" >"$FD/comments-$1.json"; }
reset() { rm -f "$FD/seq" "$FD/sleep" "$FD/req.log"; : >"$FD/req.log"; }

merge_in() { jq -n --arg c "gh pr merge 12 --repo example-org/example-app --match-head-commit $SHA" '{tool_input:{command:$c},cwd:"/tmp"}'; }
stg_in() { jq -n --arg c "git push origin $SHA:refs/heads/staging" '{tool_input:{command:$c}}'; }
run_merge() { bash "$T/hooks/merge-gate.sh" <<<"$(merge_in)" 2>"$T/err"; }
decision() { jq -r '.hookSpecificOutput.permissionDecision // "none"' <<<"$1" 2>/dev/null || echo none; }
reason() { jq -r '.hookSpecificOutput.permissionDecisionReason // ""' <<<"$1" 2>/dev/null; }
reqs() { grep -c . "$FD/req.log"; }

card_json $CARD "Some card"; comments_json $CARD "nothing"
card_json $OLD "[AGENTS] Old card"; comments_json $OLD "nothing verified"

mkboard 5 1 "2:$CARD:PR: $PRURL"
reset; printf '429\n' >"$FD/seq"
out=$(run_merge); rc=$?
ok "a 429 then a 200 on the board read passes (merge-gate allows)" [ "$(decision "$out")" = allow ]
reset; printf '429\n429\n' >"$FD/seq"
out=$(run_merge)
ok "two 429s deny TRANSIENT" bash -c '[ "$1" = deny ] && [[ "$2" == "merge-gate: TRANSIENT: board page 1 (HTTP 429)" ]]' _ "$(decision "$out")" "$(reason "$out")"
ok "two 429s are two requests" [ "$(reqs)" = 2 ]
reset; printf '404\n' >"$FD/seq"
out=$(run_merge)
ok "a 404 is not retried: one request, the plain refusal" bash -c '[ "$1" = deny ] && [ "$2" = 1 ] && [[ "$3" == *"can'"'"'t read the Trello board"* ]]' _ "$(decision "$out")" "$(reqs)" "$(reason "$out")"
reset; printf '503\n' >"$FD/seq"
out=$(run_merge)
ok "a 503 is retried and passes" [ "$(decision "$out")" = allow ]
reset; printf 'exit6\n' >"$FD/seq"
out=$(run_merge)
ok "curl exit 6 is retried and passes" [ "$(decision "$out")" = allow ]
reset; printf 'exit22\n' >"$FD/seq"
out=$(run_merge)
ok "curl exit 22 is one request and a deny" bash -c '[ "$1" = deny ] && [ "$2" = 1 ]' _ "$(decision "$out")" "$(reqs)"

# a jq that fails only on the page read (jq length): a deny, never an allow
REALJQ=$(command -v jq)
mkdir -p "$T/fakejq"
cat >"$T/fakejq/jq" <<EOF
#!/bin/bash
[ "\$1" = length ] && exit 5
exec "$REALJQ" "\$@"
EOF
chmod +x "$T/fakejq/jq"
mkboard 5 1 "2:$CARD:PR: $PRURL"
reset; out=$(PATH="$T/fakejq:$PATH" run_merge)
ok "a jq that fails on the page read: the merge is denied, never allowed" bash -c '[ "$1" = deny ]' _ "$(decision "$out")"

# 650 comments over 3 pages, the PR: line on page 3 (index 620); all inside the 14-day window
mkboard 650 1 "620:$CARD:PR: $PRURL"
reset; out=$(run_merge)
ok "650 comments over 3 pages: the PR: line on page 3 is found" [ "$(decision "$out")" = allow ]
ok "no board request asks for more than 300" bash -c '! grep -E "^/boards/.* limit=([4-9][0-9][0-9]|[0-9]{4,})" "$1"' _ "$FD/req.log"
ok "the board took 3 page requests" bash -c '[ "$(grep -c "^/boards/" "$1")" = 3 ]' _ "$FD/req.log"

# the window: 14 days. 100 comments a day-ish: per100=7 days -> 300 comments = 21 days.
mkboard 650 4.7 "100:$CARD:PR: $PRURL" "620:$OLD:PR: $PRURL"
reset; out=$(run_merge)
ok "the window stop: an older second card (an [AGENTS] card with no VERIFIED:) beyond the stop is not read" [ "$(decision "$out")" = allow ]
ok "the older card is never fetched" bash -c '! grep -q "$2" "$1"' _ "$FD/req.log" "$OLD"
mkboard 650 4.7 "620:$CARD:PR: $PRURL"
reset; out=$(run_merge)
ok "no card inside the window: the extended read finds an old card" [ "$(decision "$out")" = allow ]
mkboard 650 4.7
reset; out=$(run_merge)
ok "no card at all: NO PR CARD with the date read back to" bash -c '[ "$1" = deny ] && [[ "$2" == "merge-gate: NO PR CARD (read back to 20"* ]]' _ "$(decision "$out")" "$(reason "$out")"

mkboard 650 4.7
reset; out=$(bash "$T/hooks/staging-gate.sh" <<<"$(stg_in)" 2>"$T/err")
ok "staging-gate: no full-test comment, read stopped at the window: NO FULL-TEST COMMENT IN WINDOW with the date" bash -c '[ "$1" = deny ] && [[ "$2" == "staging-gate: NO FULL-TEST COMMENT IN WINDOW: "*"(read back to 20"* ]]' _ "$(decision "$out")" "$(reason "$out")"
mkboard 5 1
reset; out=$(bash "$T/hooks/staging-gate.sh" <<<"$(stg_in)" 2>"$T/err")
ok "staging-gate: no full-test comment on a short board keeps the plain reason" bash -c '[ "$1" = deny ] && [[ "$2" == "staging-gate: no FULL SUITE GREEN"* ]]' _ "$(decision "$out")" "$(reason "$out")"

# a stuck network: every request hangs for its --max-time; the gates give up before deadline + 2 s
export RC_HOOK_DEADLINE=2
mkboard 5 1 "2:$CARD:PR: $PRURL"
reset; : >"$FD/sleep"; s=$SECONDS
out=$(run_merge); el=$((SECONDS - s))
ok "merge-gate on a stuck network: a TIMED OUT or TRANSIENT deny before the deadline + 2 s" bash -c '[ "$1" = deny ] && [[ "$2" == "merge-gate: TIMED OUT: "* || "$2" == "merge-gate: TRANSIENT: "* ]] && [ "$3" -le 4 ]' _ "$(decision "$out")" "$(reason "$out")" "$el"
reset; : >"$FD/sleep"; s=$SECONDS
out=$(bash "$T/hooks/staging-gate.sh" <<<"$(stg_in)" 2>"$T/err"); el=$((SECONDS - s))
ok "staging-gate on a stuck network: a TIMED OUT or TRANSIENT deny before the deadline + 2 s" bash -c '[ "$1" = deny ] && [[ "$2" == "staging-gate: TIMED OUT: "* || "$2" == "staging-gate: TRANSIENT: "* ]] && [ "$3" -le 4 ]' _ "$(decision "$out")" "$(reason "$out")" "$el"
mc_in() { jq -n --arg t "MERGED: example-org/example-app#12 @ $SHA" --arg c "$CARD" '{tool_input:{action:"add_comment",text:$t,cardId:$c}}'; }
reset; : >"$FD/sleep"; s=$SECONDS
out=$(bash "$T/hooks/merged-comment-gate.sh" <<<"$(mc_in)" 2>"$T/err"); el=$((SECONDS - s))
ok "merged-comment-gate (MERGED: comment) on a stuck network: a deny before the deadline + 2 s" bash -c '[ "$1" = deny ] && [[ "$2" == "merged-comment-gate: TIMED OUT: "* || "$2" == "merged-comment-gate: TRANSIENT: "* ]] && [ "$3" -le 4 ]' _ "$(decision "$out")" "$(reason "$out")" "$el"
# the move path fails open by design
mv_in() { jq -n --arg c "$CARD" '{tool_input:{action:"move",cardId:$c,listId:"000000000000000000000013"}}'; }
reset; : >"$FD/sleep"; s=$SECONDS
out=$(bash "$T/hooks/merged-comment-gate.sh" <<<"$(mv_in)" 2>"$T/err"); rc=$?; el=$((SECONDS - s))
ok "merged-comment-gate move to DONE on a stuck network: no decision, exit 0, before the deadline + 2 s" bash -c '[ -z "$1" ] && [ "$2" = 0 ] && [ "$3" -le 4 ]' _ "$out" "$rc" "$el"
unset RC_HOOK_DEADLINE
reset; comments_json $CARD "no merged comment here"
out=$(bash "$T/hooks/merged-comment-gate.sh" <<<"$(mv_in)" 2>"$T/err"); rc=$?
ok "a move to DONE of a card with no MERGED: comment gives no decision" bash -c '[ -z "$1" ] && [ "$2" = 0 ]' _ "$out" "$rc"

# a crash on a gated path: stderr CRASHED, exit 2; the same crash on an ungated command: exit 0, no output, no request
export RC_TEST_UNSET_FOR_CRASH=1
mkboard 5 1 "2:$CARD:PR: $PRURL"
reset; out=$(run_merge); rc=$?
ok "merge-gate: a crash on a merge exits 2 with CRASHED on stderr" bash -c '[ "$1" = 2 ] && grep -q "^merge-gate: CRASHED: " "$2" && [ -z "$3" ]' _ "$rc" "$T/err" "$out"
reset; out=$(bash "$T/hooks/staging-gate.sh" <<<"$(stg_in)" 2>"$T/err"); rc=$?
ok "staging-gate: a crash on a push to staging exits 2 with CRASHED on stderr" bash -c '[ "$1" = 2 ] && grep -q "^staging-gate: CRASHED: " "$2"' _ "$rc" "$T/err"
reset; out=$(bash "$T/hooks/merged-comment-gate.sh" <<<"$(mc_in)" 2>"$T/err"); rc=$?
ok "merged-comment-gate: a crash on a MERGED: comment exits 2 with CRASHED on stderr" bash -c '[ "$1" = 2 ] && grep -q "^merged-comment-gate: CRASHED: " "$2"' _ "$rc" "$T/err"
for c in "ls" "git status" "gh pr view 12"; do
  reset
  out=$(bash "$T/hooks/merge-gate.sh" <<<"$(jq -n --arg c "$c" '{tool_input:{command:$c}}')" 2>"$T/err"); rc=$?
  ok "merge-gate: the ungated command '$c' exits 0 with no output and no request" bash -c '[ "$1" = 0 ] && [ -z "$2" ] && [ ! -s "$3" ]' _ "$rc" "$out" "$FD/req.log"
  out=$(bash "$T/hooks/staging-gate.sh" <<<"$(jq -n --arg c "$c" '{tool_input:{command:$c}}')" 2>"$T/err"); rc=$?
  ok "staging-gate: the ungated command '$c' exits 0 with no output and no request" bash -c '[ "$1" = 0 ] && [ -z "$2" ] && [ ! -s "$3" ]' _ "$rc" "$out" "$FD/req.log"
done
reset; out=$(bash "$T/hooks/merged-comment-gate.sh" <<<"$(jq -n '{tool_input:{action:"add_comment",text:"hello",cardId:"x"}}')" 2>"$T/err"); rc=$?
ok "merged-comment-gate: a comment that is not MERGED: exits 0 with no output" bash -c '[ "$1" = 0 ] && [ -z "$2" ]' _ "$rc" "$out"
reset; out=$(bash "$T/hooks/merged-comment-gate.sh" <<<"$(mv_in)" 2>"$T/err"); rc=$?
ok "merged-comment-gate: a crash on the move path lets the call through (no decision, exit 0)" bash -c '[ "$1" = 0 ] && [ -z "$2" ]' _ "$rc" "$out"
unset RC_TEST_UNSET_FOR_CRASH

# the common block is the same in the three hooks
blk() { sed -n '/^# ---- gate-common v1/,/^# ---- end of gate-common v1/p' "$1"; }
ok "the gate-common block is not empty" bash -c '[ "$(sed -n "/^# ---- gate-common v1/,/^# ---- end of gate-common v1/p" "$1" | wc -l)" -gt 40 ]' _ "$hooks/merge-gate.sh"
ok "the gate-common block is the same in merge-gate.sh and staging-gate.sh" [ "$(blk "$hooks/merge-gate.sh")" = "$(blk "$hooks/staging-gate.sh")" ]
ok "the gate-common block is the same in merge-gate.sh and merged-comment-gate.sh" [ "$(blk "$hooks/merge-gate.sh")" = "$(blk "$hooks/merged-comment-gate.sh")" ]

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
