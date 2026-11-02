#!/usr/bin/env bash
# Tells whether the gap between releases is over (rules.md, Settings: Gap between
# releases). The board watcher runs it before starting the promoter for a release.
#
# Usage: release-gap.sh [--urgent]
#   A release ends when a card moves from RELEASING to DONE or VERIFY (the release finished) or
#   from RELEASING back to MERGED (a failed release). The newest such move on the board
#   is the end of the newest release; it is read from the board's card-move history, so
#   a restarted board watcher keeps the gap.
#   --urgent: the release is for a 🚨 card (a failed-release fix or a regression):
#   exempt, the gap is not read at all.
# Prints one line:
#   GAP EXEMPT: urgent release
#   GAP OVER: no release has ended in the last <n> hours (last end <UTC>|none)
#   GAP WAIT: until <UTC> (the last release ended <UTC>)
# Exit 0 GAP EXEMPT or GAP OVER (a promoter may start); 1 GAP WAIT; 2 usage;
# 3 a Trello request failed (the caller waits and asks again; it never starts on this).
# Only reads Trello, with the key in trello.env, like board-snapshot.sh (the token itself
# can write: never print it). Test overrides: TRELLO_ENV_FILE, TRELLO_API_BASE,
# RELEASE_GAP_HOURS (default 8, the Settings value), RELEASE_GAP_NOW (epoch seconds).
set -u -o pipefail
. "$(dirname "${BASH_SOURCE[0]}")/kourai-env.sh"
env_file=${TRELLO_ENV_FILE:-$(kc paths.trello_env)}
api=${TRELLO_API_BASE:-https://api.trello.com/1}
board=$(kc board.id)
hours=${RELEASE_GAP_HOURS:-8}
urgent=false
case "${1:-}" in
  '') ;;
  --urgent) urgent=true ;;
  *) echo "usage: release-gap.sh [--urgent]" >&2; exit 2 ;;
esac
[ $# -le 1 ] || { echo "usage: release-gap.sh [--urgent]" >&2; exit 2; }
if $urgent; then echo "GAP EXEMPT: urgent release"; exit 0; fi
[[ "$hours" =~ ^[0-9]+$ ]] || { echo "release-gap: RELEASE_GAP_HOURS must be a whole number" >&2; exit 2; }
set -a
# shellcheck disable=SC1090 # the env file is the caller's (default: paths.trello_env in the config)
. "$env_file"
set +a

tmp=$(mktemp -d) || exit 3
trap 'rm -rf "$tmp"' EXIT
curl -sf -o "$tmp/moves" "$api/boards/$board/actions?filter=updateCard:idList&limit=1000&fields=date,data&key=$TRELLO_KEY&token=$TRELLO_TOKEN" \
  || { echo "release-gap: Trello request failed" >&2; exit 3; }

# The newest move out of RELEASING into DONE, VERIFY or MERGED (lists carry emoji: match the word).
last=$(jq -r '[.[] | select((.data.listBefore.name // "") | test("RELEASING"))
               | select((.data.listAfter.name // "") | test("DONE|VERIFY|MERGED"))
               | .date] | max // ""' "$tmp/moves") || { echo "release-gap: unreadable Trello answer" >&2; exit 3; }
now=${RELEASE_GAP_NOW:-$(date -u +%s)}
fmt() { date -u -r "$1" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || date -u -d "@$1" '+%Y-%m-%d %H:%M UTC'; }
if [ -z "$last" ]; then echo "GAP OVER: no release has ended in the last $hours hours (last end none)"; exit 0; fi
# Trello dates are UTC ISO 8601 with milliseconds.
last_epoch=$(python3 -I -c 'import sys,datetime as d; print(int(d.datetime.strptime(sys.argv[1][:19],"%Y-%m-%dT%H:%M:%S").replace(tzinfo=d.timezone.utc).timestamp()))' "$last") \
  || { echo "release-gap: unreadable date: $last" >&2; exit 3; }
until=$((last_epoch + hours * 3600))
if [ "$now" -ge "$until" ]; then
  echo "GAP OVER: no release has ended in the last $hours hours (last end $(fmt "$last_epoch"))"; exit 0
fi
echo "GAP WAIT: until $(fmt "$until") (the last release ended $(fmt "$last_epoch"))"; exit 1
