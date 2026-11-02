#!/usr/bin/env bash
# standing-card.sh <card name> [--find <word>...] [--link <url>]
# The small read a filer makes of a standing card ("Technical debt: High" and the like) before
# filing (rules.md, Technical debt and bug cards, "Before filing, one read"), in place of a
# whole `trelloReadChecklist list_by_card` (every checklist with up to 200 items).
# Prints:
#   CARD <card ARI>                     (or `MISSING card`, exit 0: the filer creates it)
#   CHECKLIST <ARI> <name> items=<n>[ FULL]   one per checklist; FULL at 190 or more (Trello holds 200)
#   ITEM <ARI> <checked|unchecked> <text cut at 300 characters>   only items that match
# An item matches when its text holds every --find word (any case) or holds the --link text.
# With no --find and no --link no item is printed. Two cards of one name: the first by position.
# A filer that needs "Mobile 2" or "Server 2" sees its absence as no CHECKLIST line of that name.
# Only reads Trello, with the key in trello.env, like board-snapshot.sh; never prints the key or token.
# Exit 0 on success; 1 when a Trello request fails (the caller falls back to the Trello MCP read);
# 2 on a usage error. Test overrides: TRELLO_ENV_FILE, TRELLO_API_BASE, RC_RETRY_SLEEP.
set -u -o pipefail
. "$(dirname "${BASH_SOURCE[0]}")/kourai-env.sh"
env_file=${TRELLO_ENV_FILE:-$(kc paths.trello_env)}
api=${TRELLO_API_BASE:-https://api.trello.com/1}
board=$(kc board.id)
ws=$(kc board.workspace_id)
name=${1:-}
[ -n "$name" ] && [[ "$name" != --* ]] || { echo "usage: standing-card.sh <card name> [--find <word>...] [--link <url>]" >&2; exit 2; }
shift
words=() link=""
mode=""
while [ $# -gt 0 ]; do
  case "$1" in
    --find) mode=find ;;
    --link) mode=link; shift; link=${1:-}; [ -n "$link" ] || { echo "standing-card: --link needs a url" >&2; exit 2; } ;;
    *) [ "$mode" = find ] || { echo "standing-card: unexpected argument: $1" >&2; exit 2; }; words+=("$1") ;;
  esac
  shift
done
set -a
# shellcheck disable=SC1090 # the env file is the caller's (default: paths.trello_env in the config)
. "$env_file"
set +a
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

get() { # get <file> <path> <query>: one Trello GET, retried on 429, 5xx and curl errors
  local try code wait
  for try in 1 2 3 4; do
    code=$(curl -s -o "$tmp/$1" -w '%{http_code}' "$api/$2?$3&key=$TRELLO_KEY&token=$TRELLO_TOKEN") || code=000
    case "$code" in
      2??) return 0 ;;
      429|5??|000) ;;
      *) break ;;
    esac
    [ "$try" -lt 4 ] || break
    wait=$((1 << try)); sleep "${RC_RETRY_SLEEP:-$wait}"
  done
  echo "standing-card: Trello request failed: $2" >&2; exit 1
}

get cards "boards/$board/cards" "filter=open&fields=name,pos"
id=$(jq -r --arg n "$name" '[.[] | select(.name == $n)] | sort_by(.pos) | .[0].id // empty' "$tmp/cards")
if [ -z "$id" ]; then echo "MISSING card"; exit 0; fi
echo "CARD ari:cloud:trello::card/workspace/$ws/$id"
get lists "cards/$id/checklists" "fields=name,pos&checkItems=all&checkItem_fields=name,state,pos"
wj=$(printf '%s\n' "${words[@]+"${words[@]}"}" | jq -R . | jq -sc 'map(select(. != ""))')
jq -r --arg ws "$ws" --arg link "$link" --argjson words "$wj" '
  def match($t): ($t | ascii_downcase) as $l
    | (($words | length) > 0 and ($words | all(. as $w | $l | contains($w | ascii_downcase))))
      or ($link != "" and ($t | contains($link)));
  sort_by(.pos)[] | . as $c
  | "CHECKLIST ari:cloud:trello::checklist/workspace/\($ws)/\($c.id) \($c.name) items=\($c.checkItems | length)\(if ($c.checkItems | length) >= 190 then " FULL" else "" end)",
    ($c.checkItems | sort_by(.pos)[] | select(match(.name))
     | "ITEM ari:cloud:trello::check-item/workspace/\($ws)/\(.id) \(if .state == "complete" then "checked" else "unchecked" end) \(.name | gsub("[\r\n]+"; " ") | .[0:300])")
' "$tmp/lists"
