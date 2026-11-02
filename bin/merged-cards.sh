#!/bin/bash
# Bounded read of the cards the promoter works on (MERGED and RELEASING): one line per
# card, never a description, never a comment's full text (card "🚨 🪲 [AGENTS] The
# promoter dies on "Autocompact is thrashing" when MERGED holds many cards",
# https://trello.com/c/CB0UBtzY). Trello's list_by_list returns every card's full
# description and comments (48,000 characters for 26 cards on 2026-10-18), which filled
# a promoter's context three times; this prints what the promoter needs to pick the
# covered cards, and the promoter reads one card further with card-summary.sh.
# Usage: merged-cards.sh
#        merged-cards.sh --creator <shortLink>   (any card: prints only its `creator:` field)
# Output, lists in board order, cards in list order:
#   == <list name> (<n> cards)
#   <shortLink> | <card name, 100 chars> | labels: <names or -> | members: <n> | in list since: <UTC date, to the minute> | prs: <owner/repo>#<n>, ... | merged: <owner/repo>#<n>@<sha, 12 chars>, with:<owner/repo>#<n>@<sha>, ... | reverted: <yes|no>
# `prs` are the PRs of the card's `PR:` comments, `merged` those of its `MERGED:`
# comments and, written `with:<ref>@<sha>`, of its `MERGED WITH:` comments (an included card, carried by another card's PR), `reverted: yes` when it has a `REVERTED:` comment (the promoter then reads
# the card with card-summary.sh to see whether a later MERGED: comment undoes it). A
# status card (its name starts with `⛔ BLOCKED:` or `🚀 RELEASE:`) ends with `| status card` in place of
# those fields; the promoter reads it with card-summary.sh.
# `creator:` (rules.md, VERIFY) is `internal` (the card's createCard member, or the member of its copyCard,
# moveCardToBoard or convertToCardFromCheckItem when it has no createCard, is the user's account
# the user or another internal member, or the agent account, and no REPORTER line names
# anyone), `external @user1,@user2` (REPORTER: lines at the start of any description line, plus an external
# creator) or `unknown` (the creator cannot be read or its username cannot be looked up: external, with no
# one to @mention). Each card's own comments
# are read (the newest 1000) but only the fields above are printed, so a line stays
# under about 800 characters however large the card is.
# Only reads Trello, with the key in trello.env, like board-snapshot.sh. Never print the key or token.
# Exit 0 on success; 1 when a Trello request fails or a list is missing. Test overrides:
# TRELLO_ENV_FILE, TRELLO_API_BASE.
set -u -o pipefail
. "$(dirname "${BASH_SOURCE[0]}")/kourai-env.sh"
env_file=${TRELLO_ENV_FILE:-$(kc paths.trello_env)}
api=${TRELLO_API_BASE:-https://api.trello.com/1}
board=$(kc board.id)
one=""
case "${1:-}" in
  "") ;;
  --creator) [ $# -eq 2 ] && [[ "$2" =~ ^[A-Za-z0-9]{8}$ ]] && one=$2 || { echo "usage: merged-cards.sh [--creator <shortLink>]" >&2; exit 2; } ;;
  *) echo "usage: merged-cards.sh [--creator <shortLink>]" >&2; exit 2 ;;
esac
set -a
# shellcheck disable=SC1090 # the env file is the caller's
. "$env_file"
set +a

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

get() { # get <file> <path> <query>: one Trello GET into $tmp/<file>, the key and token added
  curl -sf -o "$tmp/$1" "$api/$2?$3&key=$TRELLO_KEY&token=$TRELLO_TOKEN" \
    || { echo "merged-cards: Trello request failed: $2" >&2; exit 1; }
}

INTERNAL="$(kc board.members.user) $(kc board.members.agent) $(kc board.members.internal | tr '\n' ' ')"
uname_of() { # uname_of <member id>: the username, or nothing when it cannot be read
  [ -s "$tmp/m-$1" ] || curl -sf -o "$tmp/m-$1" "$api/members/$1?fields=username&key=$TRELLO_KEY&token=$TRELLO_TOKEN" || return 1
  jq -r '.username // empty' "$tmp/m-$1" 2>/dev/null
}
creator_of() { # creator_of <card id> <description file> <actions file>: the `creator:` value
  local reporters creator who u out=""
  reporters=$(grep -E '^REPORTER: @' "$2" | sed -E 's/^REPORTER: //' | tr ',' '\n' | sed -E 's/^ *//; s/ *$//' | grep -E '^@[A-Za-z0-9_]+$' | sort -u)
  creator=$(jq -r '[.[] | select(.type == "createCard")] | sort_by(.date) | (.[0].idMemberCreator // empty)' "$3") || { echo unknown; return; }
  [ -n "$creator" ] || creator=$(jq -r '[.[] | select(.type | IN("copyCard", "moveCardToBoard", "convertToCardFromCheckItem"))] | sort_by(.date) | (.[0].idMemberCreator // empty)' "$3")
  [ -n "$creator" ] || { [ -n "$reporters" ] || { echo unknown; return; }; }
  if [ -n "$creator" ] && ! grep -qw "$creator" <<<"$INTERNAL"; then
    u=$(uname_of "$creator") || u=""
    [ -n "$u" ] && out="@$u" || { [ -n "$reporters" ] || { echo unknown; return; }; }
  fi
  who=$(printf '%s\n%s\n' "$out" "$reporters" | grep -E '^@' | sort -u | paste -sd, -)
  if [ -n "$who" ]; then echo "external $who"; else echo internal; fi
}

if [ -n "$one" ]; then
  get c "cards/$one" "fields=desc"
  jq -r '.desc // ""' "$tmp/c" >"$tmp/c-desc"
  get ca "cards/$one/actions" "filter=createCard,copyCard,moveCardToBoard,convertToCardFromCheckItem&limit=1000&fields=date,type,idMemberCreator"
  echo "creator: $(creator_of "$one" "$tmp/c-desc" "$tmp/ca")"
  exit 0
fi

get lists "boards/$board/lists" "filter=open&fields=name,pos"
get cards "boards/$board/cards" "filter=open&fields=name,idList,idLabels,idMembers,shortLink,pos,desc"
get labels "boards/$board/labels" "fields=name,color&limit=1000"

# The lists of this script: MERGED first, then RELEASING, in board order.
jq -r '[.[] | select(.name | test("MERGED|RELEASING"))] | sort_by(.pos)[] | .id' "$tmp/lists" >"$tmp/list-ids"
[ -s "$tmp/list-ids" ] || { echo "merged-cards: MERGED and RELEASING lists not found" >&2; exit 1; }

# One small request per card for its comments and its moves between lists.
jq -r --slurpfile ids <(jq -R . "$tmp/list-ids" | jq -s .) \
  '.[] | select(.idList as $l | $ids[0] | index($l)) | "\(.id) \(.shortLink)"' "$tmp/cards" >"$tmp/card-ids"
while read -r id _; do
  get "a-$id" "cards/$id/actions" "filter=commentCard,updateCard:idList,createCard,copyCard,moveCardToBoard,convertToCardFromCheckItem&limit=1000&fields=date,data,type,idMemberCreator"
  jq -c --arg id "$id" '{key: $id, value: .}' "$tmp/a-$id" >>"$tmp/acts.jsonl"
  jq -r --arg id "$id" '.[] | select(.id == $id) | .desc // ""' "$tmp/cards" >"$tmp/d-$id"
  printf '%s\t%s\n' "$id" "$(creator_of "$id" "$tmp/d-$id" "$tmp/a-$id")" >>"$tmp/creators.tsv"
  rm -f "$tmp/a-$id"
done <"$tmp/card-ids"
touch "$tmp/acts.jsonl" "$tmp/creators.tsv"
jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: .[1]}) | from_entries' "$tmp/creators.tsv" >"$tmp/creators.json"
jq -nr --argjson repos "$(kourai-config json repos)" --slurpfile lists "$tmp/lists" --slurpfile cards "$tmp/cards" --slurpfile labels "$tmp/labels" \
  --slurpfile actl "$tmp/acts.jsonl" --slurpfile cre "$tmp/creators.json" '
  ($actl | from_entries) as $acts | ($lists[0]) as $lists | ($cards[0]) as $cards | ($labels[0]) as $labels
  | def minute: .[0:16] | sub("T"; " ");
  def short: . as $r | ($repos | map(select((.legacy_slugs // []) | index($r) != null)) | first // null) | if . then .slug else $r end;
  def shortref: (sub("#[0-9]+$"; "")) as $r | (sub("^.*#"; "")) as $n | "\($r | short)#\($n)";
  ($labels | map({key: .id, value: (if .name == "" then .color else .name end)}) | from_entries) as $lname
  | ([$lists[] | select(.name | test("MERGED|RELEASING"))] | sort_by(.pos)[]) as $l
  | ($cards | map(select(.idList == $l.id)) | sort_by(.pos)) as $lc
  | "== \($l.name) (\($lc | length) cards)",
    ($lc[] | . as $c | ($acts[$c.id] // []) as $a
      | "\($c.shortLink) | \($c.name | gsub("[\r\n]+"; " ") | .[0:100])"
        + " | labels: \(if ($c.idLabels | length) == 0 then "-" else [$c.idLabels[] | $lname[.] // "?"] | join(", ") end)"
        + " | members: \($c.idMembers | length)"
        + (if ($c.name | (startswith("⛔ BLOCKED:") or startswith("🚀 RELEASE:"))) then " | status card" else
            " | in list since: \(([$a[] | select(.type == "updateCard" and .data.listAfter.id == $l.id) | .date] | max // "-") | if . == "-" then . else minute end)"
            + " | prs: \([$a[] | select(.type == "commentCard") | (.data.text | split("\n")[0]) | select(startswith("PR:"))
                  | (scan("github\\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([0-9]+)"), scan("(?:^|[^A-Za-z0-9_./-])([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+)")) | "\(.[0] | short)#\(.[1])"]
                  | unique | if length == 0 then "-" else join(", ") end)"
            + " | merged: \([$a[] | select(.type == "commentCard") | .data.text
                  | (select(startswith("MERGED:")) | capture("^MERGED: (?<r>[A-Za-z0-9_./-]+#[0-9]+) @ (?<s>[0-9a-f]{7,40})") | "\(.r | shortref)@\(.s[0:12])"),
                    (select(startswith("MERGED WITH:")) | capture("^MERGED WITH: .*?(?<r>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+) @ (?<s>[0-9a-f]{7,40})") | "with:\(.r | shortref)@\(.s[0:12])")]
                  | unique | if length == 0 then "-" else join(", ") end)"
            + " | creator: \($cre[0][$c.id] // "unknown")"
            + " | reverted: \(if ([$a[] | select(.type == "commentCard") | .data.text | select(startswith("REVERTED:"))] | length) > 0 then "yes" else "no" end)"
          end))
'
