#!/usr/bin/env bash
# Tests the wait helpers: .claude/bin/ci-wait.sh, run-bg.sh, run-wait.sh, the
# pause-file check (pause-lib.sh) in them, in run-locked.sh and in
# and the pause check of run-locked.sh.
#
# Usage: .claude/bin/test-wait-helpers.sh
#
# Nothing real is touched: a fake `gh` on PATH answers from files in a
# temporary folder, pause files and locks live there too, and every wait runs
# with a limit of a few seconds. About 40 seconds. Exits 0 when every case
# passes, 1 otherwise, printing PASS/FAIL per case.
set -uo pipefail
export KOURAI_CONFIG=${KOURAI_CONFIG:-$(cd "$(dirname "$0")" && pwd)/fixtures/config.toml}
export KOURAI_BIN=${KOURAI_BIN:-$(cd "$(dirname "$0")/../bin" && pwd)}

root=$(cd "$(dirname "$0")/.." && pwd)
bin=$root/bin

tmp=$(mktemp -d)
# shellcheck disable=SC2329 # called by the EXIT trap
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

# Nothing in this test may reach AWS, Tailscale or a test host, even when a script
# under test lacks an override: these fakes fail at once (2026-10-15, a test of
# test-server.sh up ran the real bring-up and scaled the test-host group out).
mkdir -p "$tmp/nonet"
for c in aws tailscale ssh; do
  printf '#!/usr/bin/env bash\necho "test: %s is not allowed in tests" >&2\nexit 99\n' "$c" >"$tmp/nonet/$c"
  chmod +x "$tmp/nonet/$c"
done
export PATH="$tmp/nonet:$PATH"

failures=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; failures=$((failures + 1)); }

export RC_PAUSE_DIR=$tmp/pause
mkdir -p "$RC_PAUSE_DIR" "$tmp/fakebin" "$tmp/gh"
export CI_WAIT_POLL=1 RUN_WAIT_POLL=1

# A fake gh: `gh pr checks <n> --repo r --json …` prints $tmp/gh/checks-<n>.json
# (exit from checks-<n>.rc, default 0); `gh pr view <n> … --json headRefName -q …`
# prints $tmp/gh/branch-<n>; `gh run view <id> … --json …` prints run-<id>.json;
# `gh run view <id> … --log` prints run-<id>.log.
cat >"$tmp/fakebin/gh" <<EOF
#!/usr/bin/env bash
d=$tmp/gh
case "\$1 \$2" in
  "pr checks") n=\$3; cat "\$d/checks-\$n.json" 2>/dev/null; cat "\$d/checks-\$n.err" >&2 2>/dev/null; exit "\$(cat "\$d/checks-\$n.rc" 2>/dev/null || echo 0)" ;;
  "pr view") n=\$3; cat "\$d/branch-\$n" ;;
  "run view") id=\$3
    case " \$* " in *" --log "*) cat "\$d/run-\$id.log" ;; *) cat "\$d/run-\$id.json" ;; esac ;;
  *) echo "fake gh: unexpected \$*" >&2; exit 9 ;;
esac
EOF
chmod +x "$tmp/fakebin/gh"
export PATH="$tmp/fakebin:$PATH"

# run <out> <command…>: runs it, saving its output and exit code.
run() { local out=$1; shift; "$@" >"$out" 2>&1; echo $? >"$out.rc"; }
rc() { cat "$1.rc"; }

# --- ci-wait.sh pr ---------------------------------------------------------------
echo 'card/AbCd1234-x' >"$tmp/gh/branch-7"
echo '[{"name":"flutter-test","bucket":"pass"},{"name":"lint","bucket":"pass"}]' >"$tmp/gh/checks-7.json"
run "$tmp/c1" env CI_WAIT_LIMIT=5 "$bin/ci-wait.sh" pr o/r 7
if [ "$(rc "$tmp/c1")" = 0 ] && grep -qx 'CI: GREEN' "$tmp/c1"; then pass "pr: all checks passed"
else fail "pr: all checks passed" "rc=$(rc "$tmp/c1") $(cat "$tmp/c1")"; fi

echo '[{"name":"flutter-test","bucket":"fail"},{"name":"lint","bucket":"pass"},{"name":"api","bucket":"cancel"}]' >"$tmp/gh/checks-7.json"
run "$tmp/c2" env CI_WAIT_LIMIT=5 "$bin/ci-wait.sh" pr o/r 7
if [ "$(rc "$tmp/c2")" = 1 ] && grep -qx 'CI: RED flutter-test, api' "$tmp/c2"; then pass "pr: a failed and a cancelled check"
else fail "pr: a failed and a cancelled check" "rc=$(rc "$tmp/c2") $(cat "$tmp/c2")"; fi

echo '[{"name":"flutter-test","bucket":"pending"}]' >"$tmp/gh/checks-7.json"
run "$tmp/c3" env CI_WAIT_LIMIT=3 "$bin/ci-wait.sh" pr o/r 7
if [ "$(rc "$tmp/c3")" = 3 ] && grep -qx 'CI: RUNNING flutter-test' "$tmp/c3"; then pass "pr: still pending at the limit"
else fail "pr: still pending at the limit" "rc=$(rc "$tmp/c3") $(cat "$tmp/c3")"; fi

# A poll longer than the limit is clamped: limit 3, poll 20 returns near 3 s, not 20.
t0=$SECONDS
run "$tmp/c3c" env CI_WAIT_LIMIT=3 CI_WAIT_POLL=20 "$bin/ci-wait.sh" pr o/r 7
if [ "$(rc "$tmp/c3c")" = 3 ] && [ $((SECONDS - t0)) -lt 10 ]; then pass "pr: a poll longer than the limit is clamped to the limit"
else fail "pr: a poll longer than the limit is clamped to the limit" "rc=$(rc "$tmp/c3c") took $((SECONDS - t0)) s"; fi

# The defaults are 270 s (inside the 5-minute prompt cache).
for f in ci-wait.sh:CI_WAIT_LIMIT run-wait.sh:RUN_WAIT_LIMIT code-review-wait.sh:CODE_REVIEW_WAIT_LIMIT; do
  if grep -Eq "${f#*:}[^0-9]{1,6}270" "$bin/${f%%:*}"; then pass "${f%%:*}: default ${f#*:} is 270"
  else fail "${f%%:*}: default ${f#*:} is 270" "not found"; fi
done

: >"$tmp/gh/checks-7.json"; echo 1 >"$tmp/gh/checks-7.rc"
echo "no checks reported on the 'card/AbCd1234-x' branch" >"$tmp/gh/checks-7.err"
run "$tmp/c4" env CI_WAIT_LIMIT=3 CI_WAIT_NO_CHECKS_AFTER=2 "$bin/ci-wait.sh" pr o/r 7
if [ "$(rc "$tmp/c4")" = 4 ] && grep -qx 'CI: NO CHECKS' "$tmp/c4"; then pass "pr: no checks at all"
else fail "pr: no checks at all" "rc=$(rc "$tmp/c4") $(cat "$tmp/c4")"; fi
echo "HTTP 502: Bad Gateway" >"$tmp/gh/checks-7.err"
run "$tmp/c4b" env CI_WAIT_LIMIT=3 CI_WAIT_NO_CHECKS_AFTER=1 "$bin/ci-wait.sh" pr o/r 7
if [ "$(rc "$tmp/c4b")" = 2 ] && grep -q '^CI: ERROR gh: HTTP 502' "$tmp/c4b"; then pass "pr: a gh failure is CI: ERROR, never NO CHECKS"
else fail "pr: a gh failure is CI: ERROR" "rc=$(rc "$tmp/c4b") $(cat "$tmp/c4b")"; fi
rm -f "$tmp/gh/checks-7.rc" "$tmp/gh/checks-7.err"

echo '[{"name":"flutter-test","bucket":"pending"}]' >"$tmp/gh/checks-7.json"
echo "PAUSE for test" >"$RC_PAUSE_DIR/AbCd1234"
run "$tmp/c5" env CI_WAIT_LIMIT=5 "$bin/ci-wait.sh" pr o/r 7
if [ "$(rc "$tmp/c5")" = 5 ] && grep -qx 'PAUSED' "$tmp/c5"; then pass "pr: the card's pause file stops it"
else fail "pr: the card's pause file stops it" "rc=$(rc "$tmp/c5") $(cat "$tmp/c5")"; fi
rm -f "$RC_PAUSE_DIR/AbCd1234"

# https://trello.com/c/wO5ZnwH4: an empty pause file (a stray touch) is no pause
: >"$RC_PAUSE_DIR/AbCd1234"
run "$tmp/c5e" env CI_WAIT_LIMIT=3 "$bin/ci-wait.sh" pr o/r 7
if [ "$(rc "$tmp/c5e")" != 5 ] && ! grep -qx 'PAUSED' "$tmp/c5e"; then pass "pr: an empty pause file is ignored"
else fail "pr: an empty pause file is ignored" "rc=$(rc "$tmp/c5e") $(cat "$tmp/c5e")"; fi
rm -f "$RC_PAUSE_DIR/AbCd1234"

run "$tmp/c6" "$bin/ci-wait.sh" pr o/r
if [ "$(rc "$tmp/c6")" = 2 ]; then pass "pr: usage error"; else fail "pr: usage error" "rc=$(rc "$tmp/c6")"; fi

# --- ci-wait.sh run --------------------------------------------------------------
echo '{"status":"completed","conclusion":"success","jobs":[{"name":"api","conclusion":"success"}]}' >"$tmp/gh/run-11.json"
# Real `gh run view --log` lines: <job>\t<step>\t<timestamp> <text>, the first one
# after a BOM. The step's script is echoed (indented) before it runs, so a
# VERDICT: inside it comes before the real line, and log lines follow it.
ts='2026-10-15T09:00:00.0000000Z'
printf '\357\273\277api\tSet up job\t%s Current runner version\n' "$ts" >"$tmp/gh/run-11.log"
# shellcheck disable=SC2016 # the echoed script's $v, literally
printf 'api\tverdict\t%s ##[group]Run echo "VERDICT: $v"\napi\tverdict\t%s   echo "VERDICT: $v"\n' "$ts" "$ts" >>"$tmp/gh/run-11.log"
printf 'api\tverdict\t%s VERDICT: GREEN*  rerun: src/a.test.ts\napi\tPost job cleanup\t%s Cleaning up orphan processes\n' "$ts" "$ts" >>"$tmp/gh/run-11.log"
run "$tmp/r1" env CI_WAIT_LIMIT=5 "$bin/ci-wait.sh" run o/r 11
if [ "$(rc "$tmp/r1")" = 0 ] && grep -qx 'RUN: SUCCESS' "$tmp/r1" && grep -qx 'VERDICT: GREEN\*  rerun: src/a.test.ts' "$tmp/r1"; then pass "run: success with its VERDICT line"
else fail "run: success with its VERDICT line" "rc=$(rc "$tmp/r1") $(cat "$tmp/r1")"; fi

echo '{"status":"completed","conclusion":"failure","jobs":[{"name":"build","conclusion":"success"},{"name":"api","conclusion":"failure"}]}' >"$tmp/gh/run-12.json"
printf '\357\273\277api\tstep\t%s no verdict here\n' "$ts" >"$tmp/gh/run-12.log"
run "$tmp/r2" env CI_WAIT_LIMIT=5 "$bin/ci-wait.sh" run o/r 12
if [ "$(rc "$tmp/r2")" = 1 ] && grep -qx 'RUN: FAILURE api' "$tmp/r2" && grep -qx 'VERDICT: (none)' "$tmp/r2"; then pass "run: failure, no VERDICT line"
else fail "run: failure, no VERDICT line" "rc=$(rc "$tmp/r2") $(cat "$tmp/r2")"; fi

echo '{"status":"completed","conclusion":"failure","jobs":[{"name":"api","conclusion":"failure"}]}' >"$tmp/gh/run-14.json"
printf '\357\273\277api\tverdict\t%s VERDICT: RED src/b.test.ts\napi\tPost job cleanup\t%s done\n' "$ts" "$ts" >"$tmp/gh/run-14.log"
run "$tmp/r4" env CI_WAIT_LIMIT=5 "$bin/ci-wait.sh" run o/r 14
if [ "$(rc "$tmp/r4")" = 1 ] && grep -qx 'VERDICT: RED src/b.test.ts' "$tmp/r4"; then pass "run: a VERDICT on the BOM line, not the last line"
else fail "run: a VERDICT on the BOM line" "rc=$(rc "$tmp/r4") $(cat "$tmp/r4")"; fi

echo '{"status":"in_progress","conclusion":"","jobs":[]}' >"$tmp/gh/run-13.json"
run "$tmp/r3" env CI_WAIT_LIMIT=3 "$bin/ci-wait.sh" run o/r 13
if [ "$(rc "$tmp/r3")" = 3 ] && grep -qx 'RUN: RUNNING' "$tmp/r3"; then pass "run: still running at the limit"
else fail "run: still running at the limit" "rc=$(rc "$tmp/r3") $(cat "$tmp/r3")"; fi

# --- run-bg.sh and run-wait.sh ---------------------------------------------------
d=$tmp/bg1
run "$tmp/b1" "$bin/run-bg.sh" --cwd "$tmp" "$d" bash -c 'pwd; echo "two"; exit 0'
if [ "$(rc "$tmp/b1")" = 0 ] && [ "$(cat "$d/END")" = "END 0" ] && head -1 "$d/output.log" | grep -qF "$tmp"; then pass "run-bg: runs in --cwd, writes output.log and END"
else fail "run-bg: runs in --cwd" "rc=$(rc "$tmp/b1") END=$(cat "$d/END" 2>/dev/null) out=$(cat "$d/output.log" 2>/dev/null)"; fi

run "$tmp/w1" env RUN_WAIT_LIMIT=3 "$bin/run-wait.sh" "$d"
if [ "$(rc "$tmp/w1")" = 0 ] && grep -qx 'END 0' "$tmp/w1" && grep -qx 'two' "$tmp/w1"; then pass "run-wait: a finished run prints END and the output's tail"
else fail "run-wait: finished run" "rc=$(rc "$tmp/w1") $(cat "$tmp/w1")"; fi

d=$tmp/bg2
"$bin/run-bg.sh" "$d" bash -c 'echo started; sleep 6; echo "SERVER SUITE: FAILED: a.test.ts"; exit 1' >/dev/null 2>&1 &
sleep 1
run "$tmp/w2" env RUN_WAIT_LIMIT=2 "$bin/run-wait.sh" "$d"
if [ "$(rc "$tmp/w2")" = 124 ] && grep -qx 'RUNNING' "$tmp/w2"; then pass "run-wait: a run still going prints RUNNING"
else fail "run-wait: still going" "rc=$(rc "$tmp/w2") $(cat "$tmp/w2")"; fi
run "$tmp/w3" env RUN_WAIT_LIMIT=15 "$bin/run-wait.sh" "$d"
if [ "$(rc "$tmp/w3")" = 1 ] && grep -qx 'END 1' "$tmp/w3" && grep -qx 'SERVER SUITE: FAILED: a.test.ts' "$tmp/w3"; then pass "run-wait: called again, the failed run's END and its last lines"
else fail "run-wait: called again" "rc=$(rc "$tmp/w3") $(cat "$tmp/w3")"; fi
wait

d=$tmp/bg6
run "$tmp/b6" "$bin/run-bg.sh" "$d" bash -c 'echo working; echo PAUSED; exit 5'
run "$tmp/w7" env RUN_WAIT_LIMIT=3 "$bin/run-wait.sh" "$d"
if [ "$(rc "$tmp/w7")" = 5 ] && [ "$(cat "$tmp/w7")" = PAUSED ]; then pass "run-wait: a run that run-locked stopped on a pause prints PAUSED, not END 5"
else fail "run-wait: a paused run" "rc=$(rc "$tmp/w7") $(cat "$tmp/w7")"; fi

d=$tmp/bg3 && mkdir -p "$d" && echo 99999 >"$d/PID" && echo 'half' >"$d/output.log"
run "$tmp/w4" env RUN_WAIT_LIMIT=3 "$bin/run-wait.sh" "$d"
if [ "$(rc "$tmp/w4")" = 6 ] && grep -q '^RUN DIED' "$tmp/w4"; then pass "run-wait: no END and the process gone is RUN DIED"
else fail "run-wait: died" "rc=$(rc "$tmp/w4") $(cat "$tmp/w4")"; fi

# --- the pause file in run-locked.sh and run-wait.sh -----------------------------
# A worktree named like an agent's, <agent>-<shortLink>, is how they find the card.
wt=$tmp/worktrees/server-builder-PaUs1234 && mkdir -p "$wt"
echo "PAUSE for test" >"$RC_PAUSE_DIR/PaUs1234"
( cd "$wt" && RC_LOCK_DIR=$tmp/locks "$bin/run-locked.sh" test-lock sleep 20 ) >"$tmp/l1" 2>&1; echo $? >"$tmp/l1.rc"
if [ "$(rc "$tmp/l1")" = 5 ] && grep -qx 'PAUSED' "$tmp/l1"; then pass "run-locked: a paused card's command stops at once"
else fail "run-locked: paused" "rc=$(rc "$tmp/l1") $(cat "$tmp/l1")"; fi
rm -f "$RC_PAUSE_DIR/PaUs1234"

( cd "$wt" && RC_LOCK_DIR=$tmp/locks RC_PAUSE_POLL=1 "$bin/run-locked.sh" test-lock bash -c 'sleep 20' ) >"$tmp/l2" 2>&1 &
lp=$!
sleep 2; echo "PAUSE for test" >"$RC_PAUSE_DIR/PaUs1234"
for _ in 1 2 3 4 5 6 7 8; do kill -0 "$lp" 2>/dev/null || break; sleep 1; done
wait "$lp"; echo $? >"$tmp/l2.rc"
if [ "$(rc "$tmp/l2")" = 5 ] && grep -qx 'PAUSED' "$tmp/l2"; then pass "run-locked: a pause during the run stops it"
else fail "run-locked: pause during the run" "rc=$(rc "$tmp/l2") $(cat "$tmp/l2")"; fi
rm -f "$RC_PAUSE_DIR/PaUs1234"

( cd "$wt" && RC_LOCK_DIR=$tmp/locks "$bin/run-locked.sh" test-lock bash -c 'exit 0' ) >"$tmp/l3" 2>&1; echo $? >"$tmp/l3.rc"
if [ "$(rc "$tmp/l3")" = 0 ]; then pass "run-locked: no pause file, the command runs"
else fail "run-locked: no pause" "rc=$(rc "$tmp/l3") $(cat "$tmp/l3")"; fi

d=$tmp/bg4 && mkdir -p "$d" && echo $$ >"$d/PID"
echo "PAUSE for test" >"$RC_PAUSE_DIR/WaIt1234"
run "$tmp/w5" env RUN_WAIT_LIMIT=3 "$bin/run-wait.sh" "$d" --card WaIt1234
if [ "$(rc "$tmp/w5")" = 5 ] && grep -qx 'PAUSED' "$tmp/w5"; then pass "run-wait: --card's pause file stops the wait"
else fail "run-wait: paused" "rc=$(rc "$tmp/w5") $(cat "$tmp/w5")"; fi
rm -f "$RC_PAUSE_DIR/WaIt1234"

# --- signals and stubborn commands --------------------------------------------------
( cd "$wt" && RC_LOCK_DIR=$tmp/locks RC_PAUSE_POLL=1 exec "$bin/run-locked.sh" sig-lock bash -c 'echo $$ >"'"$tmp"'/sig.pid"; sleep 300' ) >/dev/null 2>&1 &
rl=$!
for _ in 1 2 3 4 5; do [ -s "$tmp/sig.pid" ] && break; sleep 1; done
kill -TERM "$rl"; wait "$rl" 2>/dev/null
sleep 1
if ! kill -0 "$(cat "$tmp/sig.pid")" 2>/dev/null && [ ! -d "$tmp/locks/sig-lock.lock" ]; then pass "run-locked: TERM stops the command and only then frees the lock"
else fail "run-locked: TERM" "command alive: $(kill -0 "$(cat "$tmp/sig.pid")" 2>/dev/null && echo yes || echo no), lock: $(ls "$tmp/locks")"; kill "$(cat "$tmp/sig.pid")" 2>/dev/null; fi

( cd "$wt" && RC_LOCK_DIR=$tmp/locks RC_PAUSE_POLL=1 RC_STOP_GRACE=2 "$bin/run-locked.sh" stub-lock bash -c 'trap "" TERM; echo $$ >"'"$tmp"'/stub.pid"; while :; do sleep 1; done' ) >"$tmp/l4" 2>&1 &
sp=$!
for _ in 1 2 3 4 5; do [ -s "$tmp/stub.pid" ] && break; sleep 1; done
echo "PAUSE for test" >"$RC_PAUSE_DIR/PaUs1234"
for _ in $(seq 1 12); do kill -0 "$sp" 2>/dev/null || break; sleep 1; done
wait "$sp"; echo $? >"$tmp/l4.rc"
if [ "$(rc "$tmp/l4")" = 5 ] && ! kill -0 "$(cat "$tmp/stub.pid")" 2>/dev/null; then pass "run-locked: a command that ignores TERM is killed on a pause"
else fail "run-locked: stubborn command" "rc=$(rc "$tmp/l4") alive=$(kill -0 "$(cat "$tmp/stub.pid")" 2>/dev/null && echo yes || echo no)"; kill -9 "$(cat "$tmp/stub.pid")" 2>/dev/null; fi
rm -f "$RC_PAUSE_DIR/PaUs1234"

d=$tmp/bg5 && mkdir -p "$d"
( sleep 2; exec "$bin/run-bg.sh" "$d" bash -c 'echo late; exit 0' ) >/dev/null 2>&1 &
run "$tmp/w6" env RUN_WAIT_LIMIT=10 "$bin/run-wait.sh" "$d"
if [ "$(rc "$tmp/w6")" = 0 ] && grep -qx 'END 0' "$tmp/w6"; then pass "run-wait: started before run-bg wrote its PID, it waits for it"
else fail "run-wait: before PID" "rc=$(rc "$tmp/w6") $(cat "$tmp/w6")"; fi
wait

# --- run-wait.sh stop -------------------------------------------------------------
d=$tmp/bg6 && mkdir -p "$d"
"$bin/run-bg.sh" "$d" bash -c 'sleep 61 & sleep 61; wait' >/dev/null 2>&1 &
sleep 2
run "$tmp/s1" env RC_STOP_GRACE=3 "$bin/run-wait.sh" stop "$d"
sleep 1
if [ "$(rc "$tmp/s1")" = 0 ] && grep -qx "STOPPED $d" "$tmp/s1" && grep -q '^END ' "$d/END" 2>/dev/null \
   && ! pgrep -f 'sleep 61' >/dev/null 2>&1; then pass "run-wait stop: ends the run's descendants and run-bg writes END"
else fail "run-wait stop" "rc=$(rc "$tmp/s1") $(cat "$tmp/s1") END=$(cat "$d/END" 2>/dev/null)"; fi
run "$tmp/s2" "$bin/run-wait.sh" stop "$d"
if [ "$(rc "$tmp/s2")" = 0 ] && grep -qx 'NOT RUNNING' "$tmp/s2"; then pass "run-wait stop: END present is NOT RUNNING"
else fail "run-wait stop: END present" "$(cat "$tmp/s2")"; fi
d=$tmp/bg7 && mkdir -p "$d"
sleep 30 & other=$!
echo "$other" >"$d/PID"
run "$tmp/s3" "$bin/run-wait.sh" stop "$d"
if grep -qx 'NOT RUNNING' "$tmp/s3" && kill -0 "$other" 2>/dev/null; then pass "run-wait stop: a PID that is not run-bg.sh is refused and left alone"
else fail "run-wait stop: non run-bg PID" "$(cat "$tmp/s3")"; fi
kill "$other" 2>/dev/null; wait "$other" 2>/dev/null

echo
if [ "$failures" -eq 0 ]; then echo "All cases passed"; exit 0; fi
echo "$failures case(s) failed"; exit 1
