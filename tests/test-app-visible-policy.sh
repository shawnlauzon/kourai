#!/bin/bash
# Test of review-policy.sh: a mobile PR's `App-visible:` line decides for lib/ ("[AGENTS]
# Mobile PRs get an App-visible: line" https://trello.com/c/YEdm1RBs). A fake gh on PATH
# answers from files; no network, no git.
# Usage: test-app-visible-policy.sh <review-policy.sh to test> [old]
#   old: the cases for today's hook: any lib/ change needs review whatever the line says.
set -u
export KOURAI_CONFIG=${KOURAI_CONFIG:-$(cd "$(dirname "$0")" && pwd)/fixtures/config.toml}
export KOURAI_BIN=${KOURAI_BIN:-$(cd "$(dirname "$0")/../bin" && pwd)}
hook=${1:-$(cd "$(dirname "$0")/../hooks" && pwd)/review-policy.sh}
mode=${2:-new}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir "$T/bin" "$T/f"
cat >"$T/bin/gh" <<'GH'
#!/bin/bash
args="$*"
case "$args" in
  *pulls/5/files*) cat "$FAKE/files" ;;
  *pulls/5/reviews*) echo '[]' ;;
  *pulls/5) cat "$FAKE/pr" ;;
  *) exit 1 ;;
esac
GH
chmod +x "$T/bin/gh"
export FAKE="$T/f"
H=$(printf 'a%.0s' $(seq 40))
pass=0 fail=0
run() { # name want repo "body" files...
  local name=$1 want=$2 repo=$3 body=$4; shift 4
  printf '%s\n' "$@" >"$FAKE/files"
  jq -n --arg h "$H" --arg b "$body" '{head:{sha:$h},base:{ref:"main"},body:$b}' >"$FAKE/pr"
  local out; out=$(PATH="$T/bin:$PATH" bash "$hook" check "$repo#5")
  if [[ "$out" == "$want"* ]]; then pass=$((pass+1)); echo "PASS $name"; else fail=$((fail+1)); echo "FAIL $name: want $want, got: $out"; fi
}
APP=example-org/example-app
SRV=example-org/example-api
NOREV="NO REVIEW NEEDED"; REV="REVIEW NEEDED"
want_no=$NOREV; [ "$mode" = old ] && want_no=$REV
run "lib/ change, App-visible: no" "$want_no" $APP "What.
App-visible: no — network retries under an unchanged UI" lib/core/network/retry_interceptor.dart
run "lib/ change, App-visible: yes" "$REV" $APP "App-visible: yes — new banner" lib/features/home/home_page.dart
run "lib/ change, no line" "$REV" $APP "What it does" lib/features/home/home_page.dart
run "lib/ change, an unreadable line" "$REV" $APP "App-visible: maybe" lib/features/home/home_page.dart
run "lib/ and test/ change, App-visible: no" "$want_no" $APP "App-visible: no — retries" lib/core/a.dart test/core/a_test.dart
run "lib/ change with pubspec.yaml, App-visible: no" "$REV" $APP "App-visible: no — x" lib/core/a.dart pubspec.yaml
run "pubspec.lock alone, App-visible: no" "$REV" $APP "App-visible: no — x" pubspec.lock
run "android/ change, App-visible: no" "$REV" $APP "App-visible: no — x" android/app/src/main/AndroidManifest.xml
run "ios/ change, App-visible: no" "$REV" $APP "App-visible: no — x" ios/Runner/Info.plist
run "fastlane/ change, App-visible: no" "$REV" $APP "App-visible: no — x" fastlane/Fastfile
run "assets/ change, App-visible: no" "$REV" $APP "App-visible: no — x" assets/images/icons/a.svg
run "a new top-level file, App-visible: no" "$REV" $APP "App-visible: no — x" Makefile
run "a hook change, App-visible: no" "$REV" $APP "App-visible: no — x" .claude/hooks/merge-gate.sh
run "tests and docs only, no line" "$NOREV" $APP "What it does" test/a_test.dart docs/a.md
run "server code, App-visible: no" "$NOREV" $SRV "App-visible: no — x" app/models/a.rb
run "server code, no line" "$REV" $SRV "What" app/models/a.rb
want_srv=$NOREV; [ "$mode" = old ] && want_srv=$REV
run "server controller, App-visible: no (server #123: a 500 became a 422 for an upload the app never sends)" "$want_srv" $SRV "App-visible: no — x" app/controllers/uploads_controller.rb app/models/media_object.rb test/a_test.rb
run "server controller, App-visible: yes" "$REV" $SRV "App-visible: yes — x" app/controllers/a.rb
run "server controller, no line" "$REV" $SRV "What" app/controllers/a.rb
run "server routes, App-visible: no" "$want_srv" $SRV "App-visible: no — x" config/routes.rb
run "server infra, App-visible: no" "$REV" $SRV "App-visible: no — x" infra/main.tf
echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
