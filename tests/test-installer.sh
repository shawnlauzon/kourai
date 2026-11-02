#!/usr/bin/env bash
# installer/kourai-install on scratch: plan, apply, check, idempotence, gate drift, rollback, refusals.
# Everything lives in a scratch folder; claude runs only against a scratch CLAUDE_CONFIG_DIR.
source "$(dirname "$0")/lib.sh"
require_fakes

# Outside the repo on purpose: claude resolves a project inside a git checkout differently and
# would not write the project settings there.
T=$(mktemp -d /tmp/kourai-installer-test.XXXXXX)
export CLAUDE_CONFIG_DIR="$T/claude-config"
mkdir -p "$CLAUDE_CONFIG_DIR"
guard_claude_config
guard_path "$T"
REAL_CLAUDE=$(PATH="${PATH#"$KOURAI_ROOT/tests/fakes:"}" command -v claude || true)
if [ -z "$REAL_CLAUDE" ]; then fail "no real claude binary to test the plugin commands with"; finish; exit $?; fi
export KOURAI_CLAUDE_BIN="$REAL_CLAUDE"

# The release source: a local repo of the working tree, tagged like a release.
SRC="$T/source"
mkdir -p "$SRC"
(cd "$KOURAI_ROOT" && { git ls-files; git ls-files --others --exclude-standard; } | grep -v '^tests/\.tmp/' | sort -u | while read -r f; do [ -e "$f" ] && echo "$f"; done | tar -cf - -T - | tar -xf - -C "$SRC")
VER=$(python3 -c 'import json;print(json.load(open("'"$SRC"'/.claude-plugin/plugin.json"))["version"])')
git -C "$SRC" init -q
git -C "$SRC" -c user.name=t -c user.email=t@example.invalid add -A
git -C "$SRC" -c user.name=t -c user.email=t@example.invalid commit -q -m release
git -C "$SRC" tag "kourai--v$VER"

# The installation: config from the fixture with scratch paths.
STATE="$T/state"; PROJ="$T/project"
mkdir -p "$STATE" "$PROJ/.claude"
CFG="$T/kourai.toml"
sed -e "s#/Users/shawn/Development/example_files#$STATE#" \
    -e "s#/Users/shawn/Development/github/example-app#$PROJ#" \
    -e "s#/Users/shawn/Development/github/example-api#$T/api#" \
    -e "s#^version = .*#version = \"$VER\"#" "$KOURAI_ROOT/tests/fixtures/config.toml" > "$CFG"
echo '{"autoMode":{"allow":["$defaults","keep me"]},"other":1}' > "$T/user-settings.json"
echo '{"permissions":{"allow":["Bash(ls *)"]},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo mine"}]}]},"x":2}' > "$PROJ/.claude/settings.local.json"
cp "$PROJ/.claude/settings.local.json" "$T/project-before.json"
cp "$T/user-settings.json" "$T/user-before.json"
printf '#!/bin/sh\n' > "$T/no-agents.sh"; chmod +x "$T/no-agents.sh"
export KOURAI_INSTALL_AGENT_CHECK="$T/no-agents.sh"

KI() { python3 "$KOURAI_ROOT/installer/kourai-install" --config "$CFG" --user-settings "$T/user-settings.json" \
        --project-settings "$PROJ/.claude/settings.local.json" --source "$SRC" "$@"; }
HOOKS="$STATE/kourai/hooks/$VER"

out=$(KI plan 2>&1); rc=$?
assert_eq "plan exits 10 when it has changes" 10 "$rc"
assert_contains "plan names the plan file" "Plan written" "$out"
assert_eq "plan changes no settings" "$(cat "$T/project-before.json")" "$(cat "$PROJ/.claude/settings.local.json")"
assert_eq "plan changes no user settings" "$(cat "$T/user-before.json")" "$(cat "$T/user-settings.json")"
[ ! -e "$HOOKS" ] && pass || fail "plan copied hooks"
plan_file=$(ls "$STATE"/kourai/plans/*.md 2>/dev/null | head -1)
assert_contains "plan file has the settings diff" "Settings diff" "$(cat "$plan_file")"

out=$(KI apply 2>&1); rc=$?
assert_eq "apply succeeds" 0 "$rc"
[ -f "$HOOKS/merge-gate.sh" ] && [ -f "$HOOKS/SHA256SUMS" ] && pass || fail "apply did not copy the gates with SHA256SUMS: $out"
p=$(cat "$PROJ/.claude/settings.local.json")
assert_contains "the user's own allow line stays" "Bash(ls *)" "$p"
assert_contains "the user's own hook stays" "echo mine" "$p"
assert_contains "the gate is registered with KOURAI_BIN" "KOURAI_BIN=" "$p"
assert_contains "KOURAI_CONFIG is set in env" "$CFG" "$p"
assert_contains "the plugin is enabled" "kourai@kourai-example" "$p"
assert_contains "auto-mode keeps its own rules" "keep me" "$(cat "$T/user-settings.json")"
assert_contains "auto-mode has the kourai rule" "[kourai-example]" "$(cat "$T/user-settings.json")"

out=$(KI check 2>&1); rc=$?
assert_eq "check passes after apply" 0 "$rc"
out=$(KI plan 2>&1); rc=$?
assert_eq "a second plan has nothing to change" 0 "$rc"
cp "$PROJ/.claude/settings.local.json" "$T/project-applied.json"
out=$(KI apply 2>&1); rc=$?
assert_eq "apply without a new plan is refused or idempotent" "$(cat "$T/project-applied.json")" "$(cat "$PROJ/.claude/settings.local.json")"

# gate drift: a hand-edited installed gate is named
chmod u+w "$HOOKS/merge-gate.sh"; echo "# edited" >> "$HOOKS/merge-gate.sh"
out=$(KI check 2>&1); rc=$?
assert_eq "check fails on a drifted gate" 1 "$rc"
assert_contains "check says GATE DRIFT" "GATE DRIFT: merge-gate.sh" "$out"
cp "$SRC/hooks/merge-gate.sh" "$HOOKS/merge-gate.sh"
out=$(KI check 2>&1); rc=$?
assert_eq "check passes again once the gate is restored" 0 "$rc"

# a config edit after plan is refused
echo "# edit" >> "$CFG"
out=$(KI plan 2>&1)
echo "# another" >> "$CFG"
out=$(KI apply 2>&1); rc=$?
assert_eq "apply refuses a config changed since plan" 1 "$rc"
assert_contains "the refusal says plan again" "run plan" "$out"

# a sha pin is plan-only
sed -i '' "s#^version = .*#version = \"sha:$(git -C "$SRC" rev-parse HEAD)\"#" "$CFG"
out=$(KI apply 2>&1); rc=$?
assert_eq "apply refuses a sha pin" 1 "$rc"
out=$(KI check 2>&1); rc=$?
assert_eq "check refuses a sha pin" 1 "$rc"
sed -i '' "s#^version = .*#version = \"$VER\"#" "$CFG"

# running agents hold apply
python3 - "$PROJ/.claude/settings.local.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["permissions"]["allow"]=["Bash(ls *)"]; json.dump(d,open(p,"w"))
PY
KI plan >/dev/null 2>&1
printf '#!/bin/sh\necho "running workflow-builder card=x"\n' > "$T/some-agents.sh"; chmod +x "$T/some-agents.sh"
out=$(KOURAI_INSTALL_AGENT_CHECK="$T/some-agents.sh" KI apply 2>&1); rc=$?
assert_eq "apply refuses while agents run" 1 "$rc"
assert_contains "the refusal names the agents" "agents are running" "$out"

# rollback restores the files from before the apply
out=$(KI rollback --yes 2>&1); rc=$?
assert_eq "rollback succeeds" 0 "$rc"
assert_eq "rollback restores the project settings" "$(cat "$T/project-before.json")" "$(cat "$PROJ/.claude/settings.local.json")"
assert_eq "rollback restores the user settings" "$(cat "$T/user-before.json")" "$(cat "$T/user-settings.json")"

# nothing outside the scratch tree was written
[ ! -e "$HOME/.claude/plugins/cache/kourai-example" ] && pass || fail "a live plugin cache was written"
[ -n "${KOURAI_KEEP_TMP:-}" ] || rm -rf "$T"
finish
