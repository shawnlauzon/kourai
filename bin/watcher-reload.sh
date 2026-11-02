#!/usr/bin/env bash
# Tells the board watcher whether a change to rules.md or board-watcher.md can be taken
# in place (read as a diff) or needs a restart (rules.md, Settings: Watcher reload).
#
# Usage: watcher-reload.sh baseline [--agent-commit <c>] | check | diff | asked | reset
#   baseline  records both files' current commits as the base the watcher reads (for
#             board-watcher.md, --agent-commit <c> when the watcher was started from an
#             older commit: its system prompt is that commit), clears the applied
#             commits, writes both files at the base commits to <dir>/rules.md and
#             <dir>/board-watcher.md and prints the two paths and commits. Run it
#             BEFORE reading the copies, so a merge in between shows up at the next check.
#   check     one line: NONE | INPLACE: ... | APPLIED: ... | RESTART: <reason>
#             RESTART only when a file's head is newer than its applied commit; also when
#             applied..head deletes a rules.md line (a change reverted after it was taken).
#   diff      writes the cumulative diff base..head of both files to <dir>/diff.txt,
#             prints its path and line count, sets applied=head and counts the reload
#             once (the count rises only when an applied commit advances).
#   asked     sets review_asked=1.   reset  count=0, review_asked=0 (base and applied stay).
# State: <files>/board-watcher-reload.state (key=value) and an append-only .log.
# Test overrides: WR_REPO (the checkout), WR_FILES (state dir, default project.state_dir).
set -u -o pipefail
. "$(dirname "${BASH_SOURCE[0]}")/kourai-env.sh"
repo=${WR_REPO:-$(kc repos.app.path)}
files=${WR_FILES:-$(kc project.state_dir)}
state=$files/board-watcher-reload.state
logf=$files/board-watcher-reload.log
okf=$files/board-watcher-reload.ok
work=$files/board-watcher-reload
# The project rules: project.rules_file, as a path inside the app checkout (a file elsewhere is not tracked there).
R=.claude/board/rules.md
_rf=$(kc_or project.rules_file "")
if [ -n "$_rf" ]; then
  _rp=$(cd "$repo" 2>/dev/null && pwd -P)
  case "$_rf" in "$repo"/*) R=${_rf#"$repo"/} ;; "${_rp:-/nonexistent}"/*) R=${_rf#"$_rp"/} ;; /*) ;; *) R=$_rf ;; esac
fi
# The board watcher's file: in the app repo before the switch-over; after it the plugin ships it
# ($KOURAI_BIN/../agents), a change to it reaches the watcher only through a release, kourai-install
# and a restart, so it is never read as a diff and its "commit" is the word plugin.
A=.claude/agents/board-watcher.md
plugin_agent="$KOURAI_BIN/../agents/board-watcher.md"
max_inplace=3 max_agent_add=60 max_rules=300 max_rules_del=60 max_bytes=25000

g() { git -C "$repo" "$@"; }
agent_in_repo() { g cat-file -e "HEAD:$A" 2>/dev/null; }
head_of() { # the file's last commit; the agent file, when the repo does not hold it, is "plugin"
  if [ "$1" = "$A" ] && ! agent_in_repo; then echo plugin; return; fi
  g log -1 --format=%h -- "$1" 2>/dev/null
}
log() { mkdir -p "$files"; printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >>"$logf"; }
get() { [ -f "$state" ] && sed -n "s/^$1=//p" "$state" | head -1; }
put() { # put key value
  mkdir -p "$files"; touch "$state"
  grep -v "^$1=" "$state" >"$state.tmp" 2>/dev/null; printf '%s=%s\n' "$1" "$2" >>"$state.tmp"
  mv "$state.tmp" "$state"
}
numstat() { # numstat <from> <to> <file> -> "added deleted"
  g diff --numstat "$1..$2" -- "$3" | awk '{a+=$1; d+=$2} END {print a+0, d+0}'
}
front() { g show "$1:$2" 2>/dev/null | awk 'NR==1 && $0!="---" {exit} /^---$/ {n++; if (n==2) exit; next} n==1'; }

cmd=${1:-}
case $cmd in
baseline)
  agent_c=""
  [ "${2:-}" = "--agent-commit" ] && agent_c=${3:-}
  hr=$(head_of $R); ha=${agent_c:-$(head_of $A)}
  [ -n "$hr" ] && [ -n "$ha" ] || { echo "ERROR: cannot read the commits of the two files in $repo" >&2; exit 1; }
  put base_rules "$hr"; put base_agent "$ha"; put applied_rules ""; put applied_agent ""
  [ -n "$(get count)" ] || put count 0
  [ -n "$(get review_asked)" ] || put review_asked 0
  mkdir -p "$work"
  # an --agent-commit that does not hold the file (the deletion commit of the switch-over) means the plugin's file
  if [ "$ha" != plugin ] && ! g cat-file -e "$ha:$A" 2>/dev/null; then ha=plugin; put base_agent plugin; fi
  g show "$hr:$R" >"$work/rules.md" || { echo "ERROR: git show failed" >&2; exit 1; }
  if [ "$ha" = plugin ]; then cp "$plugin_agent" "$work/board-watcher.md" || { echo "ERROR: cannot read $plugin_agent" >&2; exit 1; }
  else g show "$ha:$A" >"$work/board-watcher.md" || { echo "ERROR: git show failed" >&2; exit 1; }; fi
  log "baseline rules=$hr agent=$ha"
  echo "BASELINE: $work/rules.md (rules.md @ $hr), $work/board-watcher.md (board-watcher.md @ $ha)"
  ;;
check)
  br=$(get base_rules); ba=$(get base_agent)
  [ -n "$br" ] && [ -n "$ba" ] || { echo "RESTART: state missing or unreadable"; exit 0; }
  ar=$(get applied_rules); aa=$(get applied_agent)
  hr=$(head_of $R); ha=$(head_of $A)
  [ -n "$hr" ] && [ -n "$ha" ] || { echo "RESTART: cannot read the files' commits"; exit 0; }
  newer=0
  [ "$hr" != "${ar:-$br}" ] && newer=1
  [ "$ha" != "${aa:-$ba}" ] && newer=1
  if [ $newer = 0 ]; then
    if [ -n "$ar" ] || [ -n "$aa" ]; then echo "APPLIED: rules.md $br..$hr, board-watcher.md $ba..$ha"
    else echo NONE; fi
    exit 0
  fi
  # frontmatter and deletions of the agent file
  if [ "$ha" != "$ba" ] && { [ "$ha" = plugin ] || [ "$ba" = plugin ]; }; then
    echo "RESTART: board-watcher.md moved between the app repo and the plugin"; exit 0
  elif [ "$ha" != "$ba" ]; then
    [ "$(front "$ba" $A)" = "$(front "$ha" $A)" ] || { echo "RESTART: board-watcher.md frontmatter changed"; exit 0; }
    read -r aadd adel < <(numstat "$ba" "$ha" $A)
    [ "$adel" -eq 0 ] || { echo "RESTART: board-watcher.md diff deletes or changes $adel lines"; exit 0; }
    [ "$aadd" -le $max_agent_add ] || { echo "RESTART: board-watcher.md diff adds $aadd lines"; exit 0; }
  else aadd=0; adel=0; fi
  if [ -n "$ar" ] && [ "$hr" != "$ar" ]; then # a line taken earlier and now deleted is withdrawn: the watcher cannot unread it
    read -r _ wdel < <(numstat "$ar" "$hr" $R)
    [ "$wdel" -eq 0 ] || { echo "RESTART: rules.md removes $wdel lines already read in place"; exit 0; }
  fi
  read -r radd rdel < <(numstat "$br" "$hr" $R)
  [ $((radd + rdel)) -le $max_rules ] || { echo "RESTART: rules.md diff too large ($((radd + rdel)) lines)"; exit 0; }
  [ "$rdel" -le $max_rules_del ] || { echo "RESTART: rules.md diff deletes $rdel lines"; exit 0; }
  bytes=$( { g diff "$br..$hr" -- $R; [ "$ba" = plugin ] || g diff "$ba..$ha" -- $A; } | wc -c | tr -d ' ')
  [ "$bytes" -le $max_bytes ] || { echo "RESTART: diff too large ($bytes bytes)"; exit 0; }
  trailers=$( { g log "$br..HEAD" --format=%B -- $R; [ "$ba" = plugin ] || g log "$ba..HEAD" --format=%B -- $A; } )
  if grep -qE '^Watcher: restart[[:space:]]*$' <<<"$trailers"; then
    echo "RESTART: Watcher: restart trailer"; exit 0
  fi
  count=$(get count); count=${count:-0}
  if [ "$count" -ge $max_inplace ] && [ ! -f "$okf" ]; then
    if [ "$(get review_asked)" = 1 ]; then echo "RESTART: trial review (asked)"; else echo "RESTART: trial review (ask)"; fi
    exit 0
  fi
  echo "INPLACE: rules.md $br..$hr +$radd/-$rdel, board-watcher.md $ba..$ha +$aadd/-$adel"
  ;;
diff)
  br=$(get base_rules); ba=$(get base_agent)
  [ -n "$br" ] && [ -n "$ba" ] || { echo "ERROR: state missing: run baseline" >&2; exit 1; }
  hr=$(head_of $R); ha=$(head_of $A)
  mkdir -p "$work"
  { echo "# rules.md $br..$hr"; g diff "$br..$hr" -- $R; echo "# board-watcher.md $ba..$ha"; [ "$ba" = plugin ] || g diff "$ba..$ha" -- $A; } >"$work/diff.txt"
  changed=0
  [ "$hr" != "$(get applied_rules)" ] && [ "$hr" != "$br" ] && changed=1
  [ "$ha" != "$(get applied_agent)" ] && [ "$ha" != "$ba" ] && changed=1
  if [ $changed = 1 ]; then
    put count $(( $(get count) + 1 )); log "inplace rules=$br..$hr agent=$ba..$ha lines=$(wc -l <"$work/diff.txt" | tr -d ' ')"
  fi
  [ "$hr" = "$br" ] || put applied_rules "$hr"
  [ "$ha" = "$ba" ] || put applied_agent "$ha"
  echo "DIFF: $work/diff.txt ($(wc -l <"$work/diff.txt" | tr -d ' ') lines)"
  ;;
asked) put review_asked 1; log asked ;;
reset) put count 0; put review_asked 0; log reset ;;
*) echo "usage: watcher-reload.sh baseline [--agent-commit <c>] | check | diff | asked | reset" >&2; exit 2 ;;
esac
