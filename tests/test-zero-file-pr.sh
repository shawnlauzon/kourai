#!/bin/bash
# Tests review-policy.sh and card-kind.sh on a PR that changes no files (a
# history-only merge, server #157). A fake gh on PATH answers; no network.
set -u
export KOURAI_CONFIG=${KOURAI_CONFIG:-$(cd "$(dirname "$0")" && pwd)/fixtures/config.toml}
export KOURAI_BIN=${KOURAI_BIN:-$(cd "$(dirname "$0")/../bin" && pwd)}
here=$(cd "$(dirname "$0")/../bin" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir -p "$T/bin"
cat >"$T/bin/gh" <<'EOS'
#!/bin/bash
args="$*"; jq_expr=""
while [ $# -gt 0 ]; do [ "$1" = --jq ] && jq_expr=$2; shift; done
case "$args" in
  *pulls/7/files*) json=$FAKE_FILES ;;
  *pulls/7/reviews*) json=$FAKE_REVIEWS ;;
  *pulls/7*) json=$FAKE_PR ;;
  *) exit 1 ;;
esac
if [ -n "$jq_expr" ]; then jq -r "$jq_expr" <<<"$json"; else echo "$json"; fi
EOS
chmod +x "$T/bin/gh"
S=example-org/example-api#7
head=$(printf 'b%.0s' {1..40}); fail=0
pr() { jq -nc --arg h "$head" --argjson n "$1" '{head:{sha:$h},base:{ref:"development"},body:"",changed_files:$n}'; }
chk() { # chk <name> <want exit> <want text> <got exit> <got out>
  if [ "$2" = "$4" ] && [[ "$5" == *"$3"* ]]; then echo "ok   $1"; else echo "FAIL $1: wanted $2 '$3', got $4 '$5'"; fail=1; fi
}
run_rp() { out=$(PATH="$T/bin:$PATH" FAKE_PR="$1" FAKE_FILES="$2" FAKE_REVIEWS="$3" bash "$here/../hooks/review-policy.sh" check $S); rc=$?; }
run_ck() { out=$(PATH="$T/bin:$PATH" FAKE_PR="$1" FAKE_FILES="$2" FAKE_REVIEWS="[]" CARD_KIND_GH="$T/bin/gh" bash "$here/card-kind.sh" $S); rc=$?; }
appr=$(jq -nc --arg h "$head" '[{user:{login:"example-user"},state:"APPROVED",commit_id:$h,submitted_at:"2026-10-19T20:00:00Z"}]')

run_rp "$(pr 0)" "[]" "[]";    chk "policy: zero files, no approval -> review" 1 "REVIEW NEEDED: $S: changes no files" "$rc" "$out"
run_rp "$(pr 0)" "[]" "$appr"; chk "policy: zero files, approved on head" 0 "APPROVED: $S" "$rc" "$out"
run_rp "$(pr 3)" "[]" "$appr"; chk "policy: empty list but changed_files 3 -> error" 2 "ERROR: $S changes no files" "$rc" "$out"
run_rp "$(pr 1)" '[{"filename":"docs/a.md"}]' "[]"; chk "policy: docs-only unchanged" 0 "NO REVIEW NEEDED" "$rc" "$out"
run_ck "$(pr 0)" "[]";  chk "kind: zero files -> TESTS" 0 "$S TESTS (files: 0" "$rc" "$out"
chk "kind: card line" 0 "CARD: TESTS" "$rc" "$out"
run_ck "$(pr 3)" "[]";  chk "kind: empty list but changed_files 3 -> error" 2 "ERROR: $S lists no changed files" "$rc" "$out"
run_ck "$(pr 1)" '[{"filename":"docs/a.md"}]'; chk "kind: docs-only unchanged" 0 "AGENTS (files: 1" "$rc" "$out"
exit $fail
