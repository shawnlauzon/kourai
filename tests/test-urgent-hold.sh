#!/bin/bash
# Test of urgent-hold.sh: real git in a temporary directory, no network.
set -u
export KOURAI_CONFIG=${KOURAI_CONFIG:-$(cd "$(dirname "$0")" && pwd)/fixtures/config.toml}
export KOURAI_BIN=${KOURAI_BIN:-$(cd "$(dirname "$0")/../bin" && pwd)}
S=$(cd "$(dirname "$0")/../bin" && pwd)/urgent-hold.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q -b main "$T/r"; g() { git -C "$T/r" "$@"; }
printf 'a\nb\nc\nd\ne\n' >"$T/r/x.txt"; printf 'one\n' >"$T/r/y.txt"; printf 'z\n' >"$T/r/z.txt"
g add -A; g commit -qm base; g branch origin-main
fail=0
check() { [ "$2" = "$3" ] || { echo "FAIL $1: got '$2' want '$3'"; fail=1; }; }
mk() { g checkout -q -b "$1" main; shift; "$@"; }  # branch from main, apply edit
g checkout -q -b pr main;     sed -i.bak 's/^b$/B-pr/' "$T/r/x.txt"; rm "$T/r/x.txt.bak"; g commit -qam pr
g checkout -q -b urg main;    sed -i.bak 's/^b$/B-urg/' "$T/r/x.txt"; rm "$T/r/x.txt.bak"; g commit -qam urg
g checkout -q -b other main;  echo two >>"$T/r/y.txt"; g commit -qam other
g checkout -q -b pre main;    sed -i.bak 's/^d$/D-pre/' "$T/r/x.txt"; rm "$T/r/x.txt.bak"; g commit -qam pre
g checkout -q main
# a branch whose urgent PR already conflicts with main
g checkout -q -b main2 main;  sed -i.bak 's/^b$/B-main/' "$T/r/x.txt"; rm "$T/r/x.txt.bak"; g commit -qam m2
g checkout -q main
out=$("$S" -C "$T/r" main pr urg); rc=$?
check "same lines" "$out/$rc" "urg HOLD/1"
out=$("$S" -C "$T/r" main pr other); rc=$?
check "other file" "$out/$rc" "other CLEAR/0"
out=$("$S" -C "$T/r" main pr pre); rc=$?
check "same file, other lines" "$out/$rc" "pre CLEAR/0"
out=$("$S" -C "$T/r" main2 other urg); rc=$?
check "already conflicting" "$out/$rc" "urg ALREADY CONFLICTING/0"
out=$("$S" -C "$T/r" main pr other urg 2>&1); rc=$?
check "two heads, one holds" "$(echo "$out" | tr '\n' ' ')/$rc" "other CLEAR urg HOLD /1"
out=$("$S" -C "$T/r" main pr deadbeef 2>/dev/null); rc=$?
check "missing sha" "$out/$rc" "deadbeef ERROR/3"
out=$("$S" -C "$T/r" main2 pr urg 2>&1); rc=$?
check "the PR conflicts with the base" "$rc" "2"
out=$("$S" -C "$T/r" main pr 2>&1); rc=$?
check "bad args" "$rc" "2"
[ -n "$(git -C "$T/r" status --porcelain)" ] && { echo "FAIL: worktree touched"; fail=1; }
[ "$fail" = 0 ] && echo "ALL PASSED" || exit 1
