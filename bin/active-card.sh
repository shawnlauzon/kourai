#!/usr/bin/env bash
# The merger says which cards it has in work right now, so that board-wait.sh puts the green "Actively
# worked" label on those cards and on no other card of MERGING (rules.md, Labels; the merger's transcript
# names only its newest card read, often a queued one).
#
# Usage: active-card.sh merger [<shortLink>...]
#   merger     the one role that uses it (the promoter's cards follow the release status card);
#   shortLink  every card the merger has in work: the card it is on, plus each card that is suite
#              waiting. The call REPLACES the whole list; with no card it clears the list.
# Writes <dir>/merger, one short link per line, atomically; a call is one local write, never a Trello call.
# <dir> is $ACTIVE_CARD_DIR (default
# <state_dir>/active). board-wait.sh ignores a file older than the live merger.
# Exit 0; 2 for a usage error (nothing written).
set -u
. "$(dirname "${BASH_SOURCE[0]}")/kourai-env.sh"
dir=${ACTIVE_CARD_DIR:-$(kc paths.active_card_dir)}
role=${1:-}
[ "$role" = merger ] || { echo "usage: active-card.sh merger [<shortLink>...]" >&2; exit 2; }
shift
for c in "$@"; do
  case "$c" in
    *[!A-Za-z0-9]* | "") echo "active-card.sh: not a card short link: $c" >&2; exit 2 ;;
  esac
  [ "${#c}" = 8 ] || { echo "active-card.sh: not a card short link (8 characters): $c" >&2; exit 2; }
done
mkdir -p "$dir" || exit 1
tmpf=$(mktemp "$dir/.merger.XXXXXX") || exit 1
if [ $# -gt 0 ]; then printf '%s\n' "$@" >"$tmpf"; else : >"$tmpf"; fi
mv -f "$tmpf" "$dir/merger"
if [ $# -gt 0 ]; then echo "ACTIVE: merger $*"; else echo "ACTIVE: merger none"; fi
