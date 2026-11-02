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
# Copies of the live settings' shapes (a project's allow entries by full path, the auto-mode rules that name
# .claude/bin paths): the plan must list every one of them as stale (plan section 7).
python3 - "$PROJ" "$T/user-settings.json" <<'PY'
import json, sys
proj, us = sys.argv[1:]
names = "heartbeat card-test-server dev-merge-lock board-snapshot card-kind card-summary pr-ready pr-conflicts agent-state ci-wait run-wait board-wait release-gap remerge-check merged-cards code-review-check code-review-wait workflow-checks active-card watcher-reload urgent-hold".split()
p = proj + "/.claude/settings.local.json"
d = json.load(open(p))
d["permissions"]["allow"] += ["Bash(%s/.claude/bin/%s.sh:*)" % (proj, n) for n in names]
d["permissions"]["allow"] += ["Bash(%s/.claude/bin/test-server.sh ports:*)" % proj, "Bash(%s/.claude/bin/test-workflow-checks.sh:*)" % proj]
json.dump(d, open(p, "w"))
u = json.load(open(us))
u["autoMode"]["allow"] += ["Rule %d: run %s/.claude/bin/%s.sh from the checkout" % (k, proj, n) for k, n in enumerate(names[:21])]
# Relative mentions (the live rules 3 and 6 name the folder, not a full path): also stale.
u["autoMode"]["allow"] += ["Start agents only for agents defined in %s/.claude/agents/" % proj.rsplit("/", 1)[1],
                           "Run the project scripts in %s/.claude/bin/ for the board" % proj.rsplit("/", 1)[1]]
json.dump(u, open(us, "w"))
PY
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
assert_contains "plan reports the stale line count" "Stale lines in the current settings: 40 (plan section 7)" "$out"
plan_file=$(ls "$STATE"/kourai/plans/*.md 2>/dev/null | head -1)
assert_contains "plan file has the settings diff" "Settings diff" "$(cat "$plan_file")"
plan_text=$(cat "$plan_file")
assert_contains "plan lists a stale allow entry" "- project allow: Bash($PROJ/.claude/bin/heartbeat.sh:*)" "$plan_text"
assert_contains "plan lists the last stale allow entry" "- project allow: Bash($PROJ/.claude/bin/urgent-hold.sh:*)" "$plan_text"
case "$plan_text" in *"Bash($PROJ/.claude/bin/card-test-server.sh:*)"*|*"Bash($PROJ/.claude/bin/workflow-checks.sh:*)"*) fail "plan lists a script the project keeps as stale" ;; *) pass ;; esac
assert_contains "plan lists an auto-mode rule naming a .claude/bin path" "- auto-mode allow: Rule 20: run $PROJ/.claude/bin/urgent-hold.sh from the checkout" "$plan_text"
assert_eq "plan lists every stale line once (19 allow entries and 21 auto-mode rules name a script that moved into the plugin; the 4 and 2 that name the project's own scripts stay valid)" 40 "$(grep -c '^- \(project allow\|auto-mode allow\): ' <<<"$plan_text")"
assert_eq "plan does not list the user's own lines as stale" 0 "$(grep -c 'Bash(ls \*)\|keep me' <<<"$(sed -n '/^## 7/,$p' <<<"$plan_text")")"
# The permission template is an explicit list: no command runner, no identity script, no blanket kourai-project.
allow_text=$(python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["permissions"]["allow"]))' "$PROJ/.claude/settings.local.json" 2>/dev/null)

out=$(KI apply 2>&1); rc=$?
assert_eq "apply succeeds" 0 "$rc"
[ -f "$HOOKS/merge-gate.sh" ] && [ -f "$HOOKS/SHA256SUMS" ] && pass || fail "apply did not copy the gates with SHA256SUMS: $out"
p=$(cat "$PROJ/.claude/settings.local.json")
assert_contains "the user's own allow line stays" "Bash(ls *)" "$p"
assert_contains "the user's own hook stays" "echo mine" "$p"
assert_contains "the gate is registered with KOURAI_BIN" "KOURAI_BIN=" "$p"
assert_contains "KOURAI_CONFIG is set in env" "$CFG" "$p"
assert_contains "the plugin is enabled" "kourai@kourai-example" "$p"
for n in as-claude.sh gh-app-token.sh run-bg.sh run-locked.sh agent-worktree.sh; do
  case "$p" in *"Bash($n"*) fail "the allow list opens $n" ;; *) pass ;; esac
done
case "$p" in *'"Bash(kourai-project *)"'*) fail "the allow list opens every project script" ;; *) pass ;; esac
assert_contains "the allow list names a project script by name" "Bash(kourai-project card-test-server.sh *)" "$p"
assert_contains "the allow list lets the review policy check run through kourai-hook" "Bash(kourai-hook review-policy.sh check *)" "$p"
assert_contains "the allow list names a plugin script by name" "Bash(board-snapshot.sh *)" "$p"
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

# config drift: the config decides the gates (login, review tables, guarded paths) and lives outside git
cp "$CFG" "$T/cfg-applied.toml"
echo "# edited after the apply" >> "$CFG"
out=$(KI check 2>&1); rc=$?
assert_eq "check fails on a config changed since the apply" 1 "$rc"
assert_contains "check says CONFIG DRIFT" "CONFIG DRIFT" "$out"
out=$(KI plan 2>&1); rc=$?
assert_eq "plan does not call a changed config nothing to change" 10 "$rc"
cp "$T/cfg-applied.toml" "$CFG"
out=$(KI check 2>&1); rc=$?
assert_eq "check passes once the config is the applied one" 0 "$rc"
out=$(KI plan 2>&1); rc=$?
assert_eq "plan has nothing to change again" 0 "$rc"

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

# stale(): a post-switch rule that names kourai: agents or kourai-project may still name the project's folders and hooks;
# only a named old script or agent file is stale in it. (The two rules are the settings section's agent-start and
# workflow-builder rules, with the project's names as placeholders.)
out=$(python3 -I - "$KOURAI_ROOT" "$PROJ" "$KOURAI_ROOT/tests/fixtures" <<'PY'
import importlib.machinery, importlib.util, os, sys
root, proj, fx = sys.argv[1:]
loader = importlib.machinery.SourceFileLoader("kourai_install", os.path.join(root, "installer", "kourai-install"))
spec = importlib.util.spec_from_loader("kourai_install", loader)
mod = importlib.util.module_from_spec(spec); loader.exec_module(mod)
inst = object.__new__(mod.Inst)
inst.repo0 = proj
inst.record = {}
inst.bin_scripts = lambda r: ["board-wait.sh", "heartbeat.sh"]
def rule(n):
    t = open(os.path.join(fx, n)).read()
    return (t.replace("@PROJ@", proj).replace("@PROJNAME@", os.path.basename(proj))
             .replace("@PROJECT@", "Example").replace("@KOURAI@", "/kourai").replace("@KOURAI_REPO@", "owner/kourai"))
def stale(texts):
    return [w for w, _ in inst.stale_lines(root, {"permissions": {"allow": texts}}, {})]
for n in ("post52-agent-start-rule.txt", "post52-workflow-builder-rule.txt"):
    print(n, len(stale([rule(n)])))
print("pre52 agent-start", len(stale(["Start agents only for agents defined in %s/.claude/agents/" % os.path.basename(proj)])))
print("pre52 scripts", len(stale(["Run the scripts in %s/.claude/bin/ for the board" % proj])))
print("mixed script", len(stale(["kourai-project card-test-server.sh, and %s/.claude/bin/board-wait.sh" % proj])))
print("mixed agent file", len(stale(["kourai: agents, and %s/.claude/agents/merger.md" % proj])))
PY
)
assert_contains "stale(): the post-switch agent-start rule is not stale" "post52-agent-start-rule.txt 0" "$out"
assert_contains "stale(): the post-switch workflow-builder rule is not stale" "post52-workflow-builder-rule.txt 0" "$out"
assert_contains "stale(): the pre-switch agent-start text is still stale" "pre52 agent-start 1" "$out"
assert_contains "stale(): the pre-switch scripts text is still stale" "pre52 scripts 1" "$out"
assert_contains "stale(): a named old script is stale even beside kourai-project" "mixed script 1" "$out"
assert_contains "stale(): a named old agent file is stale even beside kourai:" "mixed agent file 1" "$out"

# nothing outside the scratch tree was written
[ ! -e "$HOME/.claude/plugins/cache/kourai-example" ] && pass || fail "a live plugin cache was written"
[ -n "${KOURAI_KEEP_TMP:-}" ] || rm -rf "$T"
finish
