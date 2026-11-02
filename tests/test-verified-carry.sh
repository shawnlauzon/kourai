#!/bin/bash
# Test of verified-carry.sh ("[AGENTS] A conflict-only fix keeps the PR's VERIFIED: (no new
# verifier round)" https://trello.com/c/mWg2nZnw): a VERIFIED: carries to a head reached only by
# merges of the base and empty commits, and to nothing else. Real git in a temporary directory,
# a local bare "origin", no network.
# Usage: test-verified-carry.sh [verified-carry.sh to test] (default: the one next to this file)
set -u
export KOURAI_CONFIG=${KOURAI_CONFIG:-$(cd "$(dirname "$0")" && pwd)/fixtures/config.toml}
export KOURAI_BIN=${KOURAI_BIN:-$(cd "$(dirname "$0")/../bin" && pwd)}
script=${1:-$(dirname "$0")/../bin/verified-carry.sh}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/nonet"
for c in aws tailscale ssh gh; do printf '#!/bin/bash\necho "fake %s: no network in tests" >&2\nexit 99\n' "$c" >"$T/nonet/$c"; chmod +x "$T/nonet/$c"; done
export PATH="$T/nonet:$PATH"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/clone" 2>/dev/null
g() { git -C "$T/clone" "$@"; }
g checkout -q -b main; echo base >"$T/clone/a.md"; echo x >"$T/clone/b.md"
g add -A; g commit -q -m base; g push -q origin main
g checkout -q -b card; echo mine >>"$T/clone/a.md"; g commit -qam mine
A=$(g rev-parse HEAD)
g checkout -q main; echo theirs >"$T/clone/b.md"; g commit -qam theirs; g push -q origin main
g checkout -q card; g merge -q --no-edit main >/dev/null 2>&1
M=$(g rev-parse HEAD)                                        # A, then a merge of main
g commit -q --allow-empty -m "Remerge-allow: a.md: x"
E=$(g rev-parse HEAD)                                        # ... then an empty commit
echo more >>"$T/clone/a.md"; g commit -qam "a code change"
C=$(g rev-parse HEAD)                                        # ... then a commit with a file change
g checkout -q -b side "$A"; echo side >"$T/clone/c.md"; g add -A; g commit -qm side   # a branch that is not main
g checkout -q -b mside "$A"; echo m >"$T/clone/e.md"; g add -A; g commit -qm m0; g merge -q --no-ff --no-edit side >/dev/null 2>&1
S=$(g rev-parse HEAD)                                        # A, then a merge of a non-base branch
g checkout -q -b other main; echo o >"$T/clone/d.md"; g add -A; g commit -qm other
O=$(g rev-parse HEAD)                                        # not after A at all
g push -q origin "$E:refs/pull/5/head"
g fetch -q origin
sed -e "s#/Users/shawn/Development/github/example-app#$T/clone#" -e "s#/Users/shawn/Development/github/example-api#$T/clone#" "$KOURAI_CONFIG" >"$T/config.toml"
export KOURAI_CONFIG=$T/config.toml
printf '#!/bin/bash\nexec bash "%s" "$@"\n' "$script" >"$T/carry.sh"
R=example-org/example-app
pass=0 fail=0
run() { # name want-prefix want-rc pr verified head
  local out rc; out=$(bash "$T/carry.sh" "$4" "$5" "$6"); rc=$?
  if [[ "$out" == "$2"* ]] && [ "$rc" = "$3" ]; then pass=$((pass+1)); echo "PASS $1"
  else fail=$((fail+1)); echo "FAIL $1: want $2 (exit $3), got exit $rc: $out"; fi
}
run "a merge of the base carries"                     CARRIED      0 "$R#5" "$A" "$M"
run "a merge of the base, then an empty commit carries" CARRIED    0 "$R#5" "$A" "$E"
run "an abbreviated verified sha is resolved"         CARRIED      0 "$R#5" "${A:0:7}" "$E"
run "the old mobile repo name is accepted"            CARRIED      0 "example-user/example-app-old#5" "$A" "$M"
run "the verified head itself carries"                CARRIED      0 "$R#5" "$A" "$A"
run "a commit that changes a file does not carry"     "NOT CARRIED: $R#5 @ ${C:0:7}: commit ${C:0:7}" 1 "$R#5" "$A" "$C"
run "a merge of a branch that is not the base does not carry" "NOT CARRIED: $R#5 @ ${S:0:7}: merge" 1 "$R#5" "$A" "$S"
run "a head the verified commit is not under does not carry" "NOT CARRIED: $R#5 @ ${O:0:7}: the verified commit" 1 "$R#5" "$A" "$O"
run "an unknown verified commit is an ERROR"          "ERROR:"     2 "$R#5" "abcdef1" "$M"
run "a short head is an ERROR"                        "ERROR:"     2 "$R#5" "$A" "${M:0:7}"
run "an unknown repo is an ERROR"                     "ERROR:"     2 "x/y#5" "$A" "$M"
# A head missing from the clone is fetched once from origin (the PR's head ref).
g checkout -q card; g reset -q --hard "$E"
g checkout -q -b later "$E"; g merge -q --no-edit main >/dev/null 2>&1; g commit -q --allow-empty -m "empty"
L=$(g rev-parse HEAD); g push -q origin "$L:refs/pull/5/head"; g checkout -q card; g branch -q -D later
g reflog expire --expire=now --all; g gc -q --prune=now 2>/dev/null
run "a head missing locally is fetched, then carries" CARRIED     0 "$R#5" "$A" "$L"
# The fetch is bounded and fails closed: an origin that cannot be reached is an ERROR, not a pass.
g remote set-url origin "$T/nowhere.git"
run "a missing head with no reachable origin is an ERROR" "ERROR: can't fetch" 2 "$R#5" "$A" "$(printf '9%.0s' {1..40})"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
