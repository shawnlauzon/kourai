#!/usr/bin/env bash
# The review policy through the paths production takes, with only the network tools faked
# (a review of 2026-11-02 found two callers that never reached the policy, and the tests that
# replaced the policy with a stand-in hid it):
#   1. board-wait.py's policy_pass, with RC_REVIEW_POLICY unset, no KOURAI_BIN in the environment
#      and the installed copy in <hooks_dir>/<version>/ (with its SHA256SUMS): it must run the real
#      hooks/review-policy.sh through kourai-hook and read NO REVIEW NEEDED / REVIEW NEEDED.
#   2. pr-ready.sh with REVIEW_POLICY unset: its last column is the policy's verdict, not ERROR.
# A fake gh answers `gh api`, `gh pr view` and `gh pr checks` from files; a fake curl answers Trello.
set -u
. "$(dirname "$0")/lib.sh"
require_fakes
bin=$KOURAI_ROOT/bin
T=$(new_tmp); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/fakebin" "$T/hooks/0.1.0-rc1" "$T/f"
cp "$KOURAI_ROOT/hooks/review-policy.sh" "$T/hooks/0.1.0-rc1/"
( cd "$T/hooks/0.1.0-rc1" && shasum -a 256 review-policy.sh | awk '{print $1 "  " $2}' >SHA256SUMS )
{ cat "$KOURAI_ROOT/tests/fixtures/config.toml"; printf '\n[paths]\nhooks_dir = "%s"\n' "$T/hooks"; } >"$T/kourai.toml"
export KOURAI_CONFIG=$T/kourai.toml
unset KOURAI_BIN RC_REVIEW_POLICY REVIEW_POLICY
export BOARD_WAIT_STATE=$T/state.json
H=$(printf 'a%.0s' $(seq 40))
cat >"$T/fakebin/gh" <<EOF
#!/usr/bin/env bash
args="\$*"
case "\$args" in
  "api --paginate repos/example-org/example-app/pulls/5/files"*) cat $T/f/files ;;
  "api --paginate repos/example-org/example-app/pulls/5/reviews"*) echo '[]' ;;
  "api repos/example-org/example-app/pulls/5") cat $T/f/pr ;;
  "pr view 5 --repo example-org/example-app"*) echo '{"state":"OPEN","headRefOid":"$H","mergeable":"MERGEABLE","body":"App-visible: no"}' ;;
  "pr checks 5 --repo example-org/example-app"*) echo '[{"name":"unit","bucket":"pass"}]' ;;
  *) echo "fake gh: unexpected \$args" >&2; exit 1 ;;
esac
EOF
printf '#!/usr/bin/env bash\nout=""; while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2;; *) shift;; esac; done\necho "{\\"desc\\":\\"**PR:** example-org/example-app#5, https://github.com/example-org/example-app/pull/5 (x)\\"}" >"$out"\n' >"$T/fakebin/curl"
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"
printf 'TRELLO_KEY=k\nTRELLO_TOKEN=t\n' >"$T/trello.env"
export TRELLO_ENV_FILE=$T/trello.env
set_pr() { # files... ; body App-visible: no
  printf '%s\n' "$@" >"$T/f/files"
  jq -n --arg h "$H" '{head:{sha:$h},base:{ref:"main"},body:"App-visible: no",changed_files:1}' >"$T/f/pr"
}
pol() { # files... -> board-wait policy_pass answer
  set_pr "$@"
  PATH="$T/fakebin:$PATH" python3 -I - "$bin" <<'PY'
import importlib.util, sys, types
spec = importlib.util.spec_from_file_location("board_wait", sys.argv[1] + "/board-wait.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
stub = types.SimpleNamespace(s={"reviewpol": {}})
print(m.Wait.policy_pass(stub, "example-org/example-app", 5, {"headRefOid": "a" * 40, "body": "App-visible: no"}, "none"))
PY
}
assert_eq "board-wait: a tests-only PR passes through the installed gate" True "$(pol test/a_test.dart)"
assert_eq "board-wait: a hook change needs review through the installed gate" False "$(pol .claude/hooks/merge-gate.sh)"
assert_eq "board-wait: an android/ Markdown file needs review (always_paths before free *.md)" False "$(pol android/README.md)"
printf 'tampered\n' >>"$T/hooks/0.1.0-rc1/review-policy.sh"
assert_eq "board-wait: a copy that no longer matches its hash is no answer" None "$(pol test/a_test.dart)"
cp "$KOURAI_ROOT/hooks/review-policy.sh" "$T/hooks/0.1.0-rc1/"

set_pr test/a_test.dart
line=$(PATH="$T/fakebin:$PATH" "$bin/pr-ready.sh" AbCd1234 2>&1)
assert_contains "pr-ready: the verdict column is the policy's" "| NO REVIEW NEEDED" "$line"
set_pr .claude/hooks/merge-gate.sh
line=$(PATH="$T/fakebin:$PATH" "$bin/pr-ready.sh" AbCd1234 2>&1)
assert_contains "pr-ready: a hook change reads REVIEW NEEDED" "| REVIEW NEEDED" "$line"

echo "$PASSES passed, $FAILS failed"; [ "$FAILS" = 0 ]
