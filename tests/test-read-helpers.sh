#!/usr/bin/env bash
# Tests the read helpers: .claude/bin/card-summary.sh and pr-ready.sh.
#
# Usage: .claude/bin/test-read-helpers.sh
#
# Nothing real is read: a fake `curl` answers Trello requests from files in a
# temporary folder, a fake `gh` answers PR reads, and a fake review policy prints
# a fixed line. A few seconds. Exits 0 when every case passes, 1 otherwise.
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

mkdir -p "$tmp/fakebin" "$tmp/trello" "$tmp/gh"
printf 'TRELLO_KEY=k\nTRELLO_TOKEN=t\n' >"$tmp/trello.env"
export TRELLO_ENV_FILE=$tmp/trello.env TRELLO_API_BASE=https://trello.test/1

# Fake curl: `curl -sf -o <file> <url>` copies $tmp/trello/<path with / as _>.json
# to <file>; a missing fixture fails like a Trello error.
cat >"$tmp/fakebin/curl" <<EOF
#!/usr/bin/env bash
out="" url=""
while [ \$# -gt 0 ]; do
  case "\$1" in -o) out=\$2; shift 2 ;; -*) shift ;; *) url=\$1; shift ;; esac
done
path=\${url#https://trello.test/1/}; path=\${path%%\\?*}
f=$tmp/trello/\${path//\//_}.json
[ -f "\$f" ] || exit 22
# Like Trello, a card read with fields=... returns only those fields (and id): labels only when listed.
case "\$url" in
  *"?fields="*|*"&fields="*)
    fl=\${url#*fields=}; fl=\${fl%%&*}
    python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); k=set(sys.argv[2].split(",")) | {"id"}
print(json.dumps({a: b for a, b in d.items() if a in k}) if isinstance(d, dict) else json.dumps(d))' "\$f" "\$fl" >"\$f.filtered"
    f=\$f.filtered ;;
esac
if [ -n "\$out" ]; then cp "\$f" "\$out"; else cat "\$f"; fi
EOF
# Fake gh: pr view <n> --repo <owner/repo> --json … prints $tmp/gh/<repo with / as _>-<n>.json;
# pr checks prints …-<n>-checks.json, …-<n>-checks.err on stderr, and exits with
# …-<n>-checks.rc (default 0).
cat >"$tmp/fakebin/gh" <<EOF
#!/usr/bin/env bash
n=\$3 repo=""
for ((i = 1; i <= \$#; i++)); do [ "\${!i}" = --repo ] && { j=\$((i + 1)); repo=\${!j}; }; done
base=$tmp/gh/\${repo//\//_}-\$n
case "\$1 \$2" in
  "pr view") cat "\$base.json" ;;
  "pr checks") cat "\$base-checks.json" 2>/dev/null; cat "\$base-checks.err" >&2 2>/dev/null; exit "\$(cat "\$base-checks.rc" 2>/dev/null || echo 0)" ;;
  *) exit 9 ;;
esac
EOF
cat >"$tmp/policy" <<'EOF'
#!/usr/bin/env bash
case "$2" in
  *example-api*) echo "REVIEW NEEDED: $2 changes app/controllers/"; exit 1 ;;
  *) echo "NO REVIEW NEEDED: $2 changes only test/ and Markdown"; exit 0 ;;
esac
EOF
chmod +x "$tmp/fakebin/curl" "$tmp/fakebin/gh" "$tmp/policy"
export PATH="$tmp/fakebin:$PATH" REVIEW_POLICY=$tmp/policy

USER_ID=000000000000000000000001 CLAUDE_ID=000000000000000000000002
cat >"$tmp/trello/cards_AbCd1234.json" <<'EOF'
{"id":"c1","name":"Fix the login button (#12, server #34)","idList":"l1","idMembers":[],
 "labels":[{"name":"Actively worked","color":"green"}],
 "desc":"**PR:** example-user/example-app-old#12, https://github.com/example-user/example-app-old/pull/12 (app fix)\n**PR:** example-org/example-api#34, https://github.com/example-org/example-api/pull/34 (server fix)\n**PR:** example-user/example-app-old#9, https://github.com/example-user/example-app-old/pull/9 (first try) (closed, replaced by #12)\n**PR:** example-user/example-app-old#7, https://github.com/example-user/example-app-old/pull/7 (old fix) (reverted by example-user/example-app-old#8)\n**PR:** example-org/example-api#30, https://github.com/example-org/example-api/pull/30 (part one) (included in example-org/example-api#34)\n**User hold:** hold MERGING until Friday, because the release is frozen while the user reviews the new onboarding flow end to end on both phones, and nothing may merge in between, not even docs\nsecond line of the hold\n\nThe login button is cut off."}
EOF
echo '{"id":"l1","name":"BUILDING"}' >"$tmp/trello/lists_l1.json"
cat >"$tmp/trello/cards_AbCd1234_actions.json" <<EOF
[
 {"date":"2026-10-15T10:05:00.000Z","idMemberCreator":"$USER_ID","data":{"text":"Please also check the tablet size."}},
 {"date":"2026-10-15T10:00:00.000Z","idMemberCreator":"$CLAUDE_ID","data":{"text":"TEST FAILED: [Mobile] the button is still cut off on the small phone"}},
 {"date":"2026-10-15T09:30:00.000Z","idMemberCreator":"$CLAUDE_ID","data":{"text":"USER REPLY (2026-10-14): use the tablet layout\n\nUNBLOCKED: the layout is decided"}},
 {"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"$CLAUDE_ID","data":{"text":"PR: https://github.com/example-org/example-api/pull/34"}},
 {"date":"2026-10-15T08:30:00.000Z","idMemberCreator":"$CLAUDE_ID","data":{"text":"TEST FAILED: [Server] older failure"}},
 {"date":"2026-10-15T08:00:00.000Z","idMemberCreator":"$CLAUDE_ID","data":{"text":"BEFORE: mobile card/AbCd1234-login @ abc, development card/AbCd1234-login @ def"}},
 {"date":"2026-10-15T07:00:00.000Z","idMemberCreator":"$CLAUDE_ID","data":{"text":"just a plain note"}}
]
EOF

out=$("$bin/card-summary.sh" AbCd1234 2>&1); rc=$?
check() { if grep -qF -- "$2" <<<"$out"; then pass "card-summary: $1"; else fail "card-summary: $1" "missing '$2' in: $out"; fi; }
if [ "$rc" = 0 ]; then pass "card-summary: exit 0"; else fail "card-summary: exit 0" "rc=$rc"; fi
check "name and list" "AbCd1234 | Fix the login button (#12, server #34) | list: BUILDING"
check "labels" "labels: Actively worked"
check "a status card's user hold, whole" "nothing may merge in between, not even docs second line of the hold"
check "the card ARI for writes" "ari: ari:cloud:trello::card/workspace/000000000000000000000000/c1"
check "open PRs from the description" "PRs: example-user/example-app-old#12, example-org/example-api#34"
check "closed PRs named as closed" "closed: example-user/example-app-old#9"
check "reverted and included PRs are not open" "closed: example-user/example-app-old#9, example-user/example-app-old#7, example-org/example-api#30"
check "newest phrase per kind" "TEST FAILED: 2026-10-15 10:00 [Mobile] the button is still cut off"
check "BEFORE phrase" "BEFORE: 2026-10-15 08:00 mobile card/AbCd1234-login"
check "newest user comment" "user: 2026-10-15 10:05 Please also check the tablet size."
check "a USER REPLY with a note before the colon is listed as USER REPLY" "USER REPLY: 2026-10-15 09:30 use the tablet layout"
if grep -qF -- "older failure" <<<"$out"; then fail "card-summary: only the newest of a phrase" "$out"; else pass "card-summary: only the newest of a phrase"; fi
if grep -qF -- "is cut off." <<<"$out"; then fail "card-summary: never prints the description" "$out"; else pass "card-summary: never prints the description"; fi
"$bin/card-summary.sh" NoSuch12 >/dev/null 2>&1; rc=$?
if [ "$rc" = 1 ]; then pass "card-summary: a Trello failure exits 1"; else fail "card-summary: Trello failure" "rc=$rc"; fi

# A second card: a "ship" buried under UNBLOCKED:, and two STAGING PUSH comments
cat >"$tmp/trello/cards_EfGh5678.json" <<'EOT'
{"id":"c2","name":"Release card","idList":"l1","idMembers":[],"labels":[],"desc":""}
EOT
cat >"$tmp/trello/cards_EfGh5678_actions.json" <<EOT
[
 {"date":"2026-10-15T12:10:00.000Z","idMemberCreator":"$USER_ID","data":{"text":"thanks, unrelated note"}},
 {"date":"2026-10-15T12:00:00.000Z","idMemberCreator":"$CLAUDE_ID","data":{"text":"UNBLOCKED: the user answered"}},
 {"date":"2026-10-15T11:50:00.000Z","idMemberCreator":"$USER_ID","data":{"text":"ship"}},
 {"date":"2026-10-15T11:00:00.000Z","idMemberCreator":"$CLAUDE_ID","data":{"text":"STAGING PUSH: development @ new from old, migrations: no"}},
 {"date":"2026-10-15T10:00:00.000Z","idMemberCreator":"$CLAUDE_ID","data":{"text":"GREEN*: one unrelated failure"}},
 {"date":"2026-10-15T09:00:00.000Z","idMemberCreator":"$CLAUDE_ID","data":{"text":"STAGING PUSH: development @ old from older, migrations: yes"}}
]
EOT
out=$("$bin/card-summary.sh" EfGh5678 2>&1)
check "the user's ship after GREEN* shows though UNBLOCKED: and a later unrelated comment are newer" "answer after GREEN*: ship 2026-10-15 11:50 ship"
if grep -qF -- "migrations: yes" <<<"$out"; then fail "card-summary: default shows the newest STAGING PUSH only" "$out"; else pass "card-summary: default shows the newest STAGING PUSH only"; fi
check "the later unrelated user comment is still shown as user:" "user: 2026-10-15 12:10 thanks, unrelated note"
out=$("$bin/card-summary.sh" EfGh5678 --all "STAGING PUSH,STAGING MIGRATED" 2>&1)
check "--all lists the earlier push with migrations: yes" "STAGING PUSH: 2026-10-15 09:00 development @ old from older, migrations: yes"
check "--all lists the newest push too" "STAGING PUSH: 2026-10-15 11:00 development @ new from old, migrations: no"
if grep -qF -- "UNBLOCKED:" <<<"$out"; then pass "card-summary: --all keeps other phrases to the newest"; else fail "card-summary: --all keeps other phrases" "$out"; fi
"$bin/card-summary.sh" EfGh5678 --all >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ]; then pass "card-summary: --all without phrases is a usage error"; else fail "card-summary: --all usage" "rc=$rc"; fi

# Agent comments posted under the wrong account (the user's): never `user:`, listed as a phrase line
for k in WrgA1111 WrgB1111 WrgC1111; do echo "{\"id\":\"$k\",\"name\":\"Wrong account\",\"idList\":\"l1\",\"idMembers\":[],\"labels\":[],\"desc\":\"\"}" >"$tmp/trello/cards_$k.json"; done
cat >"$tmp/trello/cards_WrgA1111_actions.json" <<EOT
[
 {"date":"2026-10-15T12:00:00.000Z","idMemberCreator":"$USER_ID","data":{"text":"FULL SUITE FAILED: main @ a, development @ b: x"}},
 {"date":"2026-10-15T11:00:00.000Z","idMemberCreator":"$CLAUDE_ID","data":{"text":"PROMOTING: development @ b, main @ a"}}
]
EOT
cat >"$tmp/trello/cards_WrgB1111_actions.json" <<EOT
[
 {"date":"2026-10-15T12:00:00.000Z","idMemberCreator":"$USER_ID","data":{"text":"CHECK FAILED: x#1: red"}},
 {"date":"2026-10-15T11:00:00.000Z","idMemberCreator":"$USER_ID","data":{"text":"Please look at this"}}
]
EOT
cat >"$tmp/trello/cards_WrgC1111_actions.json" <<EOT
[
 {"date":"2026-10-15T12:30:00.000Z","idMemberCreator":"$USER_ID","data":{"text":"ship"}},
 {"date":"2026-10-15T12:00:00.000Z","idMemberCreator":"$USER_ID","data":{"text":"GREEN*: main @ a, development @ b"}}
]
EOT
out=$("$bin/card-summary.sh" WrgA1111 2>&1)
check "a non-Claude FULL SUITE FAILED: is one phrase line marked wrong account" "FULL SUITE FAILED: 2026-10-15 12:00 main @ a, development @ b: x (wrong account)"
if grep -q "^user:" <<<"$out"; then fail "card-summary: a wrong-account agent comment is never user:" "$out"; else pass "card-summary: a wrong-account agent comment is never user:"; fi
out=$("$bin/card-summary.sh" WrgB1111 2>&1)
check "a non-Claude CHECK FAILED: is a wrong-account phrase line" "CHECK FAILED: 2026-10-15 12:00 x#1: red (wrong account)"
check "a plain non-Claude comment is still user:" "user: 2026-10-15 11:00 Please look at this"
out=$("$bin/card-summary.sh" WrgC1111 2>&1)
check "a non-Claude GREEN*: anchors the user's ship (as staging-gate.sh does)" "answer after GREEN*: ship 2026-10-15 12:30 ship"

# Another person's comment (neither the user nor the Claude account) is other:, never user: and never a ship
echo '{"id":"OthA1111","name":"Other person","idList":"l1","idMembers":[],"labels":[],"desc":""}' >"$tmp/trello/cards_OthA1111.json"
cat >"$tmp/trello/cards_OthA1111_actions.json" <<EOT
[
 {"date":"2026-10-15T12:30:00.000Z","idMemberCreator":"aaaaaaaaaaaaaaaaaaaaaaaa","data":{"text":"ship"}},
 {"date":"2026-10-15T12:00:00.000Z","idMemberCreator":"$CLAUDE_ID","data":{"text":"GREEN*: main @ a, development @ b"}}
]
EOT
out=$("$bin/card-summary.sh" OthA1111 2>&1)
check "another person's comment is other:" "other: 2026-10-15 12:30 ship"
case "$out" in
  *user:*|*"answer after GREEN"*) fail "card-summary: another person's comment is never user: or a ship" "$out" ;;
  *) pass "card-summary: another person's comment is never user: or a ship" ;;
esac

# --- pr-ready.sh -----------------------------------------------------------------
cat >"$tmp/gh/example-user_example-app-old-12.json" <<'EOF'
{"state":"OPEN","headRefOid":"1111111aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","mergeable":"MERGEABLE","body":"Fix.\n\n## Feature test\nAll passed."}
EOF
echo '[{"name":"flutter-test","bucket":"pass"}]' >"$tmp/gh/example-user_example-app-old-12-checks.json"
cat >"$tmp/gh/example-org_example-api-34.json" <<'EOF'
{"state":"OPEN","headRefOid":"2222222bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","mergeable":"CONFLICTING","body":"Fix.\nApp-visible: yes — the login response changes\nBehavior tests: the feature tester's (FUNCTION)"}
EOF
echo '[{"name":"ci","bucket":"fail"},{"name":"lint","bucket":"pending"}]' >"$tmp/gh/example-org_example-api-34-checks.json"

out=$("$bin/pr-ready.sh" AbCd1234 2>&1); rc=$?
check2() { if grep -qF -- "$2" <<<"$out"; then pass "pr-ready: $1"; else fail "pr-ready: $1" "missing '$2' in: $out"; fi; }
if [ "$rc" = 0 ]; then pass "pr-ready: exit 0"; else fail "pr-ready: exit 0" "rc=$rc"; fi
check2 "mobile PR line" "example-user/example-app-old#12 | head 1111111aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa | OPEN | CI: GREEN | MERGEABLE | feature test: yes | App-visible: missing | NO REVIEW NEEDED"
check2 "server PR line" "example-org/example-api#34 | head 2222222bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb | OPEN | CI: RUNNING lint; RED ci | CONFLICTING | feature test: placeholder | App-visible: yes | REVIEW NEEDED"
if grep -qF -- "example-app#9 " <<<"$out"; then fail "pr-ready: closed PRs left out" "$out"; else pass "pr-ready: closed PRs left out"; fi
if grep -qE -- "example-app#7 |example-api#30 " <<<"$out"; then fail "pr-ready: reverted and included PRs left out" "$out"; else pass "pr-ready: reverted and included PRs left out"; fi

# A gh pr checks failure is CI: ERROR; only gh's "no checks reported" is NO CHECKS.
cat >"$tmp/trello/cards_ErRo1234.json" <<'EOF'
{"id":"c2","name":"Checks (#40, #41)","idList":"l1","idMembers":[],"labels":[],
 "desc":"**PR:** example-user/example-app-old#40, https://github.com/example-user/example-app-old/pull/40 (a)\n**PR:** example-user/example-app-old#41, https://github.com/example-user/example-app-old/pull/41 (b)"}
EOF
for n in 40 41; do
  echo '{"state":"OPEN","headRefOid":"3333333ccccccccccccccccccccccccccccccccc","mergeable":"MERGEABLE","body":"## Feature test"}' >"$tmp/gh/example-user_example-app-old-$n.json"
  echo 1 >"$tmp/gh/example-user_example-app-old-$n-checks.rc"
done
echo "HTTP 502: Bad Gateway (https://api.github.com/graphql)" >"$tmp/gh/example-user_example-app-old-40-checks.err"
echo "no checks reported on the 'card/ErRo1234-x' branch" >"$tmp/gh/example-user_example-app-old-41-checks.err"
out=$("$bin/pr-ready.sh" ErRo1234 2>/dev/null); rc=$?
check2 "a gh failure is CI: ERROR" "example-user/example-app-old#40 | head 3333333ccccccccccccccccccccccccccccccccc | OPEN | CI: ERROR |"
check2 "gh's no checks reported is NO CHECKS" "example-user/example-app-old#41 | head 3333333ccccccccccccccccccccccccccccccccc | OPEN | CI: NO CHECKS |"

echo
if [ "$failures" -eq 0 ]; then echo "All cases passed"; exit 0; fi
echo "$failures case(s) failed"; exit 1
