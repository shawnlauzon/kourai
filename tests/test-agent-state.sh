#!/usr/bin/env bash
# Tests agent-state.sh with fake transcripts: no network, no real agents.
#
# Usage: .claude/bin/test-agent-state.sh
#
# Covers the API-error death and the stale-waiting death
# (https://trello.com/c/TuxG4qvA), that live agents stay alive, the live check of
# background commands, handed-off board watchers, that only a stopped parent takes
# its children with it, the per-card owner guard (https://trello.com/c/Vfym22hq; lsof
# is faked, plus one check with the real lsof on a local file), and what the
# board watcher's label sync, stuck-card check and context ceiling read: the
# card of a merger (and other roles not started for one card) found from its
# newest Trello calls, and the request count and context size of an agent's
# latest request. aws, tailscale and ssh fail at once on PATH. Exits 0 when
# every case passes, 1 otherwise.
#
# Checks read output through a here-string (grep -q -- <pattern> <<<"$out"), never
# a pipe into grep -q: grep -q exits at its first match, the writer then gets a
# broken pipe, and pipefail turns a match into a failure (https://trello.com/c/KlkoQ52e).
set -uo pipefail
export KOURAI_CONFIG=${KOURAI_CONFIG:-$(cd "$(dirname "$0")" && pwd)/fixtures/config.toml}
export KOURAI_BIN=${KOURAI_BIN:-$(cd "$(dirname "$0")/../bin" && pwd)}

bin=$(cd "$(dirname "$0")/../bin" && pwd)
tmp=$(mktemp -d)
# shellcheck disable=SC2329 # called by the EXIT trap
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

mkdir -p "$tmp/nonet" "$tmp/tr/sess/subagents"
for c in aws tailscale ssh gh curl; do
  printf '#!/usr/bin/env bash\necho "test: %s is not allowed in tests" >&2\nexit 99\n' "$c" >"$tmp/nonet/$c"
  chmod +x "$tmp/nonet/$c"
done
export PATH="$tmp/nonet:$PATH"
NOW=2000000000
export AGENT_TRANSCRIPTS_DIR=$tmp/tr AGENT_STATE_NOW=$NOW
# The cases below that leave a call open for hours are about other rules; the hung-call rule is
# switched off for them (a huge limit) and tested in section 11 with its default.
export AGENT_STATE_TOOL_MAX=999999999
# a fake lsof: the files listed in $tmp/open.txt are held open by a process
: >"$tmp/open.txt"
cat >"$tmp/fake-lsof" <<FAKE
#!/usr/bin/env bash
while [ \$# -gt 0 ] && [ "\$1" != "--" ]; do shift; done
shift
for f in "\$@"; do
  if grep -qxF -- "\$f" "$tmp/open.txt"; then printf 'p1\nf1\nn%s\n' "\$f"; fi
done
exit 1
FAKE
chmod +x "$tmp/fake-lsof"
export AGENT_STATE_LSOF=$tmp/fake-lsof

failures=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; failures=$((failures + 1)); }
line() { printf '%s\n' "$out" | grep -F "id=$1 " || true; }
is() { # <case> <agent id> <state> [detail substring]
  local l; l=$(line "$2")
  case "$l" in
    "$3 "*) ;; *) fail "$1" "expected state $3, got: ${l:-<no line>}"; return ;;
  esac
  if [ -n "${4:-}" ] && ! grep -qF -- "$4" <<<"$l"; then fail "$1" "missing '$4' in: $l"; return; fi
  pass "$1"
}

iso() { python3 -I -c "import datetime,sys; print(datetime.datetime.fromtimestamp($NOW-$1, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z'))"; }

has() { if grep -qE -- "$2" <<<"$out"; then pass "$1"; else fail "$1" "missing /$2/ in: $out"; fi; }
hasnt() { if grep -qE -- "$2" <<<"$out"; then fail "$1" "found /$2/ in: $out"; else pass "$1"; fi; }

# The helpers are not fooled by a reader that stops early: 200 KB after the match,
# SIGPIPE ignored as in the agents' shells. The inner PASS/FAIL lines and failure
# count stay in the captured subshell; only the captured text is judged.
inner=$( (trap '' PIPE; out="MATCH"$'\n'"$(head -c 200000 /dev/zero | tr '\0' x)"; has inner 'MATCH'; hasnt inner 'MATCH') 2>"$tmp/pipe.err")
if [ "$(grep -c '^PASS inner' <<<"$inner")" = 1 ] && [ "$(grep -c '^FAIL inner' <<<"$inner")" = 1 ] && [ ! -s "$tmp/pipe.err" ]; then
  pass "the helpers are not fooled by a reader that stops early"
else
  fail "the helpers are not fooled by a reader that stops early" "inner: $(cut -c1-80 <<<"$inner") stderr: $(cat "$tmp/pipe.err")"
fi

# write_agent <id> <type> <events...>: each event is a JSON line; the file is aged 10 seconds.
write_agent() {
  local id=$1 type=$2 f
  shift 2
  f=$tmp/tr/sess/subagents/agent-$id
  echo "{\"agentType\":\"$type\",\"parentAgentId\":null}" >"$f.meta.json"
  printf '%s\n' "$@" >"$f.jsonl"
  python3 -I -c "import os,sys; os.utime(sys.argv[1], (2000000000-10,)*2)" "$f.jsonl"
}
T=2026-10-15T10:00:00.000Z
user() { printf '{"type":"user","timestamp":"%s","message":{"content":"%s"}}' "$T" "$1"; }
# call <tool name> <input JSON> <usage in> <usage cached> <message id>
call() { printf '{"type":"assistant","timestamp":"%s","message":{"id":"%s","usage":{"input_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":0,"output_tokens":5},"content":[{"type":"tool_use","id":"u%s","name":"%s","input":%s}]}}' "$T" "$5" "$3" "$4" "$5" "$1" "$2"; }
result() { python3 -I -c "import json,sys; print(json.dumps({'type':'user','timestamp':sys.argv[1],'message':{'content':[{'type':'tool_result','tool_use_id':sys.argv[2],'content':[{'type':'text','text':sys.argv[3]}]}]}}))" "$T" "$1" "$2"; }

# agent <id> <type> <seconds since its last write> <ending>
# endings: error (synthetic API error message), text (plain end of turn), tool (open Bash call),
#          resumed (an API error followed by a normal turn), bg (a background command, never finished),
#          handback
agent() {
  local id=$1 type=$2 age=$3 ending=$4 t f
  f=$tmp/tr/sess/subagents/agent-$id
  t=$(iso "$age")
  echo "{\"agentType\":\"$type\",\"parentAgentId\":null}" >"$f.meta.json"
  {
    printf '{"type":"user","timestamp":"%s","message":{"content":"Work https://trello.com/c/AbCd1234 please"}}\n' "$t"
    case "$ending" in
      error|resumed)
        printf '{"type":"assistant","timestamp":"%s","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"Autocompact is thrashing: the context refilled to the limit within a few turns"}]}}\n' "$t" ;;
    esac
    case "$ending" in
      limit|limit-undated)
        # a usage limit (card NzbZtBDt): Claude Code marks the synthetic message isApiErrorMessage
        if [ "$ending" = limit ]; then lt="You've hit your weekly limit · resets Oct 19 at 7am (America/Chicago)"; else lt="You've hit your session limit · resets 7am (America/Chicago)"; fi
        printf '{"type":"assistant","timestamp":"%s","isApiErrorMessage":true,"message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"%s"}]}}\n' "$t" "$lt" ;;
    esac
    case "$ending" in
      resumed)
        printf '{"type":"user","timestamp":"%s","message":{"content":"carry on"}}\n' "$t"
        printf '{"type":"assistant","timestamp":"%s","message":{"model":"claude-x","role":"assistant","content":[{"type":"text","text":"Back."}]}}\n' "$t" ;;
      text) printf '{"type":"assistant","timestamp":"%s","message":{"model":"claude-x","role":"assistant","content":[{"type":"text","text":"Waiting."}]}}\n' "$t" ;;
      tool) printf '{"type":"assistant","timestamp":"%s","message":{"model":"claude-x","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"sleep 9"}}]}}\n' "$t" ;;
      bg)
        printf '{"type":"assistant","timestamp":"%s","message":{"model":"claude-x","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"run","run_in_background":true}}]}}\n' "$t"
        printf '{"type":"user","timestamp":"%s","toolUseResult":{"backgroundTaskId":"bg1"},"message":{"content":[{"type":"tool_result","tool_use_id":"t1"}]}}\n' "$t"
        printf '{"type":"assistant","timestamp":"%s","message":{"model":"claude-x","role":"assistant","content":[{"type":"text","text":"Started."}]}}\n' "$t" ;;
      handback) printf '{"type":"assistant","timestamp":"%s","message":{"model":"claude-x","role":"assistant","content":[{"type":"tool_use","id":"t9","name":"SubagentHandback","input":{}}]}}\n' "$t" ;;
    esac
  } >"$f.jsonl"
  python3 -I -c "import os,sys; os.utime(sys.argv[1], ($NOW-$age,)*2)" "$f.jsonl"
}

agent err1 promoter 200 error         # died on the API error 200 seconds ago
agent err3 promoter 30 error          # API error 30 seconds ago: Claude Code may still retry
agent err2 merger 7200 error          # died two hours ago
agent lim1 workflow-builder 7200 limit          # died on a dated usage limit
agent lim2 workflow-builder 7200 limit-undated  # died on an undated usage limit
agent res1 promoter 60 resumed        # API error, then resumed and writing
agent stale1 card-manager 3000 text   # ended its turn 50 minutes ago, nothing can wake it
agent fresh1 card-manager 300 text    # ended its turn 5 minutes ago: may be waiting on a message
agent tool1 promoter 300 tool         # a command opened 5 minutes ago
agent bg1 mobile-builder 3000 bg      # a background command is running
agent done1 merger 3000 handback

out=$("$bin/agent-state.sh" --all 2>"$tmp/err"); rc=$?
[ "$rc" = 0 ] && pass "exit 0" || fail "exit 0" "rc=$rc: $(cat "$tmp/err")"
is "API error past the grace time: dead, with the reason" err1 dead "died_on_an_API_error:_Autocompact_is_thrashing"
is "API error 30 seconds ago: unknown, not dead (a retry may follow)" err3 unknown
is "API error two hours ago: dead" err2 dead "Autocompact_is_thrashing"
is "an API error followed by a normal turn is not dead" res1 waiting
is "a dated usage limit: dead, with the reset time for board-wait.py" lim1 dead "limit_reset=Oct_19_at_7am_(America/Chicago)"
is "an undated usage limit: dead, with the reset time" lim2 dead "limit_reset=7am_(America/Chicago)"
is "an API error that is no usage limit has no reset time" err2 dead
hasnt "an API error that is no usage limit has no limit_reset=" 'id=err2 .*limit_reset='
is "no write for 50 minutes, nothing to wake it: dead" stale1 dead "no_write_for_50_minutes"
is "no write for 5 minutes: still waiting" fresh1 waiting
is "an open tool call inside the limit: running, not dead" tool1 running
is "a running background command: waiting, not dead" bg1 waiting "background_task_bg1_still_running"
is "a delivered report: reported" done1 reported
if grep -q -- ' children=0 ' <<<"$(line err1)"; then pass "a dead line says children=0"; else fail "children=0" "$(line err1)"; fi

out=$(AGENT_STATE_STALE=7200 "$bin/agent-state.sh" --all 2>/dev/null)
is "AGENT_STATE_STALE raises the stale time" stale1 waiting

# a parent that waits on a live child stays alive; once the child is dead, so is the parent
agent par1 card-manager 3000 text
agent kid1 mobile-builder 100 tool
echo '{"agentType":"mobile-builder","parentAgentId":"par1"}' >"$tmp/tr/sess/subagents/agent-kid1.meta.json"
out=$("$bin/agent-state.sh" --all 2>/dev/null)
is "a parent with a live child agent: waiting" par1 waiting
agent kid1 mobile-builder 200 error
echo '{"agentType":"mobile-builder","parentAgentId":"par1"}' >"$tmp/tr/sess/subagents/agent-kid1.meta.json"
out=$("$bin/agent-state.sh" --all 2>/dev/null)
is "its child died on an API error: the child is dead" kid1 dead
is "and then the parent is dead too" par1 dead "no_write_for_50_minutes"

# 1. A merger shows the card of its newest Trello call (a card link).
write_agent m1 merger "$(user 'Run once, following your instructions.')" \
  "$(call mcp__trello__trelloReadCard '{"action":"get","cardIdOrUrl":"https://trello.com/c/AaAaAaA1"}' 10 100 m1)" \
  "$(call mcp__trello__trelloWriteCard '{"action":"attach_label","cardId":"ari:cloud:trello::card/workspace/w1/0123456789abcdef01234567"}' 10 200 m2)" \
  "$(result um2 '{"id":"ari:cloud:trello::card/workspace/w1/0123456789abcdef01234567","name":"X","webUrl":"https://trello.com/c/BbBbBbB2/9-x"}')" \
  "$(call mcp__trello__trelloReadCard '{"action":"get","cardIdOrUrl":"https://trello.com/c/CcCcCcC3"}' 10 300 m3)"
out=$("$bin/agent-state.sh")
has "merger: the card of its newest Trello call" '^(running|waiting|unknown) merger card=CcCcCcC3 '
has "context: the latest request's input plus cached tokens" 'ctx=310 '
has "context: three requests" 'reqs=3 '

# 2. A newest call that names a card only by id is mapped by an earlier answer in the transcript.
write_agent m2 merger "$(user 'Run once.')" \
  "$(call mcp__trello__trelloReadCard '{"action":"get","cardIdOrUrl":"https://trello.com/c/DdDdDdD4"}' 1 1 a1)" \
  "$(result ua1 '{"cards":{"nodes":[{"id":"ari:cloud:trello::card/workspace/w1/aaaaaaaaaaaaaaaaaaaaaaaa","name":"Y","webUrl":"https://trello.com/c/DdDdDdD4/1-y"}]}}')" \
  "$(call mcp__trello__trelloWriteCard '{"action":"move","cardId":"ari:cloud:trello::card/workspace/w1/aaaaaaaaaaaaaaaaaaaaaaaa","listId":"x"}' 1 1 a2)"
out=$("$bin/agent-state.sh" --all)
has "merger: a card named only by id is mapped through an earlier answer" 'merger card=DdDdDdD4 id=m2 '

# 3. A command that reads the card (card-summary.sh <short link>) counts too.
write_agent wb1 workflow-builder "$(user 'Build.')" \
  "$(call Bash '{"command":"/x/.claude/bin/card-summary.sh EeEeEeE5"}' 1 1 b1)"
out=$("$bin/agent-state.sh")
has "workflow builder: a card-summary.sh call names its card" 'workflow-builder card=EeEeEeE5 '

# 3b. A workflow builder started for a card (one per card) keeps that card while it reads linked cards.
write_agent wb2 workflow-builder "$(user 'Work these cards, following your instructions: X https://trello.com/c/HhHhHhH8. Report when done.')" \
  "$(call mcp__trello__trelloReadCard '{"action":"get","cardIdOrUrl":"https://trello.com/c/JjJjJjJ9"}' 1 1 b2)"
out=$("$bin/agent-state.sh" --all)
has "workflow builder: the card of its prompt, not of a later call" 'workflow-builder card=HhHhHhH8 id=wb2 '
hasnt "workflow builder: one card, no cards= list" 'id=wb2 .*cards='

# 3c. A workflow builder given a batch of related cards: every card on its prompt's Cards: line is its,
# a card the prompt only mentions elsewhere is not, and a filter by any batch card finds it.
write_agent wb3 workflow-builder "$(user 'Work these cards, following your instructions.\nCards: \"[AGENTS] A\" https://trello.com/c/KkKkKkK1, \"[AGENTS] B\" https://trello.com/c/LlLlLlL2\nSee also https://trello.com/c/MmMmMmM3 for background.\nReport when done.')" \
  "$(call mcp__trello__trelloReadCard '{"action":"get","cardIdOrUrl":"https://trello.com/c/MmMmMmM3"}' 1 1 b3)"
out=$("$bin/agent-state.sh" --all)
has "workflow builder batch: card= is the first card of its Cards: line, cards= lists the batch" 'workflow-builder card=KkKkKkK1 id=wb3 .* cards=KkKkKkK1,LlLlLlL2 '
hasnt "workflow builder batch: a card the prompt only mentions is not in the batch" 'id=wb3 .*MmMmMmM3,|cards=[^ ]*MmMmMmM3'
out=$("$bin/agent-state.sh" LlLlLlL2)
has "workflow builder batch: a filter by its second card finds it" 'workflow-builder card=KkKkKkK1 id=wb3 '

# 3d. A workflow verifier started on a card's plan or PR keeps that card while it reads other cards and plans
# for overlap (https://trello.com/c/5UYHCtaZ); the weekly drift check names no card and stays floating.
write_agent wv1 workflow-verifier "$(user 'Review the plan of X (https://trello.com/c/VvVvVvV1).')" \
  "$(call mcp__trello__trelloReadCard '{"action":"get","cardIdOrUrl":"https://trello.com/c/WwWwWwW2"}' 1 1 v1)"
write_agent wv2 workflow-verifier "$(user 'Weekly drift check.')" \
  "$(call mcp__trello__trelloReadCard '{"action":"get","cardIdOrUrl":"https://trello.com/c/XxXxXxX3"}' 1 1 v2)"
out=$("$bin/agent-state.sh" --all)
has "workflow verifier: the card of its prompt, not of a later call" 'workflow-verifier card=VvVvVvV1 id=wv1 '
has "workflow verifier: the drift check (no card in its prompt) shows its newest call's card" 'workflow-verifier card=XxXxXxX3 id=wv2 '
out=$("$bin/agent-state.sh" VvVvVvV1)
has "workflow verifier: a filter by its prompt's card finds it" 'workflow-verifier card=VvVvVvV1 id=wv1 '
out=$("$bin/agent-state.sh" WwWwWwW2)
hasnt "workflow verifier: a card it only read is not its card" 'id=wv1 '

# 4. A card agent keeps the card of its prompt; a merger that touched no card shows -.
write_agent cm1 card-manager "$(user 'Manage card X (https://trello.com/c/FfFfFfF6) in TESTING.')" \
  "$(call mcp__trello__trelloReadCard '{"action":"get","cardIdOrUrl":"https://trello.com/c/GgGgGgG7"}' 1 1 c1)"
write_agent m3 merger "$(user 'Run once.')" "$(call Bash '{"command":"git status"}' 1 1 d1)"
out=$("$bin/agent-state.sh" --all)
has "card manager: the card of its prompt, not of a later call" 'card-manager card=FfFfFfF6 '
has "merger: no card touched yet is -" 'merger card=- id=m3 '

# 4b. The row says where the card came from and when the agent started (https://trello.com/c/Yi1kj6ge): board-wait.sh
# labels a floating role's card only when the card is not just its newest call.
out=$("$bin/agent-state.sh" --all)
has "row: a card from the prompt says card_from=prompt" 'workflow-verifier card=VvVvVvV1 id=wv1 .* card_from=prompt '
has "row: a card from the newest call says card_from=call" 'workflow-verifier card=XxXxXxX3 id=wv2 .* card_from=call '
has "row: a merger that touched no card says card_from=-" 'merger card=- id=m3 .* card_from=- '
has "row: start= is the first entry's time in epoch seconds, before card_from=" 'merger card=- id=m3 .* start=[0-9]{10} card_from='
has "row: start= and card_from= come after ctx= and before the transcript" 'ctx=[0-9]+ start=[0-9]+ card_from=[a-z-]+ .*agent-m3\.jsonl$'

# 5. The new fields do not move the old ones: the line still ends with the transcript path.
out=$("$bin/agent-state.sh" --all)
has "format: children, reqs and ctx come before the transcript" 'children=[0-9]+ reqs=[0-9]+ ctx=[0-9]+ .*agent-m1\.jsonl$'

# 6. A finished agent is reported whatever its leftover background tasks say.
# 6a. The report is in the same transcript, after a background task that never notified.
f=$tmp/tr/sess/subagents/agent-rep1
echo '{"agentType":"promoter","parentAgentId":null}' >"$f.meta.json"
{
  printf '{"type":"user","timestamp":"%s","message":{"content":"Run https://trello.com/c/AbCd1234"}}\n' "$(iso 3000)"
  printf '{"type":"assistant","timestamp":"%s","message":{"model":"claude-x","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"run","run_in_background":true}}]}}\n' "$(iso 3000)"
  printf '{"type":"user","timestamp":"%s","toolUseResult":{"backgroundTaskId":"bgx"},"message":{"content":[{"type":"tool_result","tool_use_id":"t1"}]}}\n' "$(iso 3000)"
  printf '{"type":"assistant","timestamp":"%s","message":{"model":"claude-x","content":[{"type":"tool_use","id":"t9","name":"SubagentHandback","input":{}}]}}\n' "$(iso 2990)"
} >"$f.jsonl"
python3 -I -c "import os,sys; os.utime(sys.argv[1], ($NOW-2990,)*2)" "$f.jsonl"
# 6b. The agent was resumed from a later session folder: the meta file and the early entries (a
# background task never notified) are in one folder, its report is in the other folder's file.
mkdir -p "$tmp/tr/sess2/subagents"
f=$tmp/tr/sess/subagents/agent-rep2
echo '{"agentType":"promoter","parentAgentId":null}' >"$f.meta.json"
{
  printf '{"type":"user","timestamp":"%s","message":{"content":"Run https://trello.com/c/AbCd1234"}}\n' "$(iso 5000)"
  printf '{"type":"assistant","timestamp":"%s","message":{"model":"claude-x","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"run","run_in_background":true}}]}}\n' "$(iso 5000)"
  printf '{"type":"user","timestamp":"%s","toolUseResult":{"backgroundTaskId":"bgy"},"message":{"content":[{"type":"tool_result","tool_use_id":"t1"}]}}\n' "$(iso 5000)"
} >"$f.jsonl"
python3 -I -c "import os,sys; os.utime(sys.argv[1], ($NOW-4000,)*2)" "$f.jsonl"
f2=$tmp/tr/sess2/subagents/agent-rep2.jsonl
{
  printf '{"type":"assistant","timestamp":"%s","message":{"model":"claude-x","content":[{"type":"tool_use","id":"t9","name":"SubagentHandback","input":{}}]}}\n' "$(iso 3500)"
} >"$f2"
python3 -I -c "import os,sys; os.utime(sys.argv[1], ($NOW-3500,)*2)" "$f2"
out=$("$bin/agent-state.sh" --all)
is "a report after a background task that never notified: reported" rep1 reported
is "a report in another session folder of the same agent: reported" rep2 reported
if [ "$(printf '%s\n' "$out" | grep -c 'id=rep2 ')" = 1 ]; then pass "the agent is listed once, not once per folder"; else fail "listed once" "$out"; fi


# --- https://trello.com/c/Vfym22hq: handed-off watchers, live background checks, the owner guard ---
# tx <id> <type> <parent or -> <event>...: a transcript in its own session folder. Each event is
# "<seconds ago>|<kind>|<payload>": prompt (the agent's prompt), bash (an open Bash call; payload the
# command), done (the result of the newest open call), bg (a background command; payload
# "<task id> <output file>"), notify (a task notification; payload the task id), handback (payload the
# report), open (a tool call of that name left open), call (a tool call and its result; payload the tool name), text, interrupt (the string form), rejected (the rejected result of the newest open call) and
# interruptl (the list-form marker Claude Code writes when an agent is stopped). The file's
# mtime is the age of its last event.
cat >"$tmp/tx.py" <<'PY'
import json, os, sys, datetime
root, now, aid, typ, parent = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
folder = os.environ.get("TX_FOLDER", "s-" + aid)
d = os.path.join(root, folder, "subagents")
os.makedirs(d, exist_ok=True)
meta = {"agentType": os.environ.get("TX_META_TYPE", typ)}
if parent != "-":
    meta["parentAgentId"] = parent
json.dump(meta, open(os.path.join(d, "agent-%s.meta.json" % aid), "w"))
out, n, open_ids, last = [], 0, [], None
def iso(age):
    return datetime.datetime.fromtimestamp(now - age, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
def use(t, name, inp):
    global n
    n += 1
    uid = "%s-u%d" % (aid, n)
    out.append({"type": "assistant", "timestamp": t, "message": {"id": uid, "model": "claude-x", "content": [
        {"type": "tool_use", "id": uid, "name": name, "input": inp}]}})
    return uid
def result(t, uid, text, tur=None):
    e = {"type": "user", "timestamp": t, "message": {"content": [{"type": "tool_result", "tool_use_id": uid, "content": text}]}}
    if tur:
        e["toolUseResult"] = tur
    out.append(e)
for ev in sys.argv[6:]:
    age, kind, payload = ev.split("|", 2)
    last = int(age)
    t = iso(last)
    if kind == "prompt":
        out.append({"type": "user", "timestamp": t, "message": {"content": payload}})
    elif kind == "bash":
        open_ids.append(use(t, "Bash", {"command": payload}))
    elif kind == "done":
        result(t, open_ids.pop(), "ok")
    elif kind == "bg":
        task, path = payload.split(" ", 1)
        uid = use(t, "Bash", {"command": "long run", "run_in_background": True})
        result(t, uid, "Command running in background with ID: %s. Output is being written to: %s. You will be notified when it completes." % (task, path),
               {"backgroundTaskId": task})
    elif kind == "notify":
        out.append({"type": "user", "timestamp": t, "message": {"content": "<task-notification><task-id>%s</task-id><status>completed</status></task-notification>" % payload}})
    elif kind == "handback":
        result(t, use(t, "SubagentHandback", {"message": payload}), "delivered")
    elif kind == "open":
        use(t, payload, {})
    elif kind == "call":
        result(t, use(t, payload, {}), "ok")
    elif kind == "text":
        out.append({"type": "assistant", "timestamp": t, "message": {"model": "claude-x", "content": [{"type": "text", "text": payload}]}})
    elif kind == "rejected":
        result(t, open_ids.pop(), "The user doesn't want to proceed with this tool use. The tool use was rejected.")
    elif kind == "interruptl":
        out.append({"type": "user", "timestamp": t, "message": {"content": [{"type": "text", "text": "[Request interrupted by user for tool use]"}]}})
    elif kind == "interrupt":
        out.append({"type": "user", "timestamp": t, "message": {"content": "[Request interrupted by user]"}})
f = os.path.join(d, "agent-%s.jsonl" % aid)
open(f, "w").write("".join(json.dumps(e) + "\n" for e in out))
os.utime(f, (now - last, now - last))
PY
rm -rf "$tmp/tr"; mkdir -p "$tmp/tr"
tx() { python3 -I "$tmp/tx.py" "$tmp/tr" "$NOW" "$@"; }
# outfile <name> <seconds since its last write>: a background command's output file
outfile() { local f; f=$(python3 -I -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$tmp")/$1.output; : >"$f"
  python3 -I -c "import os,sys; os.utime(sys.argv[1], ($NOW-int(sys.argv[2]),)*2)" "$f" "$2"; printf '%s' "$f"; }
CM='Manage card X (https://trello.com/c/Card0001) in TESTING. Test server: test-server-3.'

# 7. Background commands are checked live.
gone=$(outfile gone 3000); held=$(outfile held 3000); fresh=$(outfile fresh 30)
printf '%s\n' "$held" >"$tmp/open.txt"
tx mg1 merger - "4000|prompt|Run once." "3990|bg|bgone $gone" "3980|text|Waiting."
tx mg2 merger - "4000|prompt|Run once." "3990|bg|bheld $held" "3980|text|Waiting."
tx mg3 merger - "4000|prompt|Run once." "3990|bg|bfresh $fresh" "3980|text|Waiting."
tx mg4 merger - "4000|prompt|Run once." "3990|bg|bnofile $tmp/missing.output" "3980|text|Waiting."
out=$("$bin/agent-state.sh" --all 2>"$tmp/err")
is "a background command whose output no process holds is gone: the stopped merger is dead" mg1 dead "background_task_bgone_gone"
hasnt "a gone background command is not 'still running'" 'id=mg1 .*still_running'
is "a background command whose output a process holds: still running" mg2 waiting "background_task_bheld_still_running"
is "an output written within the grace time: it just ended, its notice is on the way" mg3 waiting "background_task_bfresh_still_running"
is "an output file that no longer exists: gone" mg4 dead "background_task_bnofile_gone"
out=$(AGENT_STATE_LSOF=/nonexistent/lsof "$bin/agent-state.sh" --all 2>"$tmp/err")
is "lsof cannot run: background commands count as running, as before" mg1 waiting "background_task_bgone_still_running"
if grep -q "cannot check background commands" "$tmp/err"; then pass "lsof cannot run: said on stderr"; else fail "lsof stderr" "$(cat "$tmp/err")"; fi
# the real lsof, on a local file a real process holds
real=$(outfile real 3000)
sleep 60 >>"$real" &
holder=$!
tx mg5 merger - "4000|prompt|Run once." "3990|bg|breal $real" "3980|text|Waiting."
out=$(AGENT_STATE_LSOF=lsof "$bin/agent-state.sh" --all 2>/dev/null)
is "real lsof: a file a live process holds keeps its command running" mg5 waiting "background_task_breal_still_running"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
out=$(AGENT_STATE_LSOF=lsof "$bin/agent-state.sh" --all 2>/dev/null)
is "real lsof: once the process is gone, so is the command" mg5 dead "background_task_breal_gone"
rm -rf "$tmp/tr"; mkdir -p "$tmp/tr"; : >"$tmp/open.txt"

# 8. A handed-off board watcher (the 2026-10-17 case) and its card managers.
tx w1 board-watcher - "9000|prompt|Run the board loop." "8000|call|Agent" "4000|handback|HANDOFF: restart me" \
  "1500|call|ToolSearch" "1490|call|SendMessage" "1480|text|Relayed."
tx w2 board-watcher - "3900|prompt|Run the board loop. HANDOFF note." "100|bash|board-wait.sh"
# the old watcher's card manager: its turn ended 40 minutes ago, its feature tester still runs
tx cmA card-manager w1 "7000|prompt|$CM" "6900|call|Agent" "2400|text|Waiting for the feature tester."
tx ftA feature-tester cmA "6800|prompt|BEFORE run of https://trello.com/c/Card0001" "60|bash|tool/ui_test_all.sh"
# another card manager of the old watcher, writing nothing for 30 minutes with no child: dead by the stale rule only
tx cmB card-manager w1 "7000|prompt|Manage card Y (https://trello.com/c/Card0002) in BUILDING." "1800|text|Done for now."
out=$("$bin/agent-state.sh" --all)
is "a watcher that wrote HANDOFF: and is not the newest: handed-off" w1 handed-off "handed_off_at"
hasnt "relaying (ToolSearch, SendMessage) is not acting" 'id=w1 .*acted_after_handoff'
is "the newest watcher is current" w2 current
is "a card manager of the handed-off watcher, waiting on a live feature tester, is not dead" cmA waiting
hasnt "and not 'died with' the handed-off watcher" 'id=cmA .*died_with'
has "and it counts its live child" 'id=cmA last=[0-9]+s children=1 '
is "a card manager of the handed-off watcher with nothing to wake it: dead by the stale rule" cmB dead "no_write_for_30_minutes"
out=$("$bin/agent-state.sh" Card0001)
has "without --all, the live card manager of the card is listed" '^waiting card-manager card=Card0001 id=cmA '
# the old watcher acts after its handoff
tx w1 board-watcher - "9000|prompt|Run the board loop." "4000|handback|HANDOFF: restart me" \
  "1500|call|SendMessage" "1400|call|Agent" "1300|call|mcp__trello__trelloWriteCard" "1200|call|Agent"
out=$("$bin/agent-state.sh" --all)
is "a handed-off watcher that acted: its detail names each tool" w1 handed-off "acted_after_handoff:Agentx2,mcp__trello__trelloWriteCardx1"
# the newest watcher writes its HANDOFF: and no new one has started yet
tx w2 board-watcher - "3900|prompt|Run the board loop." "50|handback|HANDOFF: restart me"
out=$("$bin/agent-state.sh" --all)
is "the newest watcher after its HANDOFF: still current, says restart it" w2 current "handed_off_at"

# 9. Only a stopped parent takes its children with it.
tx p1 card-manager - "7000|prompt|$CM" "6900|call|Agent" "3000|interrupt|"
tx k1 mobile-builder p1 "6800|prompt|Build https://trello.com/c/Card0001" "3050|text|Working."
tx k2 mobile-builder p1 "6800|prompt|Build https://trello.com/c/Card0001" "2000|bash|flutter test"
tx p2 card-manager - "7000|prompt|$CM" "3000|handback|done"
tx k3 server-builder p2 "6800|prompt|Build https://trello.com/c/Card0001" "2990|bash|bin/rails test"
out=$("$bin/agent-state.sh" --all)
is "a child that wrote nothing after its parent was stopped: dead with it" k1 dead "died_with_card-manager_p1,_which_was_stopped_at"
is "a child that kept writing after its parent was stopped: outlived it" k2 running "outlived_p1"
is "a stopped parent with a live child is not dead" p1 unknown "but_a_child_agent_is_still_live"
is "a child of a parent that reported runs on: not 'died with'" k3 running
hasnt "a reported parent takes no child with it" 'id=k3 .*died_with'

# 10. A meta file in a later session folder that names another type does not hide the agent.
TX_FOLDER=s-a tx mm1 card-manager - "7000|prompt|$CM" "60|bash|sleep"
python3 -I - "$tmp/tr" <<'PY'
import json, os, sys
d = os.path.join(sys.argv[1], "s-z", "subagents"); os.makedirs(d)
json.dump({"agentType": "general-purpose", "finished": True}, open(os.path.join(d, "agent-mm1.meta.json"), "w"))
open(os.path.join(d, "agent-mm1.jsonl"), "w").write("")
os.utime(os.path.join(d, "agent-mm1.jsonl"), (2000000000 - 7000,) * 2)
PY
out=$("$bin/agent-state.sh" --all)
is "a later folder's general-purpose meta file: still the card manager" mm1 running
rm -rf "$tmp/tr"; mkdir -p "$tmp/tr"

# 11. The per-card owner guard.
tok() { "$bin/agent-state.sh" --token | sed 's/^TOKEN: //'; }
T1=$(tok); T2=$(tok)
case "$T1" in [0-9a-f]*) [ ${#T1} = 32 ] && pass "--token: 32 hex digits" || fail "--token" "$T1" ;; *) fail "--token" "$T1" ;; esac
[ "$T1" != "$T2" ] && pass "--token: a fresh token each call" || fail "--token fresh" "$T1 $T2"
owner() { out=$("$bin/agent-state.sh" --owner "$@" 2>&1); rc=$?; }
# the old card manager waits on a live feature tester; the new one (restarted in error) checks
tx cmOld card-manager wOld "7000|prompt|$CM" "6900|call|Agent" "2400|text|Waiting."
tx ftOld feature-tester cmOld "6800|prompt|BEFORE https://trello.com/c/Card0001" "60|bash|tool/ui_test_all.sh"
tx cmNew card-manager - "20|prompt|$CM restart" "10|bash|agent-state.sh --owner Card0001 card-manager $T1"
owner Card0001 card-manager "$T1"
[ "$rc" = 1 ] && pass "a second card manager on a card with a live one: exit 1" || fail "owner exit 1" "rc=$rc $out"
has "it is told to stand down, naming the holder and its transcript" '^STAND DOWN: card-manager cmOld \(waiting, started .*\) holds card Card0001: .*agent-cmOld\.jsonl$'
# the old card manager checks at its next step: it holds the card, the newer copy is named
tx cmOld card-manager wOld "7000|prompt|$CM" "6900|call|Agent" "2400|text|Waiting." "5|bash|agent-state.sh --owner Card0001 card-manager $T2"
owner Card0001 card-manager "$T2"
[ "$rc" = 0 ] && pass "the older live card manager holds the card: exit 0" || fail "owner older" "rc=$rc $out"
has "OWNER names it" '^OWNER: cmOld holds card-manager card Card0001$'
has "and the newer live copy, which stands down at its own check" '^NEWER: cmNew '
# the old one reported: the new one holds the card
tx cmOld card-manager wOld "7000|prompt|$CM" "3000|handback|HANDOFF: next step AFTER"
owner Card0001 card-manager "$T1"
[ "$rc" = 0 ] && has "an older copy that reported does not hold the card" '^OWNER: cmNew ' || fail "owner reported" "rc=$rc $out"
# the old one is dead (an API error, nothing resumed it) and its feature tester has reported
tx ftOld feature-tester cmOld "6800|prompt|BEFORE https://trello.com/c/Card0001" "3100|handback|done"
tx cmOld card-manager - "7000|prompt|$CM" "3000|text|Autocompact is thrashing: the context refilled"
python3 -I - "$tmp/tr/s-cmOld/subagents/agent-cmOld.jsonl" <<'PY'
import json, sys
p = sys.argv[1]; L = [json.loads(l) for l in open(p)]; L[-1]["message"]["model"] = "<synthetic>"
open(p, "w").write("".join(json.dumps(e) + "\n" for e in L))
import os; os.utime(p, (2000000000 - 3000,) * 2)
PY
owner Card0001 card-manager "$T1"
[ "$rc" = 0 ] && has "an older copy that is dead does not hold the card" '^OWNER: cmNew ' || fail "owner dead" "rc=$rc $out"
# another card's manager is no rival
tx cmOther card-manager - "7000|prompt|Manage card Z (https://trello.com/c/Card0009) in BUILDING." "60|bash|sleep"
owner Card0001 card-manager "$T1"
[ "$rc" = 0 ] && pass "a live card manager of another card is no rival" || fail "owner other card" "rc=$rc $out"
# a token no transcript carries, and one of the wrong type
owner Card0001 card-manager 0123456789abcdef0123456789abcdef
[ "$rc" = 2 ] && has "a token no transcript carries: ERROR, exit 2" '^ERROR: 0 transcripts carry the token' || fail "owner no token" "rc=$rc $out"
owner Card0001 workflow-builder "$T1"
[ "$rc" = 2 ] && has "the token of another agent type: ERROR" '^ERROR: the token is in the transcript of card-manager cmNew' || fail "owner type" "rc=$rc $out"
owner Card0001 card-manager short
[ "$rc" = 2 ] && has "a made-up short token: ERROR" '^ERROR: the token must be' || fail "owner short" "rc=$rc $out"
# a workflow builder's batch: a builder of another card of its batch holds that card too
tx wbOld workflow-builder - "7000|prompt|Work these cards.
Cards: \"A\" https://trello.com/c/Card0005, \"B\" https://trello.com/c/Card0006" "60|bash|git status"
tx wbNew workflow-builder - "20|prompt|Work these cards: \"B\" https://trello.com/c/Card0006" "10|bash|agent-state.sh --owner Card0006 workflow-builder $T2"
owner Card0006 workflow-builder "$T2"
[ "$rc" = 1 ] && has "a workflow builder whose card is in a live builder's batch stands down" '^STAND DOWN: workflow-builder wbOld ' || fail "owner batch" "rc=$rc $out"

# a notice that arrived while the agent was busy is written as a queued attachment, not a
# user entry: it still ends the background command (no lsof needed for it)
mkdir -p "$tmp/tr/sess/subagents"; f=$tmp/tr/sess/subagents/agent-qn1
echo '{"agentType":"workflow-builder","parentAgentId":null}' >"$f.meta.json"
{
  printf '{"type":"user","timestamp":"%s","message":{"content":"Work https://trello.com/c/Card0007"}}\n' "$(iso 400)"
  printf '{"type":"assistant","timestamp":"%s","message":{"model":"claude-x","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"poll","run_in_background":true}}]}}\n' "$(iso 400)"
  printf '{"type":"user","timestamp":"%s","toolUseResult":{"backgroundTaskId":"bqueued"},"message":{"content":[{"type":"tool_result","tool_use_id":"t1"}]}}\n' "$(iso 400)"
  printf '{"type":"attachment","timestamp":"%s","attachment":{"type":"queued_command","prompt":"<task-notification>\\n<task-id>bqueued</task-id>\\n<status>completed</status>\\n</task-notification>"}}\n' "$(iso 300)"
  printf '{"type":"assistant","timestamp":"%s","message":{"model":"claude-x","role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"sleep 9"}}]}}\n' "$(iso 300)"
} >"$f.jsonl"
python3 -I -c "import os,sys; os.utime(sys.argv[1], ($NOW-300,)*2)" "$f.jsonl"
out=$("$bin/agent-state.sh" --all 2>/dev/null)
l=$(line qn1)
case "$l" in
  *bqueued*) fail "a queued notice ends its background command" "$l" ;;
  "") fail "a queued notice ends its background command" "<no line>" ;;
  *) pass "a queued notice ends its background command" ;;
esac

# 10. A code reviewer is a board agent of its card (the card manager waits for it; the card has a live agent).
rm -rf "$tmp/tr"; mkdir -p "$tmp/tr"
tx cmR card-manager - "900|prompt|$CM" "800|call|Agent" "700|text|Waiting for the code reviewer."
tx crR code-reviewer cmR "600|prompt|Code review of example-org/example-app#9 on card https://trello.com/c/Card0009. Head: abc" "30|bash|code-review-wait.sh"
out=$("$bin/agent-state.sh" --all)
has "a code reviewer is listed as an agent of its card" 'code-reviewer card=Card0009 id=crR '

# 11. https://trello.com/c/u7rEBbGc: a foreground call open longer than any tool runs is hung.
rm -rf "$tmp/tr"; mkdir -p "$tmp/tr"
unset AGENT_STATE_TOOL_MAX
tx hg1 card-manager - "5000|prompt|$CM" "4000|bash|sleep 99999"          # open 66 minutes: orphaned
tx hg2 card-manager - "5000|prompt|$CM" "600|bash|sleep 500"             # open 10 minutes: inside the limit
tx hg3 card-manager - "50000|prompt|$CM" "20000|open|Agent"               # waits on a foreground child agent for hours
held9=$(outfile bg9 3000); printf '%s\n' "$held9" >"$tmp/open.txt"
tx hg4 card-manager - "5000|prompt|$CM" "4000|bash|sleep 99999" "3990|bg|bg9 $held9"
tx hg5 card-manager - "5000|prompt|$CM" "4000|bash|sleep 99999"
tx hgc test-builder hg5 "5000|prompt|Test aspect of https://trello.com/c/Card0001" "30|bash|work"
out=$(AGENT_STATE_HOURS=48 "$bin/agent-state.sh" --all 2>"$tmp/err")
is "a foreground call open for 66 minutes: dead, not running until the 24-hour window" hg1 dead "tool_call_open_for_66_minutes"
is "a foreground call open for 10 minutes: still running" hg2 running
is "a long call to a child agent never counts as hung" hg3 running
has "a hung call with a live background command: not dead" 'id=hg4 '
hasnt "a live background command keeps it from the hung rule" 'dead card-manager card=Card0001 id=hg4 '
hasnt "a hung call with a live child agent is not dead (unknown)" 'dead card-manager card=Card0001 id=hg5 '
is "a hung call with a live child agent: unknown" hg5 unknown
# parallel queued calls: the oldest open past the limit, but a result was written 30 s ago
tx hg6 test-builder - "5000|prompt|Test aspect of https://trello.com/c/Card0001" "4000|bash|run 1" "3990|bash|run 2" "3980|bash|run 3" "30|text|result of call 1"
out=$(AGENT_STATE_TOOL_MAX=3600 "$bin/agent-state.sh" --all 2>/dev/null)
hasnt "parallel queued calls past the limit with a recent write: not dead" 'dead test-builder card=Card0001 id=hg6 '
is "parallel queued calls past the limit with a recent write: running" hg6 running
is "the same calls with a quiet transcript are dead" hg1 dead "tool_call_open_for_66_minutes_and_quiet"
tx hg7 card-manager - "50000|prompt|$CM" "20000|open|Monitor"
out=$(AGENT_STATE_TOOL_MAX=3600 "$bin/agent-state.sh" --all 2>/dev/null)
is "a Monitor call open for hours never counts as hung" hg7 running
out=$(AGENT_STATE_TOOL_MAX=7200 "$bin/agent-state.sh" --all 2>/dev/null)
is "AGENT_STATE_TOOL_MAX raises the limit" hg1 running
# 12. An agent stopped on its own marker is dead at once (https://trello.com/c/zcXgCnUq); the real
# sequence is an open call, its rejected result, then the list-form marker. A parent's stop and a
# resume after the marker keep their rules.
tx st1 card-manager - "400|prompt|$CM" "300|bash|sleep 600" "9|rejected|" "8|interruptl|" "7|interruptl|"
tx st2 card-manager - "400|prompt|$CM" "20|text|Working." "5|interrupt|"
tx st3 card-manager - "400|prompt|$CM" "300|bash|sleep 600" "30|rejected|" "29|interruptl|" "10|text|Resumed by SendMessage."
tx st4 card-manager - "400|prompt|$CM" "300|bash|sleep 600" "30|rejected|" "29|interruptl|" "10|bash|flutter test"
tx stp card-manager - "7000|prompt|$CM" "6900|call|Agent" "3000|interrupt|"
tx stk mobile-builder stp "6800|prompt|Build https://trello.com/c/Card0001" "2000|bash|flutter test"
tx stm card-manager - "7000|prompt|$CM" "6900|call|Agent" "100|bash|sleep 600" "20|rejected|" "19|interruptl|"
tx stmc feature-tester stm "6800|prompt|BEFORE https://trello.com/c/Card0001" "100|bash|tool/ui_test_all.sh" "30|rejected|" "29|interruptl|"
out=$("$bin/agent-state.sh" --all)
is "stopped (rejected result, list-form marker), nothing after: dead at once" st1 dead "interrupted_at_"
has "its detail says nothing was written after the marker" 'id=st1 .*nothing_written_after_the_marker'
is "stopped (string-form marker), nothing after: dead at once" st2 dead "nothing_written_after_the_marker"
is "stopped, then resumed with a write after the marker: not dead" st3 unknown "but_it_wrote_10s_ago"
is "stopped, then a new call open after the marker: not dead" st4 unknown "but_a_tool_call_is_still_open"
is "a child that kept writing after its parent was stopped: still outlived" stk running "outlived_stp"
is "a manager whose only child was stopped on its own marker: dead at once" stm dead "nothing_written_after_the_marker"
is "its stopped child is dead" stmc dead "nothing_written_after_the_marker"
hasnt "the parent is not held by a child that is live" 'id=stm .*child agent is still live'
# --owner: the stopped holder does not hold the card
tx stOld card-manager - "400|prompt|Run https://trello.com/c/Card0077" "300|bash|sleep 600" "9|rejected|" "8|interruptl|"
T3=$(tok)
tx stNew card-manager - "20|prompt|Run https://trello.com/c/Card0077 restart" "10|bash|agent-state.sh --owner Card0077 card-manager $T3"
owner Card0077 card-manager "$T3"
[ "$rc" = 0 ] && has "a stopped card manager holds no card: the new one is the owner" '^OWNER: stNew holds card-manager card Card0077$' || fail "owner after stop" "rc=$rc $out"

# 12. The transcript cache (https://trello.com/c/jBWpQkvt): output identical, only appended bytes parsed.
rm -rf "$tmp/tr"; mkdir -p "$tmp/tr"
cfile() { printf '%s' "$tmp/tr/s-$1/subagents/agent-$1.jsonl"; }
append_handback() { # <agent id> <seconds ago>
  printf '{"type":"assistant","timestamp":"%s","message":{"id":"hb","content":[{"type":"tool_use","id":"hbu","name":"SubagentHandback","input":{"message":"done"}}]}}\n' "$(iso "$2")" >>"$(cfile "$1")"
  python3 -I -c "import os,sys; os.utime(sys.argv[1], ($NOW-int(sys.argv[2]),)*2)" "$(cfile "$1")" "$2"
}
export AGENT_STATE_CACHE=$tmp/cache1
rm -rf "$AGENT_STATE_CACHE"
tx ca1 card-manager - "9000|prompt|$CM" "8000|bash|sleep 1" "500|text|Waiting."
tx ca2 workflow-builder - "9000|prompt|Work https://trello.com/c/Card0002" "400|bash|agent-state.sh --owner Card0002 workflow-builder $T1"
big=$(printf 'x%.0s' $(seq 1 3000))
tx ca3 merger - "9000|prompt|Run once." "100|bash|echo $big"
cold=$(AGENT_STATE_CACHE= "$bin/agent-state.sh" --all 2>&1)
out=$("$bin/agent-state.sh" --all 2>&1)
[ "$out" = "$cold" ] && pass "a cold cache call prints what the call without a cache prints" || fail "cache cold" "$out"
warm=$("$bin/agent-state.sh" --all 2>&1)
[ "$warm" = "$cold" ] && pass "a warm cache call prints what the call without a cache prints" || fail "cache warm" "$warm"
[ -s "$AGENT_STATE_CACHE/ca3.pickle" ] && pass "the cache holds an entry per agent" || fail "cache entry" "$(ls "$AGENT_STATE_CACHE")"
# only the appended bytes are parsed
size=$(wc -c <"$(cfile ca3)")
AGENT_STATE_DEBUG_BYTES=1 "$bin/agent-state.sh" --all >/dev/null 2>"$tmp/dbg"
grep -qE 'parsed 0 bytes' "$tmp/dbg" && pass "a warm call with nothing appended parses no bytes" || fail "warm bytes" "$(cat "$tmp/dbg")"
append_handback ca1 5
AGENT_STATE_DEBUG_BYTES=1 "$bin/agent-state.sh" --all >"$tmp/o" 2>"$tmp/dbg"
n=$(sed -n 's/.*parsed \([0-9]*\) bytes.*/\1/p' "$tmp/dbg")
[ -n "$n" ] && [ "$n" -gt 0 ] && [ "$n" -lt $((size / 4)) ] && pass "a call after an append parses only the appended bytes ($n)" || fail "append bytes" "n=$n size=$size"
out=$(cat "$tmp/o"); is "an appended hand-back shows in the next call" ca1 reported
# an unterminated last line is not counted twice when it is completed later
printf '{"type":"assistant","timestamp":"%s","message":{"id":"half","usage":{"input_tokens":7,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[{"type":"text","t' "$(iso 4)" >>"$(cfile ca3)"
aged() { python3 -I -c "import os,sys; os.utime(sys.argv[1], ($NOW-10,)*2)" "$(cfile "$1")"; }
aged ca3; out=$("$bin/agent-state.sh" --all 2>&1); has "an unterminated line is left alone" 'id=ca3 .*reqs=0 '
printf 'ext":"x"}]}}\n' >>"$(cfile ca3)"; aged ca3
out=$("$bin/agent-state.sh" --all 2>&1); has "the completed line is parsed once it ends" 'id=ca3 .*reqs=1 '
# a corrupt cache file and a replaced transcript
printf 'garbage' >"$AGENT_STATE_CACHE/ca3.pickle"
out=$("$bin/agent-state.sh" --all 2>"$tmp/err"); has "a corrupt cache entry: full parse, right answer" 'id=ca3 .*reqs=1 '
grep -q "unusable" "$tmp/err" && pass "a corrupt cache entry is said on stderr" || fail "corrupt stderr" "$(cat "$tmp/err")"
tx ca3 merger - "9000|prompt|Run once, again." "100|text|x"
out=$("$bin/agent-state.sh" --all 2>&1); has "a replaced transcript: the cache is not used" 'id=ca3 .*reqs=0 '
# a cache entry written by another script text is a miss (a changed script may add keys): full parse, no crash
out=$("$bin/agent-state.sh" --all 2>&1)
python3 -I - "$AGENT_STATE_CACHE/ca1.pickle" <<'PY'
import pickle, sys
p = sys.argv[1]; c = pickle.load(open(p, "rb")); c["ver"] = "old"; del c["a"]["bash_tokens"]
pickle.dump(c, open(p, "wb"))
PY
out=$("$bin/agent-state.sh" --all 2>&1)
has "a cache entry of another script version: a miss, full parse, no crash" 'id=ca1 '
hasnt "and no traceback" 'Traceback|KeyError'
# the owner check is worked out on every call (two tokens, one warm cache)
TA=$(tok); TB=$(tok); TC=$(tok)
tx cb1 workflow-builder - "300|prompt|Work https://trello.com/c/Card0003" "60|bash|agent-state.sh --owner Card0003 workflow-builder $TA"
tx cb2 workflow-builder - "300|prompt|Work https://trello.com/c/Card0004" "50|bash|agent-state.sh --owner Card0004 workflow-builder $TB"
"$bin/agent-state.sh" --all >/dev/null 2>&1
owner Card0003 workflow-builder "$TA"; [ "$rc" = 0 ] && has "first token, warm cache: its own agent" '^OWNER: cb1 ' || fail "owner A" "rc=$rc $out"
owner Card0004 workflow-builder "$TB"; [ "$rc" = 0 ] && has "second token, same warm cache: its own agent" '^OWNER: cb2 ' || fail "owner B" "rc=$rc $out"
# a call without a token parsed the Bash line first
tx cb3 workflow-builder - "300|prompt|Work https://trello.com/c/Card0005" "40|bash|agent-state.sh --owner Card0005 workflow-builder $TC"
"$bin/agent-state.sh" --all >/dev/null 2>&1
owner Card0005 workflow-builder "$TC"; [ "$rc" = 0 ] && has "a call without a token, then --owner on the line it parsed" '^OWNER: cb3 ' || fail "owner pre-parsed" "rc=$rc $out"
# housekeeping: an agent that left the window loses its entry; a filtered call does not clean
rm -rf "$tmp/tr/s-cb3"
"$bin/agent-state.sh" cb1 >/dev/null 2>&1
[ -e "$AGENT_STATE_CACHE/cb3.pickle" ] && pass "a filtered call leaves other entries" || fail "filtered clean" ""
"$bin/agent-state.sh" --all >/dev/null 2>&1
[ ! -e "$AGENT_STATE_CACHE/cb3.pickle" ] && pass "an unfiltered call removes the entry of an agent that is gone" || fail "housekeeping" ""
# an agent with two transcript files is always parsed whole
mkdir -p "$tmp/tr/s-ca1b/subagents"
cp "$(cfile ca1)" "$tmp/tr/s-ca1b/subagents/agent-ca1.jsonl"; cp "$tmp/tr/s-ca1/subagents/agent-ca1.meta.json" "$tmp/tr/s-ca1b/subagents/"
out=$("$bin/agent-state.sh" --all 2>&1); has "an agent with two transcript files still works" 'id=ca1 '
# off by default under AGENT_TRANSCRIPTS_DIR; a test never touches the real cache
unset AGENT_STATE_CACHE
rm -rf "$tmp/nocache"
"$bin/agent-state.sh" --all >/dev/null 2>&1
[ ! -e /Users/shawn/Development/example_files/agent-state-cache/ca3.pickle ] && pass "AGENT_TRANSCRIPTS_DIR without AGENT_STATE_CACHE: the cache is off" || fail "cache default off" ""

# A plugin agent's type is written kourai:<role>; the bare role and the prefixed form are the same role
rm -rf "$tmp/tr"; mkdir -p "$tmp/tr/sess/subagents"
agent pfx1 kourai:card-manager 30 text
agent pfx2 card-manager 30 text
agent pfx3 kourai:merger 30 text
out=$("$bin/agent-state.sh" --all 2>&1)
grep -q -- ' card-manager card=.* id=pfx1 ' <<<"$out" && pass "kourai:card-manager is listed as card-manager" || fail "prefixed card manager listed" "$out"
grep -q -- ' card-manager card=.* id=pfx2 ' <<<"$out" && pass "the bare card-manager is listed as card-manager" || fail "bare card manager listed" "$out"
grep -q -- ' merger card=.* id=pfx3 ' <<<"$out" && pass "kourai:merger is listed as merger" || fail "prefixed merger listed" "$out"
! grep -q 'kourai:' <<<"$out" && pass "the listing never prints the prefix" || fail "prefix in the listing" "$out"


echo
if [ "$failures" -eq 0 ]; then echo "All cases passed"; exit 0; fi
echo "$failures case(s) failed"; exit 1
