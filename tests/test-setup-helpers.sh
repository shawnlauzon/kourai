#!/usr/bin/env bash
# The checks are single-quoted on purpose: ok() evals them after each run, and
# the worktree variables they name are read there.
# shellcheck disable=SC2016,SC2034
# Tests the setup helpers: .claude/bin/agent-worktree.sh, schema-dump.sh and
# fraud-stripe.sh.
#
# Usage: .claude/bin/test-setup-helpers.sh
#
# Nothing real is touched: the repos are throwaway git repos in a temporary
# folder (with a bare "origin"), `bin/rails` and `curl` are fakes that record how
# they were called, and dependency installs are skipped (RC_SKIP_DEPS=1). A few
# seconds. Exits 0 when every case passes, 1 otherwise.
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

# --- throwaway repos -------------------------------------------------------------
mkrepo() { # mkrepo <name> <base branch>: a bare origin and a clone at $tmp/<name>
  git init -q --bare "$tmp/$1.git"
  git init -q -b "$2" "$tmp/$1"
  git -C "$tmp/$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$tmp/$1" remote add origin "$tmp/$1.git"
  git -C "$tmp/$1" push -q origin "$2"
}
mkrepo mobile main
mkrepo server development
for f in .env .env.development .env.staging .env.production .env.local .env.e2e; do echo "secret-$f" >"$tmp/mobile/$f"; done
echo dev-local >"$tmp/server/.env.development.local"
export RC_MOBILE_ROOT=$tmp/mobile RC_SERVER_ROOT=$tmp/server RC_SKIP_DEPS=1

run() { local out=$1; shift; "$@" >"$out" 2>&1; echo $? >"$out.rc"; }
rc() { cat "$1.rc"; }

# --- agent-worktree.sh -----------------------------------------------------------
run "$tmp/a1" "$bin/agent-worktree.sh" mobile-builder AbCd1234 mobile
w=$tmp/mobile/.claude/worktrees/mobile-builder-AbCd1234
ok "worktree: mobile builder's worktree made" '[ "$(rc "$tmp/a1")" = 0 ] && [ -d "$w" ] && grep -qx "WORKTREE: $w" "$tmp/a1"' "rc=$(rc "$tmp/a1") $(cat "$tmp/a1")"
ok "worktree: mobile builder gets empty placeholders, not the real env files" '[ -f "$w/.env" ] && [ ! -L "$w/.env" ] && [ ! -s "$w/.env" ] && [ -f "$w/.env.staging" ]'
ok "worktree: detached at origin/main" '[ "$(git -C "$w" rev-parse HEAD)" = "$(git -C "$tmp/mobile" rev-parse origin/main)" ]'

run "$tmp/a2" "$bin/agent-worktree.sh" mobile-builder AbCd1234 mobile
ok "worktree: a second run reuses it" '[ "$(rc "$tmp/a2")" = 0 ] && grep -qx "WORKTREE: $w" "$tmp/a2"' "rc=$(rc "$tmp/a2") $(cat "$tmp/a2")"

run "$tmp/a3" "$bin/agent-worktree.sh" feature-tester AbCd1234 mobile
w3=$tmp/mobile/.claude/worktrees/feature-tester-AbCd1234
ok "worktree: feature tester links the real env files" '[ -L "$w3/.env" ] && [ "$(readlink "$w3/.env")" = "$tmp/mobile/.env" ] && [ -L "$w3/.env.e2e" ]'
ok "worktree: feature tester gets no other env file (never .env.production)" '[ ! -e "$w3/.env.development" ] && [ ! -e "$w3/.env.staging" ] && [ ! -e "$w3/.env.production" ] && [ ! -e "$w3/.env.local" ]'
rm "$tmp/mobile/.env.e2e"
run "$tmp/a3b" "$bin/agent-worktree.sh" test-builder AbCd1234 mobile
w3b=$tmp/mobile/.claude/worktrees/test-builder-AbCd1234
ok "worktree: only env files that exist are linked" '[ "$(rc "$tmp/a3b")" = 0 ] && [ -L "$w3b/.env" ] && [ ! -e "$w3b/.env.e2e" ] && [ ! -L "$w3b/.env.e2e" ]' "rc=$(rc "$tmp/a3b") $(ls -a "$w3b")"

run "$tmp/a4" "$bin/agent-worktree.sh" server-builder AbCd1234 server
w4=$tmp/server/.claude/worktrees/server-builder-AbCd1234
ok "worktree: server builder's worktree at origin/development" '[ "$(rc "$tmp/a4")" = 0 ] && [ "$(git -C "$w4" rev-parse HEAD)" = "$(git -C "$tmp/server" rev-parse origin/development)" ]' "rc=$(rc "$tmp/a4") $(cat "$tmp/a4")"
ok "worktree: server repo excludes .claude/worktrees/" 'grep -qx ".claude/worktrees/" "$tmp/server/.git/info/exclude"'
ok "worktree: server env file linked" '[ -L "$w4/.env.development.local" ]'
"$bin/agent-worktree.sh" server-builder AbCd1234 server >/dev/null 2>&1
ok "worktree: the exclude line is added once" '[ "$(grep -cx ".claude/worktrees/" "$tmp/server/.git/info/exclude")" = 1 ]'

run "$tmp/a5" "$bin/agent-worktree.sh" promoter - mobile
ok "worktree: a role worktree has no card in its name" '[ "$(rc "$tmp/a5")" = 0 ] && [ -d "$tmp/mobile/.claude/worktrees/promoter" ]' "rc=$(rc "$tmp/a5") $(cat "$tmp/a5")"
run "$tmp/a5b" "$bin/agent-worktree.sh" promoter 2 mobile
ok "worktree: the promoter's second mobile worktree is promoter-2" '[ "$(rc "$tmp/a5b")" = 0 ] && [ -d "$tmp/mobile/.claude/worktrees/promoter-2" ] && grep -q "promoter-2$" "$tmp/a5b"' "rc=$(rc "$tmp/a5b") $(cat "$tmp/a5b")"
run "$tmp/a5c" "$bin/agent-worktree.sh" mobile-builder 2 mobile
ok "worktree: the 2 slot is the promoter's alone" '[ "$(rc "$tmp/a5c")" = 2 ]'

run "$tmp/a6" "$bin/agent-worktree.sh" board-watcher AbCd1234 mobile
ok "worktree: an agent with no worktree is refused" '[ "$(rc "$tmp/a6")" = 2 ]'
run "$tmp/a7" "$bin/agent-worktree.sh" mobile-builder 'bad;id' mobile
ok "worktree: a bad short link is refused" '[ "$(rc "$tmp/a7")" = 2 ]'
run "$tmp/a8" "$bin/agent-worktree.sh" server-builder AbCd1234 mobile
ok "worktree: the server builder never gets a mobile worktree" '[ "$(rc "$tmp/a8")" = 2 ]'


echo
if [ "$failures" -eq 0 ]; then echo "All cases passed"; exit 0; fi
echo "$failures case(s) failed"; exit 1
