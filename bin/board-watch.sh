#!/bin/bash
# Watches the project's board without AI: polls the Trello API every
# 60s and prints one line for each thing the USER does on the board, so the
# orchestrator never misses it:
#   MOVED: "<card>" <from list> → <to list>      (any list, including DONE)
#   COMMENT: "<card>" (<list>): <first 200 chars>
# Agents' own moves and comments are not printed: agents report those themselves.
# Never prints the key or token.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/kourai-env.sh"
set -a; . "$(kc paths.trello_env)"; set +a
user=$(kc board.members.user)
state="$(kc paths.board_watch_since)"
date -u +%Y-%m-%dT%H:%M:%S.000Z > "$state"
while true; do
  sleep 60
  since=$(cat "$state")
  out=$(curl -sf "https://api.trello.com/1/boards/$(kc board.id)/actions?filter=commentCard,updateCard:idList&since=$since&limit=100&key=$TRELLO_KEY&token=$TRELLO_TOKEN") \
    || { echo "board-watch: Trello request failed"; continue; }
  newest=$(jq -r 'map(.date) | max // empty' <<< "$out")
  jq -r --arg u "$user" 'reverse | .[] | select(.idMemberCreator == $u) |
    if .type == "commentCard" then
      "COMMENT: \"\(.data.card.name)\" (\(.data.list.name // "?")): \(.data.text | gsub("\n"; " ") | .[0:200])"
    else
      "MOVED: \"\(.data.card.name)\" \(.data.listBefore.name) → \(.data.listAfter.name)"
    end' <<< "$out"
  [ -n "$newest" ] && echo "$newest" > "$state"
done
