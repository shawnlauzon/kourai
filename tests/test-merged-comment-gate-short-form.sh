#!/bin/bash
# Fake-input test of merged-comment-gate.sh (card N7IHnW9T): a `MERGED:` comment is
# allowed when the card names the PR by its full URL OR as <owner>/<repo>#<n>, and
# denied for another number, another repo, or a longer number (#30 vs #309).
# Usage: test-merged-comment-gate-short-form.sh [hook path] (default: the tracked ../hooks/merged-comment-gate.sh)
# The hook runs from a copy in a temporary folder with a stub review-policy.sh; curl
# (Trello), gh, aws, tailscale and ssh are fakes on PATH. Nothing reaches the network.
set -u -o pipefail
export KOURAI_CONFIG=${KOURAI_CONFIG:-$(cd "$(dirname "$0")" && pwd)/fixtures/config.toml}
export KOURAI_BIN=${KOURAI_BIN:-$(cd "$(dirname "$0")/../bin" && pwd)}
arg=${1:-$(dirname "$0")/../hooks/merged-comment-gate.sh}
hook=$(cd "$(dirname "$arg")" && pwd)/$(basename "$arg")
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/hooks" "$T/home/Development/example_files"
for c in aws tailscale ssh; do printf '#!/bin/bash\nexit 99\n' >"$T/bin/$c"; chmod +x "$T/bin/$c"; done
printf 'TRELLO_KEY=k\nTRELLO_TOKEN=t\n' >"$T/home/Development/example_files/trello.env"
cat >"$T/bin/curl" <<'F'
#!/bin/bash
for a in "$@"; do case "$a" in https://api.trello.com/1/*) url=${a#https://api.trello.com/1} ;; esac; done
case "$url" in
  /cards/*/actions) jq -n --arg t "$FAKE_COMMENT" '[{data:{text:$t}}]' ;;
  /cards/*) echo '{"idList":"000000000000000000000011","shortUrl":"https://trello.com/c/FAKE"}' ;;
  *) exit 22 ;;
esac
F
cat >"$T/bin/gh" <<'F'
#!/bin/bash
echo "MERGED $FAKE_SHA"
F
chmod +x "$T/bin/curl" "$T/bin/gh"
printf '#!/bin/bash\necho "NO REVIEW NEEDED: stub"\n' >"$T/hooks/review-policy.sh"
hv=$("$KOURAI_BIN/kourai-config" get install.version); mkdir -p "$T/hooksdir/$hv"; cp "$T/hooks/review-policy.sh" "$T/hooksdir/$hv/"
{ cat "$KOURAI_CONFIG"; printf '\n[paths]\nhooks_dir = "%s"\ntrello_env = "%s"\n' "$T/hooksdir" "$T/home/Development/example_files/trello.env"; } >"$T/config.toml"; export KOURAI_CONFIG=$T/config.toml
cp "$hook" "$T/hooks/merged-comment-gate.sh"; chmod +x "$T/hooks/"*

sha=$(printf 'a%.0s' {1..40}); fail=0
run() { # run <name> <PR in the MERGED comment> <card comment> <allow|deny>
  local out dec
  out=$(jq -n --arg t "MERGED: $2 @ $sha" '{tool_input:{action:"add_comment",cardId:"0123456789abcdef01234567",text:$t}}' \
    | HOME="$T/home" PATH="$T/bin:$PATH" FAKE_COMMENT="$3" FAKE_SHA="$sha" bash "$T/hooks/merged-comment-gate.sh")
  dec=$(jq -r '.hookSpecificOutput.permissionDecision // "none"' <<<"$out")
  if [ "$dec" = "$4" ]; then echo "ok   $1"; else echo "FAIL $1: wanted $4, got $dec ($out)"; fail=1; fi
}
R=example-org/example-app
run "full URL"                  $R#309 "PR: https://github.com/$R/pull/309" allow
run "short form"                $R#309 "PR: $R#309" allow
run "short form in a sentence"  $R#309 "Opened $R#309 for review." allow
run "short form at line end"    $R#309 "see $R#309" allow
run "old repo name, short"      $R#309 "PR: example-user/example-app-old#309" allow
run "old repo name, URL"        $R#309 "PR: https://github.com/example-user/example-app-old/pull/309" allow
run "other number, short"       $R#309 "PR: $R#308" deny
run "longer number, short"      $R#30  "PR: $R#309" deny
run "longer number, URL"        $R#30  "PR: https://github.com/$R/pull/309" deny
run "other repo, short"         $R#309 "PR: example-org/example-api#309" deny
run "other repo, URL"           $R#309 "PR: https://github.com/example-org/example-api/pull/309" deny
run "repo as a suffix of another" $R#309 "PR: xexample-org/example-app#309" deny
run "bare number"               $R#309 "PR #309" deny
run "no PR named"               $R#309 "nothing here" deny
exit $fail
