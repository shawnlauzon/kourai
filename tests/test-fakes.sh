#!/usr/bin/env bash
# The fakes themselves: each network tool is the fake, fails, and is logged;
# local git still works.
. "$(dirname "$0")/lib.sh"
require_fakes

tmp=$(new_tmp)
log="$tmp/netlog"
for t in aws tailscale ssh curl gh; do
  out=$(KOURAI_TEST_NETLOG="$log" "$t" sts get-caller-identity 2>&1); rc=$?
  assert_eq "$t exits 97" 97 "$rc"
  assert_contains "$t says it is fake" "FAKE $t" "$out"
done
assert_eq "five calls logged" 5 "$(wc -l < "$log" | tr -d ' ')"

KOURAI_TEST_NETLOG="$log" git push origin main >/dev/null 2>&1
assert_eq "git push is blocked" 97 "$?"

git -C "$tmp" init -q repo
assert_eq "local git works" 0 "$?"
rm -rf "$tmp"
finish
