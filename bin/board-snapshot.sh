#!/bin/bash
# Cheap read of the whole board for the board-watcher: one line per card, no card
# descriptions (card "[AGENTS] Cut usage cost: a cheaper model for mechanical agents,
# smaller board-watcher and card-manager context, fewer spawns",
# https://trello.com/c/7M5YSnj4). Trello's list_by_board returns every card's full
# description (INTEGRATION TEST alone was about 63,000 characters on 2026-10-09); this
# prints what a pass needs to decide which cards to read in full.
# Usage: board-snapshot.sh [--done]
# Output, lists in board order, cards in list order (MERGING: 🚨 cards first, then [AGENTS] cards, then the rest, each in list
# order, the merge order of merger.md; a name starting with 🚨 counts, space or not):
#   == <list name> (<n> cards)
#   <shortLink> | <card name> | labels: <names or -> | members: <n> | status: <PHRASE> <date> | newest: <user|claude|other> <date>: <first 100 chars>[ | prs missing: <owner/repo>#<n>, ...][ | name prs: <(#N, server #M)|none>]
# A status card (its name starts with `⛔ BLOCKED:` or `🚀 RELEASE:`; card "[AGENTS] A "⛔ BLOCKED:" status
# card at the top of any list whose stage is held, kept current by the board-watcher",
# https://trello.com/c/phd02cLf) is never work: its line ends with `| status card` in
# place of `prs missing:` and `name prs:`.
# `prs missing:` (only when there are some) names each PR of a `PR: <url>` comment that
# the card's description names neither as owner/repo#n nor by its link (card "[AGENTS]
# Every card's description lists its PRs, as soon as each PR exists",
# https://trello.com/c/uGxXuQzv). Descriptions are read for that, never printed.
# `name prs:` (only when the card has no `prs missing:` and its name is wrong) is the
# ending the card's name should have: its open PRs, from the description's `**PR:**`
# lines without a `(closed` or `replaced by` note, mobile as `#N`, then server as
# `server #M`, for example `(#N, server #M)`; `none` when the name ends with PR numbers
# but no line is open (the user's decision, 2026-10-12, rules.md, PR links).
# PROPOSED, BUG REPORTS (and BRAINSTORM, PROPOSED's name until the lists are renamed)
# cards get the short form `<shortLink> | <card name>` (they are the user's: no agent
# acts on them). DONE shows only its header line (it held 241 cards on 2026-10-12); --done
# lists its cards in the short form too. `status:` is the newest comment that starts with a status phrase (capital
# words and a colon, as in the glossary, or IN PROGRESS / FINISHED); `newest:` is the
# newest comment of any kind, with its author: `user` (the user's own Trello account),
# `claude` (the Claude Code account the agents and the /run-board session post as) or
# `other`. Both look at the board's newest 1000 comments, read in pages of 300 (up to 4 pages, `before=<oldest id>`),
# because Trello answered 429 to one 1000-comment read (card https://trello.com/c/xXtokNFg; the 429 was transient and
# the slow big read the likeliest to get it); a card with none there shows `-`. Dates are UTC, to the minute.
# A request is tried up to 4 times (waits of 2, 4 and 8 seconds, RC_RETRY_SLEEP=0 in tests) when Trello answers 429 or
# 5xx or curl itself fails; any other answer is final.
# Only reads Trello, with the key in trello.env, like board-wait.sh. The token itself can write, so never print the key or token.
# Exit 0 on success; 1 when a Trello request fails (the caller falls back to the
# Trello MCP). Test overrides: TRELLO_ENV_FILE, TRELLO_API_BASE.
set -u -o pipefail
. "$(dirname "${BASH_SOURCE[0]}")/kourai-env.sh"
env_file=${TRELLO_ENV_FILE:-$(kc paths.trello_env)}
api=${TRELLO_API_BASE:-https://api.trello.com/1}
board=$(kc board.id)
user=$(kc board.members.user)
claude=$(kc board.members.agent)
case "${1:-}" in
  '') done=false ;;
  --done) done=true ;;
  *) echo "usage: board-snapshot.sh [--done]" >&2; exit 2 ;;
esac
set -a
# shellcheck disable=SC1090 # the env file is the caller's (default: paths.trello_env in the config)
. "$env_file"
set +a

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

get() { # get <file> <path> <query>: one Trello GET into $tmp/<file>, the key and token added; 429, 5xx and curl errors are retried
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
  echo "board-snapshot: Trello request failed: $2" >&2; exit 1
}

get lists "boards/$board/lists" "filter=open&fields=name,pos"
# desc is read only to find PRs missing from it; it is never printed.
get cards "boards/$board/cards" "filter=open&fields=name,idList,idLabels,idMembers,shortLink,pos,desc"
get labels "boards/$board/labels" "fields=name,color&limit=1000"
# The newest 1000 comments, newest first, in pages of 300 (a page shorter than 300 is the last).
before=""
for page in 1 2 3 4; do
  get "comments$page" "boards/$board/actions" "filter=commentCard&limit=300&fields=date,data,idMemberCreator${before:+&before=$before}"
  [ "$(jq length "$tmp/comments$page")" -ge 300 ] || break
  before=$(jq -r 'min_by(.date).id' "$tmp/comments$page")
done
jq -s 'add | .[0:1000]' "$tmp"/comments[1-4] >"$tmp/comments" || { echo "board-snapshot: unreadable Trello comments" >&2; exit 1; }

# Files, not arguments: the comments can be larger than the command line allows.
jq -nr --slurpfile lists "$tmp/lists" --slurpfile cards "$tmp/cards" --slurpfile labels "$tmp/labels" \
  --slurpfile comments "$tmp/comments" --arg user "$user" --arg claude "$claude" --argjson repos "$(kourai-config json repos)" --argjson "done" "$done" '
  ($lists[0]) as $lists | ($cards[0]) as $cards | ($labels[0]) as $labels | ($comments[0]) as $comments
  |
  def minute: .[0:16] | sub("T"; " ");
  def who: if . == $user then "user" elif . == $claude then "claude" else "other" end;
  def oneline: gsub("[\r\n]+"; " ") | .[0:100];
  # The PRs named by the `PR:` comments of a card that its description names neither as
  # owner/repo#n nor by link (rules.md, PR links), as "owner/repo#n", sorted.
  # The configured repo a name belongs to (its slug or one of its legacy slugs), or null.
  def repo_of: . as $r | ($repos | map(select(.slug == $r or ((.legacy_slugs // []) | index($r) != null))) | first // null);
  # A regex for a repo name. A repo that was renamed or moved is the same repo under its old names, so a PR named
  # either way is the same PR.
  def repo_re: (repo_of) as $x | if $x then "(" + ([$x.slug] + ($x.legacy_slugs // []) | map(gsub("\\."; "\\.")) | join("|")) + ")" else gsub("\\."; "\\.") end;
  def prs_missing($desc):
    [.[] | (.data.text | split("\n")[0]) | select(startswith("PR:"))
         | (scan("github\\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([0-9]+)"),
            scan("(?:^|[^A-Za-z0-9_./-])([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+)"))
         | "\(.[0])#\(.[1])"]
    | reverse | unique_by(.)
    | map(. as $ref | ($ref | split("#")) as $p
          | select(($desc | test("(^|[^A-Za-z0-9_./-])\($p[0] | repo_re)#\($p[1])([^0-9]|$)")
                   or ($desc | test("github\\.com/\($p[0] | repo_re)/pull/\($p[1])([^0-9]|$)"))) | not));
  # The ending the name of a card should have, from the open `**PR:**` lines of its description
  # (rules.md, PR links): " (#N, server #M)", or "" when it has none.
  def name_prs_wanted:
    [split("\n")[] | select(test("^\\*\\*PR:\\*\\* ")) | select(test("\\((closed|replaced by)") | not)
       | capture("^\\*\\*PR:\\*\\* (?<r>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#(?<n>[0-9]+)")]
    | (map((.r | repo_of) as $x | select($x != null) | {t: $x.card_name_tag, s: "\($x.card_name_tag)\(.n)"})
       | sort_by(if .t == "#" then 0 else 1 end) | map(.s))
    | reduce .[] as $x ([]; if index([$x]) then . else . + [$x] end)
    | if length == 0 then "" else " (\(join(", ")))" end;
  # The PR ending the name of a card has now: " (#N, server #M)", or "".
  def name_prs_has: (capture("(?<s> \\((server )?#[0-9]+(, (server )?#[0-9]+)*\\))$").s) // "";
  def phrase: (capture("^(?<p>[A-Z][A-Z*]*( [A-Z*]+)*:)") | .p)
    // (if test("^(IN PROGRESS|FINISHED)\\b") then capture("^(?<p>IN PROGRESS|FINISHED)").p else null end);
  ($labels | map({key: .id, value: (if .name == "" then .color else .name end)}) | from_entries) as $lname
  # comments come newest first: the first one per card is its newest
  | ($comments | group_by(.data.card.id)
      | map({key: .[0].data.card.id,
             value: {newest: .[0],
                     status: (map(select((.data.text | phrase) != null)) | .[0]),
                     all: .}})
      | from_entries) as $byc
  | $lists | sort_by(.pos)[] as $l
  | ($cards | map(select(.idList == $l.id)) | sort_by(.pos)
      | if ($l.name | test("MERGING"))
        then (map(select(.name | startswith("🚨")))
             + map(select((.name | startswith("🚨") | not) and (.name | sub("^🪲 *";"") | startswith("[AGENTS]"))))
             + map(select((.name | startswith("🚨") | not) and (.name | sub("^🪲 *";"") | startswith("[AGENTS]") | not))))
        else . end) as $lc
  | "== \($l.name) (\($lc | length) cards)",
    ($lc[] |
      if ($l.name | test("DONE")) and ($done | not) then empty
      elif ($l.name | test("DONE|BRAINSTORM|PROPOSED|BUG REPORTS")) then "\(.shortLink) | \(.name)"
      else
        ($byc[.id] // {}) as $c
        | "\(.shortLink) | \(.name) | labels: \(if (.idLabels | length) == 0 then "-" else [.idLabels[] | $lname[.] // "?"] | join(", ") end)"
          + " | members: \(.idMembers | length)"
          + " | status: \(if $c.status then "\($c.status.data.text | phrase) \($c.status.date | minute)" else "-" end)"
          + " | newest: \(if $c.newest then "\($c.newest.idMemberCreator | who) \($c.newest.date | minute): \($c.newest.data.text | oneline)" else "-" end)"
          + (if (.name | (startswith("⛔ BLOCKED:") or startswith("🚀 RELEASE:"))) then " | status card" else
            (((.desc // "") as $d | ($c.all // []) | prs_missing($d)) as $m
             | if ($m | length) > 0 then " | prs missing: \($m | join(", "))"
               else ((.desc // "") | name_prs_wanted) as $w
                 | if (.name | name_prs_has) == $w then ""
                   elif $w == "" then " | name prs: none"
                   else " | name prs: \($w[1:])" end
               end) end)
      end)
'
