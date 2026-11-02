#!/bin/bash
# Fake-input test of merge-gate.sh's screenshot check (card 6U8HrveL): a mobile PR that adds
# or changes a file under docs/ui_tests/ is denied with "merge-gate: SCREENSHOTS IN GIT:", a
# deleted one is allowed, and a file list that cannot be read (or reaches the 3000-file cap)
# is denied with "merge-gate: CANNOT LIST FILES:". The hook runs from a copy with a stub
# review-policy.sh; curl (Trello) and gh are fakes on PATH. Nothing reaches the network.
# Usage: test-merge-gate-screenshots.sh [hook path] (default: the tracked ../hooks/merge-gate.sh)
set -u -o pipefail
export KOURAI_CONFIG=${KOURAI_CONFIG:-$(cd "$(dirname "$0")" && pwd)/fixtures/config.toml}
export KOURAI_BIN=${KOURAI_BIN:-$(cd "$(dirname "$0")/../bin" && pwd)}
arg=${1:-$(dirname "$0")/../hooks/merge-gate.sh}
hook=$(cd "$(dirname "$arg")" && pwd)/$(basename "$arg")
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/hooks" "$T/home/Development/example_files"
for c in aws tailscale ssh; do printf '#!/bin/bash\nexit 99\n' >"$T/bin/$c"; chmod +x "$T/bin/$c"; done
printf 'TRELLO_KEY=k\nTRELLO_TOKEN=t\n' >"$T/home/Development/example_files/trello.env"
# gh api …/files: prints the file list the case sets in FAKE_FILES ("status<TAB>path" lines), or fails when FAKE_GH_FAIL is set.
cat >"$T/bin/gh" <<'F'
#!/bin/bash
[ -z "${FAKE_GH_FAIL:-}" ] || { echo "gh: HTTP 502" >&2; exit 1; }
printf '%s' "${FAKE_FILES:-}"
F
chmod +x "$T/bin/gh"
cat >"$T/bin/curl" <<'F'
#!/bin/bash
for a in "$@"; do case "$a" in https://api.trello.com/1/*) url=${a#https://api.trello.com/1} ;; esac; done
case "$url" in
  /boards/*/actions) jq -n '[{id:"a1",date:"2026-10-18T10:00:00.000Z",data:{text:"PR: example-org/example-app#309",card:{id:"c1"}}}]' ;;
  /cards/c1) echo '{"name":"Some card","shortUrl":"https://trello.com/c/FAKE"}' ;;
  /cards/c1/actions) echo '[]' ;;
  *) exit 22 ;;
esac
F
chmod +x "$T/bin/curl"
printf '#!/bin/bash\necho "NO REVIEW NEEDED: stub"\n' >"$T/hooks/review-policy.sh"
hv=$("$KOURAI_BIN/kourai-config" get install.version); mkdir -p "$T/hooksdir/$hv"; cp "$T/hooks/review-policy.sh" "$T/hooksdir/$hv/"
{ cat "$KOURAI_CONFIG"; printf '\n[paths]\nhooks_dir = "%s"\ntrello_env = "%s"\n' "$T/hooksdir" "$T/home/Development/example_files/trello.env"; } >"$T/config.toml"; export KOURAI_CONFIG=$T/config.toml
cp "$hook" "$T/hooks/merge-gate.sh"; chmod +x "$T/hooks/"*

sha=$(printf 'a%.0s' {1..40}); fail=0; R=example-org/example-app
tab=$(printf '\t')
run() { # run <name> <allow|deny> <expected text in the reason, or ""> <files, "status<TAB>path" lines>
  local out dec reason
  out=$(jq -n --arg c "gh pr merge 309 --repo $R --merge --match-head-commit $sha" '{tool_input:{command:$c}}' \
    | HOME="$T/home" PATH="$T/bin:$PATH" FAKE_FILES="$4" bash "$T/hooks/merge-gate.sh")
  dec=$(jq -r '.hookSpecificOutput.permissionDecision // "none"' <<<"$out")
  reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason // ""' <<<"$out")
  if [ "$dec" = "$2" ] && [[ "$reason" == *"$3"* ]]; then echo "ok   $1"; else echo "FAIL $1: wanted $2 with '$3', got $dec ($reason)"; fail=1; fi
}
run "no screenshot file"        allow "" "modified${tab}lib/a.dart"$'\n'
run "added file denied"         deny "merge-gate: SCREENSHOTS IN GIT: $R#309 adds or changes docs/ui_tests/X/after/01.png" "added${tab}docs/ui_tests/X/after/01.png"$'\n'
run "changed file denied"       deny "merge-gate: SCREENSHOTS IN GIT:" "modified${tab}docs/ui_tests/X/after/01.png"$'\n'
run "renamed into it denied"    deny "merge-gate: SCREENSHOTS IN GIT:" "renamed${tab}docs/ui_tests/Y/01.png"$'\n'
run "removed file allowed"      allow "" "removed${tab}docs/ui_tests/X/after/01.png"$'\n'"modified${tab}README.md"$'\n'
run "a similar folder allowed"  allow "" "added${tab}docs/ui_tests_notes/a.md"$'\n'
R=example-user/example-app-old
run "old repo name: added denied" deny "merge-gate: SCREENSHOTS IN GIT:" "added${tab}docs/ui_tests/X/after/01.png"$'\n'
run "old repo name: clean allowed" allow "" "modified${tab}lib/a.dart"$'\n'
R=example-org/example-app
run "removed and added denied"  deny "SCREENSHOTS IN GIT:" "removed${tab}docs/ui_tests/X/a.png"$'\n'"added${tab}docs/ui_tests/X/b.png"$'\n'
# a failing gh and the 3000-file cap deny with the other text
out=$(jq -n --arg c "gh pr merge 309 --repo $R --merge --match-head-commit $sha" '{tool_input:{command:$c}}' | HOME="$T/home" PATH="$T/bin:$PATH" FAKE_GH_FAIL=1 bash "$T/hooks/merge-gate.sh")
if [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out")" = deny ] && jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out" | grep -q '^merge-gate: CANNOT LIST FILES: ' \
  && ! jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out" | grep -q 'SCREENSHOTS IN GIT'; then echo "ok   gh error denied (CANNOT LIST FILES)"; else echo "FAIL gh error: $out"; fail=1; fi
many=$(for i in $(seq 1 3000); do printf 'modified\tlib/f%s.dart\n' "$i"; done)
run "3000 files denied"         deny "merge-gate: CANNOT LIST FILES:" "$many"$'\n'
# the other repo is not checked
out=$(jq -n --arg c "gh pr merge 309 --repo example-org/example-api --merge --match-head-commit $sha" '{tool_input:{command:$c}}' | HOME="$T/home" PATH="$T/bin:$PATH" FAKE_GH_FAIL=1 bash "$T/hooks/merge-gate.sh")
echo "$out" | grep -q 'CANNOT LIST FILES' && { echo "FAIL server repo checked"; fail=1; } || echo "ok   server PRs are not checked"
[ $fail = 0 ] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
