#!/usr/bin/env bash
# The real `claude plugin validate --strict .` on the repo, never faked. It makes no network
# call and runs against a scratch CLAUDE_CONFIG_DIR.
source "$(dirname "$0")/lib.sh"
require_fakes
T=$(mktemp -d /tmp/kourai-validate-test.XXXXXX)
export CLAUDE_CONFIG_DIR="$T/claude-config"; mkdir -p "$CLAUDE_CONFIG_DIR"
guard_claude_config
REAL_CLAUDE=$(PATH="${PATH#"$KOURAI_ROOT/tests/fakes:"}" command -v claude || true)
if [ -z "$REAL_CLAUDE" ]; then fail "no real claude binary to validate with"; rm -rf "$T"; finish; exit $?; fi
out=$(cd "$KOURAI_ROOT" && "$REAL_CLAUDE" plugin validate --strict . 2>&1); rc=$?
assert_eq "claude plugin validate --strict passes" 0 "$rc"
[ "$rc" -eq 0 ] || echo "$out" >&2
# plugin.json and the defaults agree on the version the installer will read
pv=$(python3 -c 'import json;print(json.load(open("'"$KOURAI_ROOT"'/.claude-plugin/plugin.json"))["version"])')
dv=$(python3 -c 'import re,sys;t=open(sys.argv[1]).read();print(re.search(r"\[install\][^\[]*?\nversion = \"([^\"]+)\"",t).group(1))' "$KOURAI_ROOT/config/defaults.toml")
assert_eq "plugin.json version equals the install.version default" "$pv" "$dv"
rm -rf "$T"
finish
