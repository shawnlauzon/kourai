#!/bin/bash
# Test of code-review-wait.sh: fake forks in a temporary projects folder, no network.
set -u
export KOURAI_CONFIG=${KOURAI_CONFIG:-$(cd "$(dirname "$0")" && pwd)/fixtures/config.toml}
export KOURAI_BIN=${KOURAI_BIN:-$(cd "$(dirname "$0")/../bin" && pwd)}
bin=$(cd "$(dirname "$0")/../bin" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export CODE_REVIEW_PROJECT_DIR=$T/proj CODE_REVIEW_POLL=0.2 CODE_REVIEW_WAIT_LIMIT=1
mkdir -p "$T/proj/s1/subagents" "$T/proj/s2/subagents"
pass=0 fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "PASS $1"; else fail=$((fail+1)); echo "FAIL $1: want [$3], got [$2]"; fi; }
fork() { # fork <session> <id> <target> <finished true|false> <final text> [skill]
  local d=$T/proj/$1/subagents b=$T/proj/$1/subagents/agent-$2
  printf '{"skillName":"%s","effort":"medium"}' "${6:-code-review}" >"$b.forked-skill.json"
  printf '{"name":"code-review","finished":%s}' "$4" >"$b.meta.json"
  python3 -I -c '
import json,sys
t,txt=sys.argv[1],sys.argv[2]
print(json.dumps({"type":"user","message":{"role":"user","content":"Review target: `"+t+"`\n\nthe recipe"}}))
print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}))
if txt: print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":txt}]}}))
print(json.dumps({"type":"attachment","attachment":{}}))' "$3" "$5" >"$b.jsonl"
}
run() { out=$("$bin/code-review-wait.sh" "$1"); rc=$?; }

fork s1 aaa /wt/one true "FINDINGS ONE"
run /wt/one
ok "done: first line" "$(head -1 <<<"$out")" "REVIEW: DONE aaa $T/proj/s1/subagents/agent-aaa.jsonl"
ok "done: the final assistant text follows" "$(sed -n 2p <<<"$out")" "FINDINGS ONE"
ok "done: exit 0" "$rc" "0"

fork s1 bbb /wt/two false ""
run /wt/two
ok "running: line" "$out" "REVIEW: RUNNING bbb"
ok "running: exit 1" "$rc" "1"

# running, then finished while the script polls
( sleep 0.5; printf '{"finished":true}' >"$T/proj/s1/subagents/agent-bbb.meta.json" ) &
CODE_REVIEW_WAIT_LIMIT=5 run /wt/two
wait
ok "running then finished: DONE" "$(head -1 <<<"$out" | cut -c1-16)" "REVIEW: DONE bbb"

# two forks for another target, one for this: the right one
fork s1 ccc /wt/other true "OTHER"
fork s2 ddd /wt/three true "THREE"
run /wt/three
ok "other targets are ignored" "$(sed -n 2p <<<"$out")" "THREE"
# the same target twice: the newest fork
fork s1 eee /wt/three true "OLD"; touch -t 202601010000 "$T/proj/s1/subagents/agent-eee.forked-skill.json"
fork s2 fff /wt/three true "NEWER"
run /wt/three
ok "the newest fork of a target wins" "$(sed -n 2p <<<"$out")" "NEWER"
# a prefix of another target is not a match
fork s1 ggg "medium the uncommitted diff in /wt/six" true "SIX"
run /wt/six
ok "args with words around the path match" "$(sed -n 2p <<<"$out")" "SIX"
run /wt/si
ok "a path prefix inside the words is not a match" "$out" "REVIEW: NOT STARTED /wt/si"
run /wt/thre
ok "a target that only starts the same is not a match" "$out" "REVIEW: NOT STARTED /wt/thre"
ok "not started: exit 3" "$rc" "3"
# a fork of another skill
fork s1 ggg /wt/four true "X" other-skill
run /wt/four
ok "another skill's fork is ignored" "$out" "REVIEW: NOT STARTED /wt/four"
# stale: no write for longer than CODE_REVIEW_STALE
fork s1 hhh /wt/five false ""; touch -t 202601010000 "$T/proj/s1/subagents/agent-hhh.jsonl"
run /wt/five
ok "stale unfinished fork is DEAD" "$out" "REVIEW: DEAD hhh: no transcript write for 20 minutes"
ok "dead: exit 3" "$rc" "3"
# bad arguments
out=$("$bin/code-review-wait.sh" relative/path); rc=$?
ok "a relative path is an error" "$rc" "2"
out=$("$bin/code-review-wait.sh"); rc=$?
ok "no argument is an error" "$rc" "2"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
