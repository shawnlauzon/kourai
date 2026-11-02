#!/bin/bash
# Test of code-review-check.sh: real git in a temporary directory (a bare origin and a clone),
# a fake gh, no network. Cases: not app code, no review, a review with must-fix, a review at
# the head, a base merge after the review, a test-only commit after, a lib/ commit after, a
# non-bot comment, the old repo name, the newest review wins, the server repo.
set -u
export KOURAI_CONFIG=${KOURAI_CONFIG:-$(cd "$(dirname "$0")" && pwd)/fixtures/config.toml}
export KOURAI_BIN=${KOURAI_BIN:-$(cd "$(dirname "$0")/../bin" && pwd)}
bin=$(cd "$(dirname "$0")/../bin" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/clone" 2>/dev/null
g() { git -C "$T/clone" "$@"; }
g checkout -q -b main; mkdir -p "$T/clone/lib" "$T/clone/test"; echo base >"$T/clone/lib/x.dart"; echo t >"$T/clone/test/x_test.dart"
g add -A; g commit -q -m base; g push -q origin main
g checkout -q -b card; echo mine >>"$T/clone/lib/x.dart"; g commit -qam mine
R=$(g rev-parse HEAD)                                  # the reviewed commit
g checkout -q main; echo theirs >"$T/clone/lib/y.dart"; g add -A; g commit -qm theirs; g push -q origin main
g checkout -q card; g merge -q --no-edit main >/dev/null 2>&1                # a merge of the base
MERGE=$(g rev-parse HEAD)
echo more >>"$T/clone/test/x_test.dart"; g commit -qam "test: more"; TESTC=$(g rev-parse HEAD)
echo code >>"$T/clone/lib/x.dart"; g commit -qam "code"; CODE=$(g rev-parse HEAD)
g checkout -q -b other "$R"; echo side >"$T/clone/lib/z.dart"; g add -A; g commit -qm side; SIDE=$(g rev-parse HEAD)
g checkout -q "$MERGE" 2>/dev/null; g merge -q --no-edit other >/dev/null 2>&1; SIDEMERGE=$(g rev-parse HEAD)   # merges a side branch, not the base
push_pr() { g push -q -f origin "$1:refs/pull/5/head"; }
push_pr "$MERGE"

mkdir "$T/bin"; cat >"$T/bin/gh" <<'GH'
#!/bin/bash
args="$*"
case "$args" in
  *pulls/5/files*) cat "$FAKE/files" ;;
  *issues/5/comments*) cat "$FAKE/comments" ;;
  *pulls/5) cat "$FAKE/pr" ;;
  *) exit 1 ;;
esac
GH
chmod +x "$T/bin/gh"
export FAKE="$T/f"; mkdir "$FAKE"
export CODE_REVIEW_GH=$T/bin/gh CODE_REVIEW_APP_CLONE=$T/clone CODE_REVIEW_SERVER_CLONE=$T/clone
pr() { echo '{"head":{"sha":"'$1'"},"base":{"ref":"main"}}' >"$FAKE/pr"; }
files() { printf '%s\n' "$@" >"$FAKE/files"; }
# comment <login> <repo> <sha> <k> <created_at>   (appended to the list in $FAKE/list)
: >"$FAKE/list"
comment() { printf '{"user":{"login":"%s"},"created_at":"%s","body":"CODE REVIEW: %s#5 @ %s: %s must-fix, 1 notes\\n\\nMust fix\\n1. x"}\n' "$1" "$5" "$2" "$3" "$4" >>"$FAKE/list"; jq -s '.' "$FAKE/list" >"$FAKE/comments"; }
reset() { : >"$FAKE/list"; echo '[]' >"$FAKE/comments"; }
pass=0 fail=0
run() { # name want [repo]
  local out; out=$(PATH="$T/bin:$PATH" "$bin/code-review-check.sh" "${3:-example-org/example-app}#5")
  if [[ "$out" == "$2"* ]]; then pass=$((pass+1)); echo "PASS $1"; else fail=$((fail+1)); echo "FAIL $1: want $2, got: $out"; fi
}
APPR=example-org/example-app BOT='example-bot[bot]'

reset; pr "$MERGE"; files README.md .claude/agents/x.md
run "docs and agent files only: not needed" "CODE REVIEW NOT NEEDED: $APPR#5: AGENTS"
files test/x_test.dart
run "tests only: not needed" "CODE REVIEW NOT NEEDED: $APPR#5: TESTS"
files lib/x.dart test/x_test.dart
run "app code and no review comment: needed" "CODE REVIEW NEEDED: $APPR#5 @ $MERGE: no code review yet"
reset; comment someone-else $APPR "$MERGE" 0 2026-10-17T10:00:00Z
run "a review by someone else is ignored" "CODE REVIEW NEEDED: $APPR#5 @ $MERGE: no code review yet"
reset; comment "$BOT" $APPR "$MERGE" 2 2026-10-17T10:00:00Z
run "a review of the head with must-fix: needed" "CODE REVIEW NEEDED: $APPR#5 @ $MERGE: the review of ${MERGE:0:7} has 2 must-fix"
reset; comment "$BOT" $APPR "$MERGE" 0 2026-10-17T10:00:00Z
run "a clean review of the head: ok" "CODE REVIEW OK: $APPR#5: reviewed its head ${MERGE:0:7}"
reset; comment "$BOT" example-user/example-app-old "$MERGE" 0 2026-10-17T10:00:00Z
run "the old repo name in the review line is accepted" "CODE REVIEW OK: $APPR#5: reviewed its head"
reset; comment "$BOT" $APPR "$R" 0 2026-10-17T10:00:00Z
run "a clean review, then only a merge of the base: ok" "CODE REVIEW OK: $APPR#5: reviewed ${R:0:7}; since then only merges of main"
pr "$TESTC"; push_pr "$TESTC"
run "then a test-only commit: ok" "CODE REVIEW OK: $APPR#5: reviewed ${R:0:7}; since then only merges of main and commits without"
pr "$CODE"; push_pr "$CODE"
run "then a lib/ commit: needed" "CODE REVIEW NEEDED: $APPR#5 @ $CODE: reviewed ${R:0:7}, not its head ${CODE:0:7}; commit ${CODE:0:7} since then changes app or server code (lib/x.dart)"
pr "$SIDEMERGE"; push_pr "$SIDEMERGE"
run "a merge of something that is not the base: needed" "CODE REVIEW NEEDED: $APPR#5 @ $SIDEMERGE:"
pr "$MERGE"; push_pr "$MERGE"
comment "$BOT" $APPR "$MERGE" 1 2026-10-17T12:00:00Z
run "the newest review wins (a later one with must-fix)" "CODE REVIEW NEEDED: $APPR#5 @ $MERGE: the review of ${MERGE:0:7} has 1 must-fix"
reset; comment "$BOT" $APPR "$MERGE" 3 2026-10-17T10:00:00Z; comment "$BOT" $APPR "$MERGE" 0 2026-10-17T12:00:00Z
run "the newest review wins (a later clean one)" "CODE REVIEW OK: $APPR#5: reviewed its head"
reset; comment "$BOT" $APPR "$SIDE" 0 2026-10-17T10:00:00Z
run "a review of a commit that is not in the head's history: needed" "CODE REVIEW NEEDED: $APPR#5 @ $MERGE: reviewed ${SIDE:0:7}, not its head ${MERGE:0:7}, and the reviewed commit is no longer in its history"
# the server repo: tests/ is not code, app/ is
SRV=example-org/example-api
reset; files app/models/user.rb tests/integration/a.test.ts; pr "$MERGE"
run "server code with no review: needed" "CODE REVIEW NEEDED: $SRV#5 @ $MERGE: no code review yet" $SRV
comment "$BOT" $SRV "$MERGE" 0 2026-10-17T10:00:00Z
run "server code with a clean review of the head: ok" "CODE REVIEW OK: $SRV#5: reviewed its head" $SRV
files tests/integration/a.test.ts docs/x.md
run "server tests and docs only: not needed" "CODE REVIEW NOT NEEDED: $SRV#5: TESTS" $SRV
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
