#!/usr/bin/env bash
# Tests the board scripts: card-kind.sh, dev-merge-lock.sh, heartbeat.sh, board-snapshot.sh and
# merged-cards.sh. (The test-server and card-test-server cases test the project layer's scripts and
# live there.)
#
# Usage: tests/test-board-scripts.sh
#
# Nothing real is touched: a fake `gh` answers PR file lists, a fake
# agent-state.sh answers liveness, and every lock and state file lives in a
# temporary folder. A few seconds. Exits 0 when every case passes, 1 otherwise.
# shellcheck disable=SC2016 # the checks are single-quoted on purpose: ok() evals them
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
ok() { if eval "$2"; then pass "$1"; else fail "$1" "${3:-check failed: $2}"; fi; }
# rc_dir <folder>: EVERY assignment of RC_TEST_SERVER_DIR goes through it. The test aborts (exit 2) unless the
# folder is under $tmp, so no case can ever write the real test-servers folder.
rc_dir() { case "$1" in "$tmp"/*) export RC_TEST_SERVER_DIR=$1 ;; *) echo "ABORT: RC_TEST_SERVER_DIR must be under $tmp, got: $1" >&2; exit 2 ;; esac; }
run() { local out=$1; shift; "$@" >"$out" 2>&1; echo $? >"$out.rc"; }
# shellcheck disable=SC2329 # called inside the eval'd checks
rc() { cat "$1.rc"; }

# --- card-kind.sh ----------------------------------------------------------------
cat >"$tmp/gh" <<EOF
#!/usr/bin/env bash
# gh api --paginate repos/<repo>/pulls/<n>/files --jq …: prints $tmp/files-<n>
n=\$(printf '%s\n' "\$@" | sed -n 's|^repos/.*/pulls/\([0-9]*\)/files\$|\1|p')
cat "$tmp/files-\$n"
EOF
chmod +x "$tmp/gh"
export CARD_KIND_GH=$tmp/gh
printf 'tool/ui_test_lib.sh\n.claude/bin/x.sh\n' >"$tmp/files-1"
run "$tmp/k1" "$bin/card-kind.sh" example-user/example-app-old#1
ok "card-kind: a tool/ test script is TESTS, not AGENTS" 'grep -qx "CARD: TESTS" "$tmp/k1"' "$(cat "$tmp/k1")"
printf '.claude/agents/merger.md\nREADME.md\n' >"$tmp/files-2"
run "$tmp/k2" "$bin/card-kind.sh" example-user/example-app-old#2
ok "card-kind: agent files only is AGENTS" 'grep -qx "CARD: AGENTS" "$tmp/k2"' "$(cat "$tmp/k2")"
printf 'lib/main.dart\n' >"$tmp/files-3"
run "$tmp/k3" "$bin/card-kind.sh" example-user/example-app-old#2 example-user/example-app-old#3
ok "card-kind: any app file makes the card APP" 'grep -qx "CARD: APP" "$tmp/k3"' "$(cat "$tmp/k3")"
# the mobile repo moved to RunnerCityOrg: the same rules under its new name
run "$tmp/k4" "$bin/card-kind.sh" example-org/example-app#1
ok "card-kind: under the new mobile repo name a tool/ test script is TESTS" 'grep -qx "CARD: TESTS" "$tmp/k4"' "$(cat "$tmp/k4")"
run "$tmp/k5" "$bin/card-kind.sh" example-org/example-app#3
ok "card-kind: under the new mobile repo name an app file makes the card APP" 'grep -qx "CARD: APP" "$tmp/k5"' "$(cat "$tmp/k5")"
# --paths: the same test on named paths, no gh call
run "$tmp/k6" "$bin/card-kind.sh" --paths example-org/example-app test/a_test.dart lib/a.dart README.md
ok "card-kind --paths: one kind per path and the highest" 'grep -qx "TESTS test/a_test.dart" "$tmp/k6" && grep -qx "APP lib/a.dart" "$tmp/k6" && grep -qx "AGENTS README.md" "$tmp/k6" && grep -qx "PATHS: APP" "$tmp/k6"' "$(cat "$tmp/k6")"
run "$tmp/k7" "$bin/card-kind.sh" --paths example-org/example-api tests/integration/a.ts docs/x.txt
ok "card-kind --paths: server tests and docs are not APP" 'grep -qx "PATHS: TESTS" "$tmp/k7"' "$(cat "$tmp/k7")"
run "$tmp/k8" "$bin/card-kind.sh" --paths example-org/example-api app/models/user.rb
ok "card-kind --paths: a server app file is APP" 'grep -qx "PATHS: APP" "$tmp/k8"' "$(cat "$tmp/k8")"

# --- dev-merge-lock.sh -----------------------------------------------------------
export RC_LOCK_DIR=$tmp/locks
cat >"$tmp/agent-state" <<EOF
#!/usr/bin/env bash
cat "$tmp/state-lines" 2>/dev/null
EOF
chmod +x "$tmp/agent-state"
export DEV_MERGE_LOCK_AGENT_STATE=$tmp/agent-state
L=$bin/dev-merge-lock.sh

run "$tmp/d1" "$L" integration-server status
ok "lock: free at first" 'grep -qx free "$tmp/d1"' "$(cat "$tmp/d1")"
run "$tmp/d2" "$L" integration-server take promoter
ok "lock: the promoter takes it, at once" '[ "$(rc "$tmp/d2")" = 0 ] && grep -q "taken by promoter" "$tmp/d2"' "$(cat "$tmp/d2")"
run "$tmp/d3" "$L" integration-server take promoter
ok "lock: taking it again as the promoter succeeds" '[ "$(rc "$tmp/d3")" = 0 ] && grep -q "already held by promoter" "$tmp/d3"' "$(cat "$tmp/d3")"
echo "running promoter card=- id=a1 last=5s children=0 - /x.jsonl" >"$tmp/state-lines"
run "$tmp/d4" "$L" integration-server status
ok "lock: status names the holder and a live promoter" 'grep -q "^held by promoter since .* (a promoter is alive)" "$tmp/d4"' "$(cat "$tmp/d4")"
echo "reported promoter card=- id=a1 last=900s children=0 reported /x.jsonl" >"$tmp/state-lines"
run "$tmp/d5" "$L" integration-server status
ok "lock: status says when no promoter is alive (a dead one's lock)" 'grep -q "(no promoter alive)" "$tmp/d5"' "$(cat "$tmp/d5")"
run "$tmp/d6" "$L" integration-server take promoter 14400
ok "lock: a wait argument is refused (takes never wait)" '[ "$(rc "$tmp/d6")" = 2 ]'
run "$tmp/d7" "$L" integration-server release promoter
ok "lock: the promoter releases it" '[ "$(rc "$tmp/d7")" = 0 ] && [ ! -d "$tmp/locks/integration-test-server" ]' "$(cat "$tmp/d7")"
run "$tmp/d8" "$L" integration-server take integrator
ok "lock: no role but the promoter" '[ "$(rc "$tmp/d8")" = 2 ]'
if grep -q 'heartbeat\.sh' "$L"; then fail "lock: no heartbeat.sh call left" "$(grep -n 'heartbeat\.sh' "$L")"; else pass "lock: no heartbeat.sh call left"; fi

# --- heartbeat.sh ----------------------------------------------------------------
export HEARTBEAT_DIR=$tmp/hb
mkdir -p "$HEARTBEAT_DIR" && touch "$HEARTBEAT_DIR/AbCd1234"
run "$tmp/h1" "$bin/heartbeat.sh" remove AbCd1234
ok "heartbeat: remove clears a leftover file" '[ "$(rc "$tmp/h1")" = 0 ] && [ ! -e "$HEARTBEAT_DIR/AbCd1234" ]'
run "$tmp/h2" "$bin/heartbeat.sh" path AbCd1234
ok "heartbeat: path prints the keep-alive file" 'grep -qx "$HEARTBEAT_DIR/AbCd1234" "$tmp/h2"' "$(cat "$tmp/h2")"
run "$tmp/h3" "$bin/heartbeat.sh" touch AbCd1234
ok "heartbeat: touch is gone (agents write no heartbeats)" '[ "$(rc "$tmp/h3")" = 2 ]'

# --- board-snapshot.sh -----------------------------------------------------------
mkdir -p "$tmp/fakebin" "$tmp/trello"
printf 'TRELLO_KEY=k\nTRELLO_TOKEN=t\n' >"$tmp/trello.env"
cat >"$tmp/fakebin/curl" <<'EOF'
#!/usr/bin/env bash
# Prints the HTTP status like curl -w '%{http_code}'. A board actions read with limit above 300 answers 429 (the rule
# of the real board, card xXtokNFg; no other path has it); a file $FAKE_TRELLO/429-once makes the next request answer 429
# once; a file $FAKE_TRELLO/429-always makes every request answer 429; before=<id> serves <path>.before-<id>.json when it exists.
out="" url="" wcode="" failf=""
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2 ;; -w) wcode=1; shift 2 ;; -f|-sf) failf=1; shift ;; -*) shift ;; *) url=$1; shift ;; esac; done
path=${url#https://trello.test/1/}; path=${path%%\?*}
echo "$url" >>"$FAKE_TRELLO/requests.log"
code=200
if [ -e "$FAKE_TRELLO/429-always" ]; then code=429
elif [ -e "$FAKE_TRELLO/429-once" ]; then rm "$FAKE_TRELLO/429-once"; code=429
elif [[ "$path" == boards/*/actions ]]; then
  lim=$(sed -n 's/.*[?&]limit=\([0-9]*\).*/\1/p' <<<"$url")
  [ "${lim:-0}" -le 300 ] || code=429
fi
if [ "$code" = 200 ]; then
  before=$(sed -n 's/.*[?&]before=\([A-Za-z0-9]*\).*/\1/p' <<<"$url")
  f="$FAKE_TRELLO/${path//\//_}.json"
  [ -z "$before" ] || [ ! -f "${f%.json}.before-$before.json" ] || f="${f%.json}.before-$before.json"
  cp "$f" "$out"
else : >"$out"; fi
if [ -n "$wcode" ]; then printf '%s' "$code"; elif [ "$code" != 200 ]; then exit 22; fi
EOF
export FAKE_TRELLO="$tmp/trello" RC_RETRY_SLEEP=0
chmod +x "$tmp/fakebin/curl"
echo '[{"id":"lp","name":"🙋‍♂️ PROPOSED 💡","pos":1},{"id":"lm","name":"MERGING","pos":2}]' >"$tmp/trello/boards_AbCd1234_lists.json"
echo '[{"id":"c1","name":"An idea","idList":"lp","idLabels":[],"idMembers":[],"shortLink":"IdEa1234","pos":1,"desc":""},
       {"id":"c2","name":"A card","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"CaRd1234","pos":1,"desc":""},
       {"id":"c3","name":"Moved repo (#7)","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"MoVd1234","pos":2,"desc":"**PR:** example-org/example-app#7, https://github.com/example-org/example-app/pull/7 (x)"},
       {"id":"c5","name":"Short comment","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"ShRt1234","pos":4,"desc":""},
       {"id":"c4","name":"Old comment (#8)","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"OlDc1234","pos":3,"desc":"**PR:** example-org/example-app#8, https://github.com/example-org/example-app/pull/8 (x)"}]' >"$tmp/trello/boards_AbCd1234_cards.json"
echo '[]' >"$tmp/trello/boards_AbCd1234_labels.json"
echo '[{"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"000000000000000000000002","data":{"text":"GREEN*: example-user/example-app-old#5 @ abc","card":{"id":"c2"}}},
       {"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"000000000000000000000002","data":{"text":"PR: https://github.com/example-user/example-app-old/pull/8","card":{"id":"c4"}}},
       {"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"000000000000000000000002","data":{"text":"PR: example-org/example-app#9\nSee also example-org/example-app#12","card":{"id":"c5"}}}]' >"$tmp/trello/boards_AbCd1234_actions.json"
run "$tmp/b1" env PATH="$tmp/fakebin:$PATH" TRELLO_ENV_FILE="$tmp/trello.env" TRELLO_API_BASE=https://trello.test/1 "$bin/board-snapshot.sh"
ok "snapshot: a PROPOSED card gets the short form" 'grep -qx "IdEa1234 | An idea" "$tmp/b1"' "$(cat "$tmp/b1")"
ok "snapshot: a card naming its PR by the new mobile repo name is named (#N) with no complaint" '! grep -q "MoVd1234.*name prs" "$tmp/b1"' "$(cat "$tmp/b1")"
ok "snapshot: an old-name PR comment and a new-name description line are the same PR" '! grep -q "OlDc1234.*prs missing" "$tmp/b1"' "$(cat "$tmp/b1")"
ok "snapshot: a PR comment naming the PR as owner/repo#N (no link) is read, so the card's description is checked for it" 'grep -q "ShRt1234.*prs missing: example-org/example-app#9" "$tmp/b1"' "$(grep ShRt "$tmp/b1" | cut -c1-300)"
ok "snapshot: only the first line of a PR: comment names the PR (as in merge-gate), so a later mention is not read" '! grep -q "example-app#12" <<<"$(grep -o "prs missing:.*" <<<"$(grep ShRt "$tmp/b1")")"' "$(grep ShRt "$tmp/b1" | cut -c1-300)"
# MERGING prints urgent cards first (with or without a space after the emoji); other order unchanged
echo '[{"id":"lp","name":"🙋‍♂️ PROPOSED 💡","pos":1},{"id":"lm","name":"MERGING","pos":2},{"id":"lt","name":"TODO","pos":3}]' >"$tmp/trello/boards_AbCd1234_lists.json"
echo '[{"id":"m1","name":"First normal","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"NoRm0001","pos":1,"desc":""},
       {"id":"m2","name":"Second normal","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"NoRm0002","pos":2,"desc":""},
       {"id":"m3","name":"🚨Urgent no space","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"UrG00003","pos":3,"desc":""},
       {"id":"m4","name":"🚨 Urgent with space","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"UrG00004","pos":4,"desc":""},
       {"id":"m5","name":"[AGENTS] Workflow card","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"AgNt0005","pos":5,"desc":""},
       {"id":"t1","name":"Todo one","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"ToDo0001","pos":1,"desc":""},
       {"id":"t2","name":"🚨 Todo urgent","idList":"lt","idLabels":[],"idMembers":[],"shortLink":"ToDo0002","pos":2,"desc":""}]' >"$tmp/trello/boards_AbCd1234_cards.json"
echo '[]' >"$tmp/trello/boards_AbCd1234_actions.json"
run "$tmp/b2" env PATH="$tmp/fakebin:$PATH" TRELLO_ENV_FILE="$tmp/trello.env" TRELLO_API_BASE=https://trello.test/1 "$bin/board-snapshot.sh"
ok "snapshot: MERGING prints 🚨 cards first, then [AGENTS] cards, then the rest in list order" '[ "$(sed -n "/^== MERGING/,/^== TODO/p" "$tmp/b2" | grep -v "^==" | cut -c1-8 | tr "\n" " ")" = "UrG00003 UrG00004 AgNt0005 NoRm0001 NoRm0002 " ]' "$(cat "$tmp/b2")"
ok "snapshot: another list keeps its list order" '[ "$(sed -n "/^== TODO/,\$p" "$tmp/b2" | grep -v "^==" | cut -c1-8 | tr "\n" " ")" = "ToDo0001 ToDo0002 " ]' "$(cat "$tmp/b2")"
ok "snapshot: GREEN*: is read as a status phrase" 'grep -q "CaRd1234 | A card .* status: GREEN\*: 2026-10-15 09:00" "$tmp/b1"' "$(cat "$tmp/b1")"
# Paging (card xXtokNFg): 650 comments over 3 pages of 300; a PR: comment only on page 3 is still read; no request has limit above 300.
python3 -I - "$tmp/trello" <<'PY'
import json, sys
d = sys.argv[1]
def c(n, text="x", card="c2"):
    return {"id": f"a{n:04d}", "date": f"2026-10-15T{9 + (1000 - n) // 600:02d}:{((1000 - n) % 600) // 10:02d}:00.000Z",
            "idMemberCreator": "000000000000000000000002", "data": {"text": text, "card": {"id": card}}}
allc = [c(n) for n in range(1, 651)]
allc[640] = c(641, "PR: example-org/example-app#77", "c5")
p1, p2, p3 = allc[:300], allc[300:600], allc[600:]
json.dump(p1, open(f"{d}/boards_AbCd1234_actions.json", "w"))
oldest = min(p1, key=lambda a: a["date"])["id"]; json.dump(p2, open(f"{d}/boards_AbCd1234_actions.before-{oldest}.json", "w"))
oldest2 = min(p2, key=lambda a: a["date"])["id"]; json.dump(p3, open(f"{d}/boards_AbCd1234_actions.before-{oldest2}.json", "w"))
PY
echo '[{"id":"lm","name":"MERGING","pos":1}]' >"$tmp/trello/boards_AbCd1234_lists.json"
echo '[{"id":"c5","name":"Short comment","idList":"lm","idLabels":[],"idMembers":[],"shortLink":"ShRt1234","pos":1,"desc":""}]' >"$tmp/trello/boards_AbCd1234_cards.json"
: >"$tmp/trello/requests.log"
run "$tmp/b3" env PATH="$tmp/fakebin:$PATH" TRELLO_ENV_FILE="$tmp/trello.env" TRELLO_API_BASE=https://trello.test/1 "$bin/board-snapshot.sh"
ok "snapshot: a PR: comment only on page 3 of 3 is read" 'grep -q "ShRt1234.*prs missing: example-org/example-app#77" "$tmp/b3"' "$(cat "$tmp/b3")"
ok "snapshot: 650 comments are read in three requests of limit 300" '[ "$(grep -c "/actions?" "$tmp/trello/requests.log")" = 3 ] && ! grep -qv "limit=300" <<<"$(grep "/actions?" "$tmp/trello/requests.log")"' "$(cat "$tmp/trello/requests.log")"
touch "$tmp/trello/429-once"
run "$tmp/b4" env PATH="$tmp/fakebin:$PATH" TRELLO_ENV_FILE="$tmp/trello.env" TRELLO_API_BASE=https://trello.test/1 "$bin/board-snapshot.sh"
ok "snapshot: one 429 is retried and the snapshot succeeds" 'grep -q "ShRt1234" "$tmp/b4"' "$(cat "$tmp/b4")"
touch "$tmp/trello/429-always"
env PATH="$tmp/fakebin:$PATH" TRELLO_ENV_FILE="$tmp/trello.env" TRELLO_API_BASE=https://trello.test/1 "$bin/board-snapshot.sh" >"$tmp/b5" 2>&1; rc5=$?
ok "snapshot: four 429s in a row exit 1 with the message" '[ "$rc5" = 1 ] && grep -q "board-snapshot: Trello request failed" "$tmp/b5"' "rc=$rc5 $(cat "$tmp/b5")"
rm -f "$tmp/trello/429-always" "$tmp/trello/429-once"

# --- merged-cards.sh: the promoter's bounded read of MERGED, 30+ cards -------------
# A fake board of 34 cards in MERGED and one in RELEASING, each with a huge description
# and comments of 50,000 characters: the output stays one short line per card.
mkdir -p "$tmp/mc"
echo '[{"id":"lg","name":"MERGED","pos":9},{"id":"lr","name":"RELEASING","pos":10},{"id":"lt","name":"TODO","pos":1}]' >"$tmp/mc/boards_AbCd1234_lists.json"
echo '[{"id":"lab1","name":"","color":"red"}]' >"$tmp/mc/boards_AbCd1234_labels.json"
big=$(head -c 50000 /dev/zero | tr '\0' 'x')
python3 -I - "$tmp/mc" "$big" <<'PY'
import json, sys
d, big = sys.argv[1], sys.argv[2]
cards = [{"id": "t0", "name": "Not mine", "idList": "lt", "idLabels": [], "idMembers": [], "shortLink": "ToDo0000", "pos": 1, "desc": big}]
for i in range(35):
    cid = "m%d" % i
    lst = "lr" if i == 34 else "lg"
    cards.append({"id": cid, "name": ("Card %d " % i) + "n" * 300, "idList": lst, "idLabels": ["lab1"] if i == 3 else [],
                  "idMembers": [], "shortLink": "MeRg%04d" % i, "pos": i, "desc": big})
    acts = [
        {"type": "commentCard", "date": "2026-10-1%dT10:00:00.000Z" % (i % 10), "data": {"text": "PR: https://github.com/example-user/example-app-old/pull/%d\n%s" % (100 + i, big)}},
        {"type": "commentCard", "date": "2026-10-1%dT11:00:00.000Z" % (i % 10), "data": {"text": "MERGED: example-user/example-app-old#%d @ %s\n%s" % (100 + i, "abcdef0123456789abcdef0123456789abcdef01", big)}},
        {"type": "updateCard", "date": "2026-10-1%dT12:00:00.000Z" % (i % 10), "data": {"listAfter": {"id": lst}, "listBefore": {"id": "lm"}}},
    ]
    if i == 6:
        acts[1]["data"]["text"] = "MERGED WITH: Carrying card: with a colon: example-user/example-app-old#%d @ abcdef0123456789abcdef0123456789abcdef01\\n%s" % (900, big)
    if i == 7:
        acts[0]["data"]["text"] = "PR: example-org/example-app#107\n" + big
    if i == 5:
        acts.append({"type": "commentCard", "date": "2026-10-17T12:00:00.000Z", "data": {"text": "REVERTED: x\n" + big}})
    # creators (rules.md, VERIFY): each internal account, an external one, a REPORTER line under PR lines, an unreadable one
    mk = lambda who, t="createCard": {"type": t, "date": "2026-10-01T09:00:00.000Z", "idMemberCreator": who, "data": {}}
    if i == 3: acts.append(mk("000000000000000000000002"))
    if i == 4: acts.append(mk("000000000000000000000001"))
    if i == 8: acts.append(mk("000000000000000000000003"))
    if i == 9: acts.append(mk("mext0000"))
    if i == 10:
        acts.append(mk("000000000000000000000002"))
        cards[-1]["desc"] = "**PR:** a/b#1, https://x (y)\nREPORTER: @tess, @bo\nrest"
    if i == 11: acts.append(mk("mgone000"))
    if i == 12: acts.append(mk("mext0000", "copyCard"))
    json.dump(acts, open("%s/cards_%s_actions.json" % (d, cid), "w"))
cards.append({"id": "st", "name": "⛔ BLOCKED: user hold", "idList": "lg", "idLabels": [], "idMembers": [], "shortLink": "StAt0000", "pos": 0, "desc": big})
json.dump([], open("%s/cards_st_actions.json" % d, "w"))
json.dump(cards, open("%s/boards_AbCd1234_cards.json" % d, "w"))
json.dump({"username": "andy"}, open("%s/members_mext0000.json" % d, "w"))
json.dump({}, open("%s/members_mgone000.json" % d, "w"))
json.dump({"id": "o1", "desc": "x\nREPORTER: @zed\n"}, open("%s/cards_ONe00001.json" % d, "w"))
json.dump([{"type": "createCard", "date": "2026-10-01T09:00:00.000Z", "idMemberCreator": "000000000000000000000002"}], open("%s/cards_ONe00001_actions.json" % d, "w"))
PY
run "$tmp/mc1" env PATH="$tmp/fakebin:$PATH" TRELLO_ENV_FILE="$tmp/trello.env" TRELLO_API_BASE=https://trello.test/1 "$bin/merged-cards.sh"
# the fake curl reads $tmp/trello: point it at the merged-cards fixtures
cp "$tmp"/mc/* "$tmp/trello/"
run "$tmp/mc1" env PATH="$tmp/fakebin:$PATH" TRELLO_ENV_FILE="$tmp/trello.env" TRELLO_API_BASE=https://trello.test/1 "$bin/merged-cards.sh"
ok "merged-cards: lists MERGED (35 cards with the status card) and RELEASING (1)" 'grep -qx "== MERGED (35 cards)" "$tmp/mc1" && grep -qx "== RELEASING (1 cards)" "$tmp/mc1"' "$(head -n 5 "$tmp/mc1")"
ok "merged-cards: a card not in those lists is not printed" '! grep -q ToDo0000 "$tmp/mc1"' "$(head -n 5 "$tmp/mc1")"
ok "merged-cards: 37 lines in all, none over 800 characters, whatever the card holds" '[ "$(wc -l <"$tmp/mc1" | tr -d " ")" = 38 ] && [ "$(awk "{ if (length(\$0) > m) m = length(\$0) } END { print m + 0 }" "$tmp/mc1")" -le 800 ]' "lines $(wc -l <"$tmp/mc1"), $(wc -c <"$tmp/mc1") bytes"
ok "merged-cards: the whole output stays under 15,000 bytes (the Trello list read was 48,000 for 26 cards)" '[ "$(wc -c <"$tmp/mc1" | tr -d " ")" -lt 15000 ]' "$(wc -c <"$tmp/mc1") bytes"
ok "merged-cards: a card's PR, merged commit (12 chars, new repo name), list date, label and revert show" 'grep -q "^MeRg0003 | .*labels: red | members: 0 | in list since: 2026-10-13 12:00 | prs: example-org/example-app#103 | merged: example-org/example-app#103@abcdef012345 | creator: internal | reverted: no$" "$tmp/mc1" && grep -q "^MeRg0005 .*reverted: yes$" "$tmp/mc1"' "$(grep -n 'MeRg000[35]' "$tmp/mc1" | cut -c1-400)"
ok "merged-cards: a PR comment naming the PR as owner/repo#N (no link) shows in prs:" 'grep -q "^MeRg0007 .* | prs: example-org/example-app#107 | " "$tmp/mc1"' "$(grep MeRg0007 "$tmp/mc1" | cut -c1-400)"
ok "merged-cards: an included card's MERGED WITH: commit shows as with:<ref>@<sha>, not merged: -" 'grep -q "^MeRg0006 .* | merged: with:example-org/example-app#900@abcdef012345 | creator: unknown | reverted: no$" "$tmp/mc1"' "$(grep MeRg0006 "$tmp/mc1" | cut -c1-400)"
ok "merged-cards: a status card gets its own short line" 'grep -q "^StAt0000 | ⛔ BLOCKED: user hold | labels: - | members: 0 | status card$" "$tmp/mc1"' "$(grep StAt "$tmp/mc1")"
ok "merged-cards: creator internal for the Claude account, the user's account and the RunnerCity Developer account" 'grep -q "^MeRg0003 .* | creator: internal | reverted" "$tmp/mc1" && grep -q "^MeRg0004 .* | creator: internal | reverted" "$tmp/mc1" && grep -q "^MeRg0008 .* | creator: internal | reverted" "$tmp/mc1"' "$(grep -E "MeRg000[348]" "$tmp/mc1" | cut -c1-30)"
ok "merged-cards: a creator that is not one of them is external with the username (and a copyCard counts)" 'grep -q "^MeRg0009 .* | creator: external @andy | reverted" "$tmp/mc1" && grep -q "^MeRg0012 .* | creator: external @andy | reverted" "$tmp/mc1"' "$(grep -E "MeRg00(09|12)" "$tmp/mc1" | cut -c1-30)"
ok "merged-cards: a REPORTER line below PR lines makes an agent-created card external, two reporters" 'grep -q "^MeRg0010 .* | creator: external @bo,@tess | reverted" "$tmp/mc1"' "$(grep MeRg0010 "$tmp/mc1" | cut -c1-300)"
ok "merged-cards: a creator whose username cannot be read is unknown" 'grep -q "^MeRg0011 .* | creator: unknown | reverted" "$tmp/mc1"' "$(grep MeRg0011 "$tmp/mc1" | cut -c1-300)"
run "$tmp/mc2" env PATH="$tmp/fakebin:$PATH" TRELLO_ENV_FILE="$tmp/trello.env" TRELLO_API_BASE=https://trello.test/1 "$bin/merged-cards.sh" --creator ONe00001
ok "merged-cards --creator: any card, an agent-created one with a REPORTER line is external" '[ "$(cat "$tmp/mc2")" = "creator: external @zed" ]' "$(cat "$tmp/mc2")"
run "$tmp/mc3" env PATH="$tmp/fakebin:$PATH" TRELLO_ENV_FILE="$tmp/trello.env" TRELLO_API_BASE=https://trello.test/1 "$bin/merged-cards.sh" --creator bad
ok "merged-cards --creator: a bad short link is a usage error (exit 2)" 'grep -q "^usage: merged-cards.sh" "$tmp/mc3"' "$(cat "$tmp/mc3")"


"$bin/verify/test-refusal-scan.sh" >"$tmp/refusal-scan.out" 2>&1; rs_rc=$?
ok "refusal_scan.py: only the two real refusal prefixes are records (verify/test-refusal-scan.sh)" '[ "$rs_rc" = 0 ]' "$(cat "$tmp/refusal-scan.out")"

echo
if [ "$failures" -eq 0 ]; then echo "All cases passed"; exit 0; fi
echo "$failures case(s) failed"; exit 1
