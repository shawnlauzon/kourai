#!/usr/bin/env bash
# kourai-project runs a script of the project's script folder by NAME only: a path (../, an absolute path,
# a subfolder) or a dotfile is refused, so the allow rules `Bash(kourai-project <name> *)` cannot be used to run anything else.
set -u
. "$(dirname "$0")/lib.sh"
require_fakes
T=$(new_tmp); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/proj/.claude/bin" "$T/outside"
printf '#!/bin/bash\necho ran-ok "$@"\n' >"$T/proj/.claude/bin/ok.sh"
printf '#!/bin/bash\necho ESCAPED\n' >"$T/outside/evil.sh"
printf '#!/bin/bash\necho DOTTED\n' >"$T/proj/.claude/bin/.hidden.sh"
chmod +x "$T/proj/.claude/bin/ok.sh" "$T/outside/evil.sh" "$T/proj/.claude/bin/.hidden.sh"
{ cat "$KOURAI_ROOT/tests/fixtures/config.toml"; printf '\n[paths]\nproject_bin = "%s"\n' "$T/proj/.claude/bin"; } >"$T/kourai.toml"
export KOURAI_CONFIG=$T/kourai.toml
KP=$KOURAI_ROOT/bin/kourai-project
assert_eq "a script name runs" "ran-ok a b" "$("$KP" ok.sh a b 2>&1)"
for bad in "../../../outside/evil.sh" "$T/outside/evil.sh" "sub/ok.sh" ".hidden.sh" ".."; do
  out=$("$KP" "$bad" 2>&1); rc=$?
  assert_eq "refuses [$bad]" 2 "$rc"
  case "$out" in *ESCAPED*|*DOTTED*) fail "ran [$bad]" ;; *) pass ;; esac
done
finish
