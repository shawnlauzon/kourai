#!/bin/bash
# Fake-input test of merge-gate.sh (card N7IHnW9T): `gh pr merge` is allowed when a card
# comment names the PR by its full URL OR as <owner>/<repo>#<n> on a `PR:` line, and denied for another
# number, another repo, a longer number (#30 vs #309) or no PR named.
# Usage: test-merge-gate-short-form.sh [hook path] (default: the tracked ../hooks/merge-gate.sh)
# The hook runs from a copy with a stub review-policy.sh; curl (Trello), gh, aws,
# tailscale and ssh are fakes on PATH. Nothing reaches the network.
set -u -o pipefail
export KOURAI_CONFIG=${KOURAI_CONFIG:-$(cd "$(dirname "$0")" && pwd)/fixtures/config.toml}
export KOURAI_BIN=${KOURAI_BIN:-$(cd "$(dirname "$0")/../bin" && pwd)}
arg=${1:-$(dirname "$0")/../hooks/merge-gate.sh}
hook=$(cd "$(dirname "$arg")" && pwd)/$(basename "$arg")
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/hooks" "$T/home/Development/example_files"
for c in aws tailscale ssh; do printf '#!/bin/bash\nexit 99\n' >"$T/bin/$c"; chmod +x "$T/bin/$c"; done
printf '#!/bin/bash\nexit 0\n' >"$T/bin/gh"; chmod +x "$T/bin/gh"
printf 'TRELLO_KEY=k\nTRELLO_TOKEN=t\n' >"$T/home/Development/example_files/trello.env"
cat >"$T/bin/curl" <<'F'
#!/bin/bash
for a in "$@"; do case "$a" in https://api.trello.com/1/*) url=${a#https://api.trello.com/1} ;; esac; done
case "$url" in
  /boards/*/actions) jq -n --arg t "$FAKE_COMMENT" --arg t2 "${FAKE_COMMENT2:-}" \
      '[{id:"a1",date:"2026-10-18T10:00:00.000Z",data:{text:$t,card:{id:"c1"}}}] + (if $t2 == "" then [] else [{id:"a2",date:"2026-10-18T10:00:00.000Z",data:{text:$t2,card:{id:"c2"}}}] end)' ;;
  /cards/c1) echo "{\"name\":\"${FAKE_NAME:-Some card}\",\"shortUrl\":\"https://trello.com/c/FAKE\"}" ;;
  /cards/c2) echo '{"name":"[AGENTS] Included card","shortUrl":"https://trello.com/c/INCL"}' ;;
  /cards/c1/actions) jq -n --arg t "VERIFIED: example-org/example-app#309 @ $FAKE_SHA" '[{date:"2026-10-18T10:00:00.000Z",data:{text:$t}}]' ;;
  /cards/c2/actions) echo '[]' ;;
  *) exit 22 ;;
esac
F
chmod +x "$T/bin/curl"
printf '#!/bin/bash\necho "NO REVIEW NEEDED: stub"\n' >"$T/hooks/review-policy.sh"
hv=$("$KOURAI_BIN/kourai-config" get install.version); mkdir -p "$T/hooksdir/$hv"; cp "$T/hooks/review-policy.sh" "$T/hooksdir/$hv/"
{ cat "$KOURAI_CONFIG"; printf '\n[paths]\nhooks_dir = "%s"\ntrello_env = "%s"\n' "$T/hooksdir" "$T/home/Development/example_files/trello.env"; } >"$T/config.toml"; export KOURAI_CONFIG=$T/config.toml
cp "$hook" "$T/hooks/merge-gate.sh"; chmod +x "$T/hooks/"*

sha=$(printf 'a%.0s' {1..40}); fail=0; R=example-org/example-app
export FAKE_SHA=$sha
run() { # run <name> <PR number merged> <card comment> <allow|deny> [second card's comment]
  local out dec
  out=$(jq -n --arg c "gh pr merge $2 --repo $R --merge --match-head-commit $sha" '{tool_input:{command:$c}}' \
    | HOME="$T/home" PATH="$T/bin:$PATH" FAKE_COMMENT="$3" FAKE_COMMENT2="${5:-}" FAKE_NAME="${FAKE_NAME:-}" bash "$T/hooks/merge-gate.sh")
  dec=$(jq -r '.hookSpecificOutput.permissionDecision // "none"' <<<"$out")
  if [ "$dec" = "$4" ]; then echo "ok   $1"; else echo "FAIL $1: wanted $4, got $dec ($out)"; fail=1; fi
}
run "full URL"                   309 "PR: https://github.com/$R/pull/309" allow
run "short form"                 309 "PR: $R#309" allow
run "short form in a sentence"   309 "Opened $R#309 for review." deny
run "old repo name, short"       309 "PR: example-user/example-app-old#309" allow
run "old repo name, URL"         309 "PR: https://github.com/example-user/example-app-old/pull/309" allow
run "other number, short"        309 "PR: $R#308" deny
run "longer number, short"       30  "PR: $R#309" deny
run "longer number, URL"         30  "PR: https://github.com/$R/pull/309" deny
run "other repo, short"          309 "PR: example-org/example-api#309" deny
run "repo as a suffix of another" 309 "PR: xexample-org/example-app#309" deny
run "bare number"                309 "PR #309" deny
# The carrying card is an [AGENTS] card with a VERIFIED for this head. A second [AGENTS] card that
# only mentions the PR (an INCLUDED IN: line, a sentence) never has its own VERIFIED and must not block.
export FAKE_NAME="[AGENTS] Carrying card"
run "agents card, short PR: line"      309 "PR: $R#309" allow
run "agents card, URL"                 309 "PR: https://github.com/$R/pull/309" allow
run "included card (INCLUDED IN:)"     309 "PR: $R#309" allow "INCLUDED IN: $R#309 (carrying card)"
run "card mentions PR in a sentence"   309 "PR: $R#309" allow "conflicts with $R#309 on rules.md"
run "second card PR: line, no VERIFIED" 309 "PR: $R#309" deny "PR: $R#309"
run "second card URL, no VERIFIED"     309 "PR: $R#309" deny "PR: https://github.com/$R/pull/309"
run "DEPENDS ON: URL on an agents card" 309 "PR: $R#309" allow "DEPENDS ON: https://github.com/$R/pull/309"
run "DEPENDS ON: short on an agents card" 309 "PR: $R#309" allow "DEPENDS ON: $R#309"
run "PR: URL card, no VERIFIED"        309 "PR: https://github.com/$R/pull/309" deny "PR: https://github.com/$R/pull/309"
exit $fail
