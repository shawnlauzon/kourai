#!/usr/bin/env bash
# Tests watcher-reload.sh in a temporary git repo (no network, no board).
# Usage: .claude/bin/test-watcher-reload.sh. Exits 0 when every case passes, 1 otherwise.
set -uo pipefail
export KOURAI_CONFIG=${KOURAI_CONFIG:-$(cd "$(dirname "$0")" && pwd)/fixtures/config.toml}
export KOURAI_BIN=${KOURAI_BIN:-$(cd "$(dirname "$0")/../bin" && pwd)}
bin=$(cd "$(dirname "$0")/../bin" && pwd)
tmp=$(mktemp -d)
# shellcheck disable=SC2329 # called by the EXIT trap
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
export WR_REPO=$tmp/repo WR_FILES=$tmp/files
wr() { "$bin/watcher-reload.sh" "$@"; }
G() { git -C "$WR_REPO" "$@"; }
failures=0
ok() { # ok <name> <expected text> <actual>
  if grep -qF -- "$2" <<<"$3"; then echo "PASS $1"; else echo "FAIL $1: wanted '$2', got '$3'"; failures=$((failures + 1)); fi
}
commit() { G add -A >/dev/null; G commit -q -m "$1" -m "${2:-}"; }
setup() { # fresh repo, base state
  rm -rf "$WR_REPO" "$WR_FILES"; mkdir -p "$WR_REPO/.claude/board" "$WR_REPO/.claude/agents"
  G init -q; G config user.email t@t; G config user.name t
  { echo "# rules"; for i in $(seq 1 400); do echo "rule line $i"; done; } >"$WR_REPO/.claude/board/rules.md"
  printf -- '---\nname: board-watcher\nmodel: opus\n---\nline a\nline b\n' >"$WR_REPO/.claude/agents/board-watcher.md"
  commit base
}
add_rules() { for i in $(seq 1 "$1"); do echo "new rule $i-$RANDOM"; done >>"$WR_REPO/.claude/board/rules.md"; }
inplace_once() { add_rules 3; commit "rules $RANDOM" "${1:-}"; }

setup; ok "baseline prints paths" "BASELINE:" "$(wr baseline)"
ok "NONE at base" "NONE" "$(wr check)"
add_rules 5; commit r1
ok "rules-only INPLACE" "INPLACE: rules.md" "$(wr check)"
ok "diff prints path" "DIFF: $WR_FILES/board-watcher-reload/diff.txt" "$(wr diff)"
ok "APPLIED after diff" "APPLIED:" "$(wr check)"
wr diff >/dev/null; ok "no double count" "count=1" "$(cat "$WR_FILES/board-watcher-reload.state")"
setup; wr baseline >/dev/null
echo "line c" >>"$WR_REPO/.claude/agents/board-watcher.md"; commit a1
ok "additive agent INPLACE" "INPLACE:" "$(wr check)"
setup; wr baseline >/dev/null
sed -i.bak 's/line b/line B/' "$WR_REPO/.claude/agents/board-watcher.md"; rm "$WR_REPO"/.claude/agents/*.bak; commit a2
ok "agent deletion RESTART" "RESTART: board-watcher.md diff deletes" "$(wr check)"
setup; wr baseline >/dev/null
sed -i.bak 's/opus/sonnet/' "$WR_REPO/.claude/agents/board-watcher.md"; rm "$WR_REPO"/.claude/agents/*.bak; commit a3
ok "frontmatter RESTART" "frontmatter changed" "$(wr check)"
setup; wr baseline >/dev/null
for i in $(seq 1 61); do echo "x$i"; done >>"$WR_REPO/.claude/agents/board-watcher.md"; commit a4
ok "agent over 60 RESTART" "adds 61 lines" "$(wr check)"
setup; wr baseline >/dev/null
add_rules 301; commit big
ok "rules over 300 RESTART" "rules.md diff too large" "$(wr check)"
setup; wr baseline >/dev/null
sed -i.bak '2,63d' "$WR_REPO/.claude/board/rules.md"; rm "$WR_REPO"/.claude/board/*.bak; commit del
ok "rules over 60 deleted RESTART" "deletes 62" "$(wr check)"
setup; wr baseline >/dev/null
for i in $(seq 1 150); do printf 'long line %s %0200d\n' "$i" 0; done >>"$WR_REPO/.claude/board/rules.md"; commit bytes
ok "30KB diff RESTART" "diff too large (3" "$(wr check)"
setup; wr baseline >/dev/null
inplace_once "Watcher: restart"
ok "trailer RESTART" "Watcher: restart trailer" "$(wr check)"
setup; ok "missing state RESTART" "RESTART: state missing" "$(wr check)"
# trial gate
setup; wr baseline >/dev/null
for n in 1 2 3; do inplace_once; wr diff >/dev/null; done
ok "count 3 with no change prints APPLIED, not RESTART" "APPLIED:" "$(wr check)"
inplace_once
ok "count 3 with a change asks" "RESTART: trial review (ask)" "$(wr check)"
wr asked; ok "asked" "RESTART: trial review (asked)" "$(wr check)"
touch "$WR_FILES/board-watcher-reload.ok"; ok ".ok allows" "INPLACE:" "$(wr check)"
rm "$WR_FILES/board-watcher-reload.ok"; wr reset
ok "reset" "INPLACE:" "$(wr check)"; ok "reset keeps base" "base_rules=" "$(cat "$WR_FILES/board-watcher-reload.state")"
# baseline right after a restart: NONE
wr baseline >/dev/null; ok "baseline after restart prints NONE" "NONE" "$(wr check)"
# changed then reverted: the line taken in place is withdrawn -> RESTART
setup; wr baseline >/dev/null
echo "2 approvals" >>"$WR_REPO/.claude/board/rules.md"; commit add
ok "added line INPLACE" "INPLACE:" "$(wr check)"; wr diff >/dev/null
G revert --no-edit HEAD >/dev/null
ok "changed then reverted RESTART" "RESTART: rules.md removes" "$(wr check)"
# loose trailer text is not a trailer
setup; wr baseline >/dev/null; inplace_once "Watcher: restarting soon"
ok "loose trailer text is INPLACE" "INPLACE:" "$(wr check)"
# race: baseline at A, change at B
setup; wr baseline >/dev/null; inplace_once
ok "race INPLACE" "INPLACE:" "$(wr check)"
# older agent commit
setup; old=$(G log -1 --format=%h); echo "line c" >>"$WR_REPO/.claude/agents/board-watcher.md"; commit a5
wr baseline --agent-commit "$old" >/dev/null
ok "older agent commit INPLACE" "INPLACE:" "$(wr check)"
ok "baseline copy is the old text" "0" "$(grep -c 'line c' "$WR_FILES/board-watcher-reload/board-watcher.md")"
# copies equal git show
setup; wr baseline >/dev/null; inplace_once
ok "copy equals base" "" "$(diff <(G show HEAD~1:.claude/board/rules.md) "$WR_FILES/board-watcher-reload/rules.md")"
# the trailer check reads the commit bodies through a variable, not a pipe into grep -q: with about 200 KB of
# bodies, SIGPIPE ignored (as in the agents' shells) and a board-watcher.md commit in the range, grep -q used to
# exit before git finished writing and the check came out false, so a trailer went unseen (INPLACE)
setup; wr baseline >/dev/null
echo "line c" >>"$WR_REPO/.claude/agents/board-watcher.md"; commit awatch
big=$(head -c 50000 /dev/zero | tr '\0' x)
for n in 1 2 3; do add_rules 3; commit "big $n" "$big"; done
add_rules 3; commit "big 4" "$big"$'\n\n'"Watcher: restart"
pipe_runs=$( (trap '' PIPE; for _ in $(seq 1 10); do wr check; done) 2>&1 )
pipe_seen=$(grep -c "RESTART: Watcher: restart trailer" <<<"$pipe_runs")
ok "trailer seen through 200 KB of bodies, 10 runs" "10" "$pipe_seen"
# Two-layer layout (after the switch-over): the app repo no longer holds board-watcher.md (the plugin ships it) and
# the project rules are project.rules_file, here in another folder than the default.
fixture_cfg=$KOURAI_CONFIG
setup2() {
  rm -rf "$WR_REPO" "$WR_FILES"; mkdir -p "$WR_REPO/.claude/board" "$WR_REPO/.claude/agents" "$WR_REPO/docs"
  G init -q; G config user.email t@t; G config user.name t
  { echo "# rules"; for i in $(seq 1 400); do echo "rule line $i"; done; } >"$WR_REPO/docs/project-rules.md"
  printf -- '---\nname: board-watcher\n---\nline a\n' >"$WR_REPO/.claude/agents/board-watcher.md"
  commit base2
  G rm -q .claude/agents/board-watcher.md; commit "switch: the agent moves to the plugin"
  sed "s#^name = \"example\"#name = \"example\"\nrules_file = \"$WR_REPO/docs/project-rules.md\"#" "$fixture_cfg" >"$tmp/two-layer.toml"
}
setup2
del=$(G log -1 --format=%h -- .claude/agents/board-watcher.md)
saved_cfg=$KOURAI_CONFIG; export KOURAI_CONFIG=$tmp/two-layer.toml
out=$(wr baseline --agent-commit "$del" 2>&1); rc=$?
ok "two-layer: baseline with the deletion commit succeeds" "BASELINE:" "$out"
ok "two-layer: baseline exit 0" "0" "$rc"
ok "two-layer: the baseline copy of the agent is the plugin's" "board-watcher" "$(head -5 "$WR_FILES/board-watcher-reload/board-watcher.md")"
ok "two-layer: NONE at base" "NONE" "$(wr check)"
for i in 1 2 3; do echo "new $i" >>"$WR_REPO/docs/project-rules.md"; done; commit r2
ok "two-layer: a rules change is seen (INPLACE)" "INPLACE: rules.md" "$(wr check)"
ok "two-layer: diff runs" "DIFF:" "$(wr diff)"
ok "two-layer: APPLIED after diff" "APPLIED:" "$(wr check)"
setup2; wr baseline >"$tmp/b.out" 2>&1; cat "$tmp/b.out"
ok "two-layer: baseline without --agent-commit succeeds" "plugin" "$(cat "$WR_FILES/board-watcher-reload.state")"
export KOURAI_CONFIG=$saved_cfg
[ "$failures" = 0 ] && echo "ALL PASSED" || { echo "$failures FAILED"; exit 1; }
