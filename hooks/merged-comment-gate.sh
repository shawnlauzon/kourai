#!/bin/bash
# Claude Code PreToolUse hook (mcp__trello__trelloWriteCard): lets the merger post
# its `MERGED: <repo>#<n> @ <sha>` comment after a merge, which auto mode otherwise
# refuses as "Merge Without Review". Every other Trello write gets no output, so
# normal permission handling applies.
#
# A `MERGED:` comment is allowed only when:
#   - <repo>#<n> really is merged, with merge commit <sha> (GitHub),
#   - the card it's posted on has a comment naming that PR's URL,
#   - the card is now in MERGING, MERGED or DONE, and
#   - `review-policy.sh check <repo>#<n>` (next to this hook, as in merge-gate)
#     says NO REVIEW NEEDED or APPROVED. A GitHub approval is the only acceptance.
# A `MERGED:` comment that fails any check is denied (fail closed). So is a slow or failing
# read: the hook has one deadline (RC_HOOK_DEADLINE, 50 s) and tries a Trello request at most
# twice; the reasons the merger keys on, in full (merger.md):
#   `merged-comment-gate: TIMED OUT: <step> at <n>s`
#   `merged-comment-gate: TRANSIENT: <step> (<why>)`
#   `merged-comment-gate: CRASHED: <step>` (stderr, exit 2)
# They apply to the `MERGED:` comment only. The merger sends SHOW RETRY:, posts the same comment
# once more, and a second one is its manual step. Fail-closed on the 60 s timeout needs
# `"onFailure": "block"` on the hook's settings entry (user-setup-changes.md).
#
# It also lets the merger move a card on after its merge, which auto mode refuses
# the same way: a move out of MERGING into MERGED or DONE is allowed when the card
# has at least one `MERGED:` comment and every one of them names a PR that really
# is merged at that SHA. (Those comments could only be posted through this gate.)
# Other moves get no decision. The MOVE path is allow-only and fails open BY DESIGN: GATED is never
# set there, so a slow or failing read, a timeout or a crash ends it with no decision and exit 0
# (normal permission handling then decides). Its reads still use the two-try rule and the deadline.
#
# The lists keep their Trello ids across renames: MERGING was APPROVED, MERGED was
# READY FOR STAGING.
#
# Only reads Trello, with the key in paths.trello_env
# (that token can write too, so this hook only ever sends GETs).
# Never prints the key or token.
set -u -o pipefail

. "${KOURAI_BIN:?this hook needs KOURAI_BIN (the installer hook registration sets it)}/kourai-env.sh"
MERGING_LIST=$(kc board.lists.merging.id)
MERGED_LIST=$(kc board.lists.merged.id)
DONE_LIST=$(kc board.lists.done.id)
TRELLO_ENV=$(kc paths.trello_env)
POLICY() { "$KOURAI_BIN/kourai-hook" review-policy.sh "$@"; }

input=$(cat)
action=$(jq -r '.tool_input.action // ""' <<<"$input")
text=$(jq -r '.tool_input.text // ""' <<<"$input")

decide() { # decide allow|deny <reason>
  jq -n --arg d "$1" --arg r "merged-comment-gate: $2" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
  exit 0
}

GATE=merged-comment-gate
# ---- gate-common v1: this block is the same in merge-gate.sh, staging-gate.sh and
# merged-comment-gate.sh (test-hook-trello-retry.sh compares the three). ----
# One deadline for the whole hook (RC_HOOK_DEADLINE, default 50 s: Claude Code cancels a hook at its
# 60 s timeout, and a cancelled PreToolUse hook lets the call through unless its settings entry says
# "onFailure": "block"). Every Trello request and every gh call is checked against it first; when it
# is spent the gate denies `<gate>: TIMED OUT: <step> at <n>s`. A Trello request is tried at most twice
# (a 429, a 5xx, or a curl network error 6, 7, 28, 35, 52 or 56; one wait of RC_RETRY_SLEEP, default
# 2 s between); two transient failures deny `<gate>: TRANSIENT: <step> (<why>)`. Any other failure
# (a 4xx, curl exit 22) is not retried. A gated command that crashes (an unbound variable and the
# like) leaves through the EXIT trap with `<gate>: CRASHED: <step>` on stderr and exit 2, which
# blocks. Before GATED=1 (a command that is not this gate's business) a crash or a timeout
# lets the call through with no output and exit 0, as before.
T0=$SECONDS
DEADLINE=${RC_HOOK_DEADLINE:-50}
STEP=start GATED=0 TG_OUT=""
trap 'rc=$?; if [ "$rc" -ne 0 ]; then [ "$GATED" = 1 ] || exit 0; printf "%s: CRASHED: %s\n" "$GATE" "$STEP" >&2; exit 2; fi' EXIT
left() { echo $(( DEADLINE - (SECONDS - T0) )); }
gate_stop() { if [ "$GATED" = 1 ]; then decide deny "$1"; fi; exit 0; }
chk_left() { # chk_left <step>: before every gh call, Trello request, wait and paging step
  STEP=$1
  [ "$(left)" -gt 0 ] || gate_stop "TIMED OUT: $1 at $((SECONDS - T0))s"
}
tget() { # tget <step> <reason if the read fails for good> <curl args...>: the body in TG_OUT
  local step=$1 perm=$2 try=0 l mt out code http why sl
  shift 2
  : "${RC_TEST_UNSET_FOR_CRASH:+${RC_TEST_CRASH_VAR}}"   # tests only: an unbound variable, to prove the crash path
  while :; do
    chk_left "$step"
    l=$(left); mt=10; [ "$l" -lt 10 ] && mt=$l
    [ "$mt" -ge 1 ] || mt=1   # never --max-time 0 (no limit) when the deadline ticks over here
    try=$((try + 1))
    out=$(curl -s -G --max-time "$mt" -w '\n%{http_code}' "$@" 2>/dev/null); code=$?
    http=${out##*$'\n'}
    case "$http" in [0-9][0-9][0-9]) out=${out%$'\n'*} ;; *) http=200 ;; esac
    why=""
    if [ "$code" -ne 0 ]; then
      case "$code" in 6|7|28|35|52|56) why="curl exit $code" ;; *) gate_stop "$perm" ;; esac
    else
      case "$http" in 2??) TG_OUT=$out; return 0 ;; 429|5??) why="HTTP $http" ;; *) gate_stop "$perm" ;; esac
    fi
    [ "$try" -lt 2 ] || gate_stop "TRANSIENT: $step ($why)"
    sl=${RC_RETRY_SLEEP:-2}
    [ "$(left)" -gt "$sl" ] || gate_stop "TIMED OUT: $step at $((SECONDS - T0))s"
    sleep "$sl"
  done
}
trello_get() { # trello_get <step> <failure reason> <path> [curl args...]
  local step=$1 perm=$2 path=$3
  shift 3
  tget "$step" "$perm" "https://api.trello.com/1$path" \
    --data-urlencode "key=$TRELLO_KEY" --data-urlencode "token=$TRELLO_TOKEN" "$@"
}
PAGE=${RC_GATE_PAGE:-300}
board_page() { # board_page <n> [<before id>]: one page of the board's comments, newest first, in TG_OUT
  trello_get "board page $1" "can't read the Trello board" "/boards/${BOARD:-}/actions" \
    --data-urlencode filter=commentCard --data-urlencode limit="$PAGE" ${2:+--data-urlencode "before=$2"}
}
gate_cutoff() { # the start of the window (RC_GATE_DAYS, default 14) as a Trello date, to compare as text
  date -u -v-"${RC_GATE_DAYS:-14}"d +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null \
    || date -u -d "${RC_GATE_DAYS:-14} days ago" +%Y-%m-%dT%H:%M:%S.000Z
}
# ---- end of gate-common v1 ----

if [ "$action" = move ]; then
  dest=$(jq -r '.tool_input.listId // ""' <<<"$input"); dest=${dest##*/}
  case "$dest" in "$MERGED_LIST"|"$DONE_LIST") ;; *) exit 0 ;; esac
  card=$(jq -r '.tool_input.cardId // ""' <<<"$input"); card=${card##*/}
  [[ "$card" =~ ^[0-9a-f]{24}$ ]] || exit 0
  [ -r "$TRELLO_ENV" ] || exit 0
  TRELLO_KEY=$(sed -n 's/^TRELLO_KEY=//p' "$TRELLO_ENV")
  TRELLO_TOKEN=$(sed -n 's/^TRELLO_TOKEN=//p' "$TRELLO_ENV")
  trello_get "the comments of card $card" "" "/cards/$card/actions" \
    --data-urlencode filter=commentCard --data-urlencode limit=1000
  merged=$(jq -r '.[].data.text | select(startswith("MERGED: ")) | split("\n")[0]' <<<"$TG_OUT") || exit 0
  [ -z "$merged" ] && exit 0   # not a post-merge move; normal permission handling
  # Only the step right after a merge: the card must be leaving MERGING. Later moves
  # (e.g. MERGED -> RELEASING -> DONE) get no decision here.
  trello_get "card $card" "" "/cards/$card" --data-urlencode fields=idList
  from=$(jq -r .idList <<<"$TG_OUT") || exit 0
  [ "$from" = "$MERGING_LIST" ] || exit 0
  while read -r line; do
    [[ "$line" =~ ^MERGED:\ ([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+)\ @\ ([0-9a-f]{40}) ]] || exit 0
    r=${BASH_REMATCH[1]} n=${BASH_REMATCH[2]} h=${BASH_REMATCH[3]}
    chk_left "the state of $r#$n"
    got=$(gh pr view "$n" --repo "$r" --json state,mergeCommit -q '"\(.state) \(.mergeCommit.oid // "")"' 2>/dev/null) || exit 0
    [ "$got" = "MERGED $h" ] || exit 0
  done <<<"$merged"
  decide allow "every MERGED comment on this card names a PR merged at that SHA"
fi

[ "$action" = add_comment ] || exit 0
[[ "$text" == MERGED:* ]] || exit 0
GATED=1   # from here on this gate is deciding the MERGED: comment: a crash or a timeout blocks

if ! [[ "$text" =~ ^MERGED:\ ([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+)\ @\ ([0-9a-f]{40}) ]]; then
  decide deny "a MERGED comment must start \"MERGED: <owner/repo>#<n> @ <40-char sha>\""
fi
repo=${BASH_REMATCH[1]} num=${BASH_REMATCH[2]} sha=${BASH_REMATCH[3]}
pr_url="https://github.com/$repo/pull/$num"

chk_left "the state of $repo#$num"
got=$(gh pr view "$num" --repo "$repo" --json state,mergeCommit -q '"\(.state) \(.mergeCommit.oid // "")"' 2>/dev/null) \
  || decide deny "can't read $pr_url"
[ "$got" = "MERGED $sha" ] || decide deny "$pr_url is not merged at $sha"

card=$(jq -r '.tool_input.cardId // ""' <<<"$input")
card=${card##*/}
[[ "$card" =~ ^[0-9a-f]{24}$ ]] || decide deny "can't tell which card this comment is for"

[ -r "$TRELLO_ENV" ] || decide deny "can't read the Trello credentials"
TRELLO_KEY=$(sed -n 's/^TRELLO_KEY=//p' "$TRELLO_ENV")
TRELLO_TOKEN=$(sed -n 's/^TRELLO_TOKEN=//p' "$TRELLO_ENV")
trello_get "card $card" "can't read Trello card $card" "/cards/$card" --data-urlencode fields=idList,shortUrl
info=$TG_OUT
short=$(jq -r .shortUrl <<<"$info")
list=$(jq -r .idList <<<"$info")
case "$list" in
  "$MERGING_LIST"|"$MERGED_LIST"|"$DONE_LIST") ;;
  *) decide deny "$short isn't in MERGING, MERGED or DONE" ;;
esac

trello_get "the comments of card $card" "can't read $short's comments" "/cards/$card/actions" \
  --data-urlencode filter=commentCard --data-urlencode limit=1000
comments=$TG_OUT
# every name of the repo (its slug and legacy_slugs): a card that names the PR may use an older one
names=""
while IFS= read -r nm; do [ -n "$nm" ] && names+="${names:+|}${nm//./\\.}"; done < <(kourai-config json repos \
  | jq -r --arg r "$repo" '([.[] | select(.slug == $r or ((.legacy_slugs // []) | index($r) != null)) | [.slug] + (.legacy_slugs // [])] | first) // [$r] | .[]')
[ -n "$names" ] || names="${repo//./\\.}"
# and it may name the PR by its full URL or as <owner>/<repo>#<n>
pattern="(github\\.com/(${names})/pull/${num}|(^|[^A-Za-z0-9_./-])(${names})#${num})([^0-9]|$)"
jq -e --arg p "$pattern" 'any(.[]; .data.text | test($p))' <<<"$comments" >/dev/null \
  || decide deny "$short has no comment naming $pr_url"

# The review policy, as in merge-gate: the PR needed no review, or the user
# approved it on GitHub (also across merges of its base, conflict resolutions
# included).
chk_left "the review policy"
policy=$(POLICY check "$repo#$num" 2>/dev/null)
[ $? = 0 ] || decide deny "${policy:-ERROR: the review policy printed nothing}"
decide allow "$pr_url is merged at ${sha:0:7}; $policy"
