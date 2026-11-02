#!/usr/bin/env bash
# Every written `subagent_type: <name>` in agents/, commands/, rules/ and docs/ is true against the
# [agents] lists of config/defaults.toml: a plugin role is written kourai:<role>, a project role bare.
. "$(dirname "$0")/lib.sh"
require_fakes
cfg="$KOURAI_ROOT/config/defaults.toml"
plugin=$(python3 -c 'import sys,tomllib,json; print(json.dumps(tomllib.load(open(sys.argv[1],"rb"))["agents"]["plugin"]))' "$cfg")
assert_contains "plugin list has the watcher" board-watcher "$plugin"
n=0
while IFS= read -r hit; do
  name=$(printf '%s' "$hit" | sed -E 's/.*subagent_type: `?([A-Za-z:_-]+).*/\1/')
  case "$name" in
    '<'*|*'<'*|*:) continue ;;
    kourai:*) role=${name#kourai:}
      case "$plugin" in *"\"$role\""*) pass ;; *) fail "start [$name] names a role that is not in [agents] plugin" ;; esac ;;
    *) case "$plugin" in *"\"$name\""*) fail "start [$name] must be written kourai:$name" ;; *) pass ;; esac ;;
  esac
  n=$((n+1))
done < <(grep -rhE 'subagent_type: `?[A-Za-z]' "$KOURAI_ROOT/agents" "$KOURAI_ROOT/commands" "$KOURAI_ROOT/rules" "$KOURAI_ROOT/docs" 2>/dev/null)
assert_eq "some starts were checked" 1 "$([ "$n" -ge 2 ] && echo 1 || echo 0)"
finish
