#!/usr/bin/env bash
# Tests agents-status.sh with fake transcripts and a fake Trello: no network.
#
# Usage: .claude/bin/test-agents-status.sh
#
# Builds agent transcripts in a temporary folder (agent-state.sh reads them), a
# fake `curl` that answers the Trello card read from a file, and a UI run's
# results.txt. aws, tailscale and ssh fail at once on PATH. Exits 0 when every
# case passes, 1 otherwise.
set -uo pipefail
export KOURAI_CONFIG=${KOURAI_CONFIG:-$(cd "$(dirname "$0")" && pwd)/fixtures/config.toml}
export KOURAI_BIN=${KOURAI_BIN:-$(cd "$(dirname "$0")/../bin" && pwd)}

bin=$(cd "$(dirname "$0")/../bin" && pwd)
tmp=$(mktemp -d)
# shellcheck disable=SC2329 # called by the EXIT trap
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

mkdir -p "$tmp/nonet" "$tmp/fakebin" "$tmp/tr/sess/subagents" "$tmp/logs"
for c in aws tailscale ssh; do
  printf '#!/usr/bin/env bash\necho "test: %s is not allowed in tests" >&2\nexit 99\n' "$c" >"$tmp/nonet/$c"
  chmod +x "$tmp/nonet/$c"
done
printf 'TRELLO_KEY=k\nTRELLO_TOKEN=SECRETTOKEN\n' >"$tmp/trello.env"
# Fake curl: copies $tmp/trello-<card>.json to the -o file and notes each call.
cat >"$tmp/fakebin/curl" <<FAKE
#!/usr/bin/env bash
out="" url=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out=\$2; shift 2 ;; -*) shift ;; *) url=\$1; shift ;; esac; done
card=\${url#https://trello.test/1/cards/}; card=\${card%%/*}
echo "\$card" >>$tmp/curl-calls
[ -f "$tmp/trello-\$card.json" ] || exit 22
cp "$tmp/trello-\$card.json" "\$out"
FAKE
chmod +x "$tmp/fakebin/curl"
export PATH="$tmp/nonet:$tmp/fakebin:$PATH"
export TRELLO_ENV_FILE=$tmp/trello.env TRELLO_API_BASE=https://trello.test/1
real_now=$(date +%s)
export AGENT_TRANSCRIPTS_DIR=$tmp/tr AGENT_STATE_NOW=2000000000 AGENTS_STATUS_NOW=$real_now
export AGENT_STATE_CACHE=$tmp/agent-state-cache
export AGENTS_STATUS_CACHE=$tmp/cache AGENTS_STATUS_TTL=30

failures=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; failures=$((failures + 1)); }
has() { if grep -qF -- "$2" <<<"$out"; then pass "$1"; else fail "$1" "missing '$2' in: $out"; fi; }
hasnt() { if grep -qF -- "$2" <<<"$out"; then fail "$1" "found '$2' in: $out"; else pass "$1"; fi; }

# agent <id> <type> <card> <seconds old> <command of its last tool call, or ""> [handback]
agent() {
  local id=$1 type=$2 card=$3 age=$4 cmd=$5 hand=${6:-} t f
  f=$tmp/tr/sess/subagents/agent-$id
  t=$(python3 -I -c "import datetime; print(datetime.datetime.fromtimestamp(2000000000-$age, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z'))")
  echo "{\"agentType\":\"$type\",\"parentAgentId\":null}" >"$f.meta.json"
  {
    printf '{"type":"user","timestamp":"%s","message":{"content":"Work https://trello.com/c/%s please"}}\n' "$t" "$card"
    if [ -n "$cmd" ]; then
      python3 -I -c "import json,sys; print(json.dumps({'type':'assistant','timestamp':sys.argv[1],'message':{'content':[{'type':'tool_use','id':'t1','name':'Bash','input':{'command':sys.argv[2]}}]}}))" "$t" "$cmd"
      printf '{"type":"user","timestamp":"%s","message":{"content":[{"type":"tool_result","tool_use_id":"t1"}]}}\n' "$t"
    fi
    [ "$hand" != int ] || printf '{"type":"user","timestamp":"%s","message":{"content":"[Request interrupted by user]"}}\n' "$t"
    [ "$hand" != handback ] || printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"tool_use","id":"t9","name":"SubagentHandback","input":{}}]}}\n' "$t"
  } >"$f.jsonl"
  python3 -I -c "import os,sys; os.utime(sys.argv[1], (2000000000-$age,)*2)" "$f.jsonl"
}

CLAUDE=000000000000000000000002
cat >"$tmp/trello-AbCd1234.json" <<TRELLO
[{"date":"2026-10-15T10:00:00.000Z","idMemberCreator":"$CLAUDE","data":{"text":"IN PROGRESS: feature-tester, function test (AFTER)"}},
 {"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"$CLAUDE","data":{"text":"BEFORE: mobile card/AbCd1234-x @ abc, development card/AbCd1234-x @ def"}}]
TRELLO
cat >"$tmp/logs/results.txt" <<RESULTS
PASS integration_test/ui/a_ui_test.dart (emulator-5554, 40s) log: x
PASS integration_test/ui/b_ui_test.dart (emulator-5554, 30s) log: y
FAIL integration_test/ui/c_ui_test.dart (emulator-5554, 20s) log: z
RESULTS

agent cm1 card-manager AbCd1234 12 "cd /wt && SECRET=hunter2 bash tool/foo.sh --token abc123"
agent ft1 feature-tester AbCd1234 2 "cd /wt && UI_TEST_API_BASE_URL=http://secret tool/ui_test_all.sh --ports 5554 --logs $tmp/logs integration_test/ui/a_ui_test.dart integration_test/ui/b_ui_test.dart integration_test/ui/c_ui_test.dart integration_test/ui/d_ui_test.dart integration_test/ui/e_ui_test.dart"
agent wb1 workflow-builder - 40 "git -C /wt commit -m x"
agent cm2 card-manager NoSuch99 20 "git status"
agent old1 merger EndedAAA 30 "" handback
agent dead1 promoter EndedBBB 5000 "" int

out=$("$bin/agents-status.sh" 2>"$tmp/err"); rc=$?
[ "$rc" = 0 ] && pass "table: exit 0" || fail "table: exit 0" "rc=$rc: $(cat "$tmp/err")"
has "table: header" "ROLE"
has "card manager row: step from the newest status comment" "card-manager      AbCd1234  5/6 function test (AFTER)"
has "card manager row: bar" "█████░ 5/6"
has "card manager row: last action, no env prefix or flags" "12s  Bash bash tool/foo.sh"
hasnt "no env value printed" "hunter2"
hasnt "no flag value printed" "abc123"
hasnt "no Trello token printed" "SECRETTOKEN"
has "feature tester row: step from its UI run" "feature-tester    AbCd1234  4/5 AFTER run"
has "test counts from results.txt" "tests 2/5 passed, 1 failed"
hasnt "the env value of the run is not printed" "http://secret"
has "a card Trello cannot answer: guessed step marked" "card-manager      NoSuch99  1/6 read card ?"
has "a workflow builder row: step from its last action" "workflow-builder  -         5/6 commit and PR"
hasnt "a reported agent is left out" "EndedAAA"
hasnt "a dead agent is left out" "EndedBBB"
if [ "$(grep -c AbCd1234 "$tmp/curl-calls")" = 1 ]; then pass "one Trello read per card per refresh"; else fail "one Trello read per card" "$(cat "$tmp/curl-calls")"; fi

rm -f "$tmp/curl-calls"
out=$("$bin/agents-status.sh" 2>/dev/null)
if ! grep -q AbCd1234 "$tmp/curl-calls" 2>/dev/null; then pass "a second run inside the TTL reads the cache"; else fail "cache" "$(cat "$tmp/curl-calls")"; fi
out=$(AGENTS_STATUS_NOW=$(($(date +%s) + 100)) "$bin/agents-status.sh" 2>/dev/null)
if grep -q AbCd1234 "$tmp/curl-calls" 2>/dev/null; then pass "a run after the TTL reads Trello again"; else fail "cache expiry" "no new read"; fi

out=$("$bin/agents-status.sh" --statusline 2>/dev/null)
has "status line: count and the card manager's step" "4 agents · NoSuch99 read card 1/6 · AbCd1234 function test 5/6"
out=$("$bin/agents-status.sh" --bogus 2>&1); rc=$?
[ "$rc" = 2 ] && pass "usage error exits 2" || fail "usage error" "rc=$rc"

rm -f "$tmp"/tr/sess/subagents/*
out=$("$bin/agents-status.sh" --statusline 2>/dev/null)
has "status line with no agents" "0 agents"
out=$("$bin/agents-status.sh" 2>/dev/null)
has "table with no agents" "No live board agents."

echo
if [ "$failures" -eq 0 ]; then echo "All cases passed"; exit 0; fi
echo "$failures case(s) failed"; exit 1
