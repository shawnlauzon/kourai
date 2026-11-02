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

# the push runs in a throwaway repo with a network remote, never in the caller's checkout (whose origin may be a
# local path, which the fake allows on purpose: the tests use throwaway bare repos)
git -C "$tmp" init -q netrepo
git -C "$tmp/netrepo" remote add origin https://example.invalid/x.git
KOURAI_TEST_NETLOG="$log" git -C "$tmp/netrepo" push origin main >/dev/null 2>&1
assert_eq "git push to a network remote is blocked" 97 "$?"
git -C "$tmp" init -q --bare bare.git
git -C "$tmp" init -q localrepo
git -C "$tmp/localrepo" remote add origin "$tmp/bare.git"
KOURAI_TEST_NETLOG="$log" git -C "$tmp/localrepo" push origin HEAD:refs/heads/x >/dev/null 2>&1
assert_eq "git push to a local path remote is the real git (it has no commit, so it fails with 1, not 97)" 1 "$?"

git -C "$tmp" init -q repo
assert_eq "local git works" 0 "$?"
rm -rf "$tmp"
finish
