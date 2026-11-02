#!/bin/bash
# Test of review-policy.sh: an approval survives any merge of the base into the PR's
# branch, even with a "Behavior change:" resolution note ("[AGENTS] A remerge never needs
# another approval", https://trello.com/c/w2BWB0Su). Real git in a temporary directory, a
# fake gh, no network.
# Usage: test-remerge-approval.sh <review-policy.sh to test> [old]
#   old: the cases for today's hook: a behavior-changing note voids the approval.
set -u
export KOURAI_CONFIG=${KOURAI_CONFIG:-$(cd "$(dirname "$0")" && pwd)/fixtures/config.toml}
export KOURAI_BIN=${KOURAI_BIN:-$(cd "$(dirname "$0")/../bin" && pwd)}
hook=${1:-$(cd "$(dirname "$0")/../hooks" && pwd)/review-policy.sh}
mode=${2:-new}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/clone" 2>/dev/null
g() { git -C "$T/clone" "$@"; }
g checkout -q -b main; mkdir -p "$T/clone/lib"; echo base >"$T/clone/lib/x.dart"
g add -A; g commit -q -m base; g push -q origin main
g checkout -q -b card; echo mine >>"$T/clone/lib/x.dart"; g commit -qam mine
A=$(g rev-parse HEAD)
g checkout -q main; echo theirs >>"$T/clone/lib/x.dart"; g commit -qam theirs; g push -q origin main
g checkout -q card; g merge -q main >/dev/null 2>&1; printf 'base\nmine\ntheirs\n' >"$T/clone/lib/x.dart"; g commit -qam "merge main"
M=$(g rev-parse HEAD)
push_pr() { g push -q -f origin "$1:refs/pull/5/head"; g push -q -f origin "$1:refs/heads/card"; }
# fake gh: answers from files in $T
mkdir "$T/bin"; cat >"$T/bin/gh" <<'GH'
#!/bin/bash
args="$*"
case "$args" in
  *pulls/5/files*) echo "lib/x.dart" ;;
  *pulls/5/reviews*) cat "$FAKE/reviews" ;;
  *issues/5/comments*) cat "$FAKE/comments" ;;
  *pulls/5) cat "$FAKE/pr" ;;
  *) exit 1 ;;
esac
GH
chmod +x "$T/bin/gh"
export FAKE="$T/f"; mkdir "$FAKE"
sed -e "s#/Users/shawn/Development/github/example-app#$T/clone#" -e "s#/Users/shawn/Development/github/example-api#$T/clone#" "$KOURAI_CONFIG" >"$T/config.toml"; export KOURAI_CONFIG=$T/config.toml
cp "$hook" "$T/hook.sh"
review() { echo '[{"user":{"login":"example-user"},"state":"APPROVED","commit_id":"'$A'","submitted_at":"2026-10-16T10:00:00Z"}]' >"$FAKE/reviews"; }
pr() { echo '{"head":{"sha":"'$1'"},"base":{"ref":"main"},"body":""}' >"$FAKE/pr"; }
note() { printf '[{"created_at":"2026-10-16T11:00:00Z","body":"Merge conflict resolution\\n%s"}]' "$1" >"$FAKE/comments"; }
pass=0 fail=0
run() { # name want [repo, default the mobile one]
  local out; out=$(PATH="$T/bin:$PATH" bash "$T/hook.sh" check "${3:-example-org/example-app}#5")
  if [[ "$out" == "$2"* ]]; then pass=$((pass+1)); echo "PASS $1"; else fail=$((fail+1)); echo "FAIL $1: want $2, got: $out"; fi
}
review; pr "$M"; push_pr "$M"
note "Behavior change: none"
run "a remerge with a no-change note keeps the approval" APPROVED
note "Behavior change: the banner now shows both titles"
if [ "$mode" = old ]; then run "OLD: a behavior-changing note voids the approval" "REVIEW NEEDED"
else run "a remerge with a behavior-changing note keeps the approval" APPROVED; fi
echo '[]' >"$FAKE/comments"
run "a remerge with no note keeps the approval" APPROVED
# The server repo's AFTER tests live in tests/integration/; the mobile repo's do not.
g checkout -q -b server-after "$M"; mkdir -p "$T/clone/tests/integration"; echo t >"$T/clone/tests/integration/x.test.ts"
g add -A; g commit -qm "test: server after run"
S=$(g rev-parse HEAD); pr "$S"; push_pr server-after
SRV=example-org/example-api
if [ "$mode" = old ]; then run "OLD: a server remerge then a tests/integration/ commit voids the approval" "REVIEW NEEDED" $SRV
else run "a server remerge then a tests/integration/ commit keeps the approval" APPROVED $SRV
  run "a mobile remerge then a tests/ commit voids the approval" "REVIEW NEEDED"; fi
# A file moved out of lib/ into test/ is still a change to app code.
g checkout -q -b moved "$M"; mkdir -p "$T/clone/test"; g mv lib/x.dart test/moved_x.dart; g commit -qm "move lib to test"
V=$(g rev-parse HEAD); pr "$V"; push_pr moved
run "a remerge then a rename from lib/ to test/ voids the approval" "REVIEW NEEDED"
g checkout -q card; pr "$M"; push_pr card
# The AFTER run's commits: tests and screenshots only.
g checkout -q card; mkdir -p "$T/clone/test" "$T/clone/docs"; echo t >"$T/clone/test/x_test.dart"; echo s >"$T/clone/docs/shot.png"
g add -A; g commit -qm "test: after run"
P=$(g rev-parse HEAD); pr "$P"; push_pr card
if [ "$mode" = old ]; then run "OLD: a test-only commit after the remerge voids the approval" "REVIEW NEEDED"
else run "a remerge then a test-only commit keeps the approval" APPROVED; fi
echo extra >>"$T/clone/lib/x.dart"; g commit -qam "plain commit"
P=$(g rev-parse HEAD); pr "$P"; push_pr card
run "a remerge then a lib/ commit voids the approval" "REVIEW NEEDED"
echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
