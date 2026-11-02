#!/bin/bash
# Claude Code PreToolUse hook (Bash): lets the promoter release to staging, which
# auto mode otherwise refuses, but only the pair its full test passed on. For
# every other command it prints nothing, so normal permission handling applies.
#
# Two pushes are covered, each written with a literal SHA or tag name:
#   - `git push origin <sha>:refs/heads/staging` in the server repo: allowed
#     when <sha> fast-forwards origin/staging, is on development or on a release branch (origin/release/*, cut from a release's pin),
#     and a card's
#     full-test comment names `development @ <sha>`;
#   - `git push origin client-build/<name>+<n>` in the app repo: allowed when the
#     tag's commit is on main or on a release branch and a card's full-test comment names `main @ <sha>`.
# A full-test comment is either
#   - `FULL SUITE GREEN: main @ <m>, development @ <d>` (every test passed the
#     first time), or
#   - `GREEN*: main @ <m>, development @ <d>` (some passed only on their rerun)
#     when, after the newest GREEN* comment on its card, the user's own Trello
#     account wrote "ship" (a comment that starts with "ship") and no "hold"
#     after that. Agents post as the separate Claude account, so they can't
#     produce it.
# A push of either kind that fails a check is denied (fail closed). The board is read newest
# first in pages of 300 back over the last 14 days (RC_GATE_DAYS); when no full-test comment
# names the commit and the read stopped at the window, the reason starts
#   `staging-gate: NO FULL-TEST COMMENT IN WINDOW: … (read back to <date>)`
# and the promoter reruns the full test (promoter.md). The hook has one deadline (RC_HOOK_DEADLINE,
# 50 s) and tries a Trello request at most twice; the reasons the promoter keys on, in full:
#   `staging-gate: TIMED OUT: <step> at <n>s`   `staging-gate: TRANSIENT: <step> (<why>)`
#   `staging-gate: CRASHED: <step>` (stderr, exit 2)
# each retried once with the same command; a second one is the promoter's manual step.
# Fail-closed on the 60 s timeout needs `"onFailure": "block"` on the hook's settings entry.
#
# Only reads Trello, with the key in paths.trello_env
# (that token can write too, so this hook only ever sends GETs).
# Never prints the key or token.
set -u -o pipefail

. "${KOURAI_BIN:?this hook needs KOURAI_BIN (the installer hook registration sets it)}/kourai-env.sh"
BOARD=$(kc board.id)
SRV=$(kc repos.server.path)
APP=$(kc repos.app.path)
TRELLO_ENV=$(kc paths.trello_env)
USER_MEMBER=$(kc board.members.user)

input=$(cat)
cmd=$(jq -r '.tool_input.command // ""' <<<"$input")

decide() { # decide allow|deny <reason>
  jq -n --arg d "$1" --arg r "staging-gate: $2" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
  exit 0
}

GATE=staging-gate
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

push='git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+push'
if grep -Eq "$push" <<<"$cmd" && grep -Eq 'refs/heads/staging|:staging([[:space:]]|$)' <<<"$cmd"; then
  kind=server
elif grep -Eq "${push}[^;&|]*client-build/" <<<"$cmd"; then
  kind=client
else
  exit 0
fi

GATED=1   # from here on this gate is deciding: a crash or a timeout blocks
# One push per command, nothing chained, so what's checked is what runs.
grep -Eq '&&|\|\||;|\||`|\$\(' <<<"$cmd" && decide deny "run the push on its own, with no other commands chained"
grep -q '\$' <<<"$cmd" && decide deny "write the SHA or tag literally, not as a variable"
grep -Eq '(^|[[:space:]])(-f|--force|--force-with-lease|--delete|-d|--mirror|--all|--tags)([[:space:]=]|$)|[[:space:]]\+[^[:space:]]' <<<"$cmd" \
  && decide deny "no force, delete or bulk pushes"

[ -r "$TRELLO_ENV" ] || decide deny "can't read the Trello credentials"
TRELLO_KEY=$(sed -n 's/^TRELLO_KEY=//p' "$TRELLO_ENV")
TRELLO_TOKEN=$(sed -n 's/^TRELLO_TOKEN=//p' "$TRELLO_ENV")
# Every comment on the board, newest first: "<card>\t<creator>\t<first line>".
all="" before="" pages=0 cutoff=$(gate_cutoff) readback=""
while :; do
  pages=$((pages + 1))
  board_page "$pages" "$before"
  page=$TG_OUT
  STEP="reading board page $pages"
  all+=$(jq -r '.[] | [.data.card.id, .idMemberCreator, ((.data.text // "") | split("\n")[0])] | @tsv' <<<"$page") \
    || decide deny "can't read the Trello board"
  all+=$'\n'
  [ "$(jq length <<<"$page")" -lt "$PAGE" ] && break   # the whole board has been read
  last=$(jq -r '.[-1].date // ""' <<<"$page")
  before=$(jq -r '.[-1].id' <<<"$page")
  if [ -n "$last" ] && [[ "$last" < "$cutoff" ]]; then readback=${last%%T*}; break; fi
done
none="no FULL SUITE GREEN, and no GREEN* with the user's \"ship\" after it, names"
[ -z "$readback" ] || none="NO FULL-TEST COMMENT IN WINDOW: $none"
tail_note=""; [ -z "$readback" ] || tail_note=" (read back to $readback)"

# The user's answer in a comment's first line: "ship" or "hold" when it starts
# with that word (case and leading quotes or bold marks ignored), else nothing.
user_answer() { # user_answer <first line>
  local l re='^[[:space:]"*_]*(ship|hold)([^a-z]|$)'
  l=$(tr 'A-Z' 'a-z' <<<"$1")
  [[ "$l" =~ $re ]] && echo "${BASH_REMATCH[1]}"
}

# The full-test comments that count: every FULL SUITE GREEN, and the newest
# GREEN* of a card when the user's newest answer after it is "ship". Read newest
# first, so per card the first answer read is the newest one, and only answers
# read before the card's first (newest) GREEN* count.
fulls=$(awk -F'\t' '$3 ~ /^FULL SUITE GREEN:/ {print $3}' <<<"$all")$'\n'
answers="" seen=""
while IFS=$'\t' read -r card who line; do
  [ -n "$card" ] || continue
  case "$seen" in *"|$card|"*) continue ;; esac   # older than the card's newest GREEN*
  if [[ "$line" == "GREEN*:"* ]]; then
    case "$answers" in *"|$card=ship|"*) fulls+="$line"$'\n' ;; esac
    seen+="|$card|"
  elif [ "$who" = "$USER_MEMBER" ]; then
    case "$answers" in *"|$card="*) continue ;; esac
    a=$(user_answer "$line")
    [ -n "$a" ] && answers+="|$card=$a|"
  fi
done <<<"$all"

on_branch() { # on_branch <repo> <full sha> <base>: on origin/<base>, or on a release branch (origin/release/*) cut from it
  local r
  git -C "$1" merge-base --is-ancestor "$2" "origin/$3" && return 0
  for r in $(git -C "$1" for-each-ref --format='%(refname)' refs/remotes/origin/release/); do
    git -C "$1" merge-base --is-ancestor "$2" "$r" && return 0
  done
  return 1
}

named() { # named <full sha> <main|development> <comments>: does one of them name it (7+ char prefix)?
  local full=$1 branch=$2 s
  for s in $(grep -Eo "$branch @ [0-9a-f]{7,40}" <<<"$3" | awk '{print $3}'); do
    [[ "$full" == "$s"* ]] && return 0
  done
  return 1
}

if [ "$kind" = server ]; then
  ref=$(grep -Eo '[0-9a-f]{7,40}:(refs/heads/)?staging' <<<"$cmd" | head -1)
  [ -z "$ref" ] && decide deny "push a literal commit SHA: <sha>:refs/heads/staging"
  chk_left "fetching the server repo"
  git -C "$SRV" fetch -q origin staging development 'refs/heads/release/*:refs/remotes/origin/release/*' || decide deny "can't fetch the server repo"
  sha=$(git -C "$SRV" rev-parse --verify -q "${ref%%:*}^{commit}") || decide deny "unknown commit ${ref%%:*}"
  git -C "$SRV" merge-base --is-ancestor origin/staging "$sha" || decide deny "${sha:0:7} doesn't fast-forward staging"
  on_branch "$SRV" "$sha" development || decide deny "${sha:0:7} isn't on development or a release branch"
  named "$sha" development "$fulls" || decide deny "$none development @ ${sha:0:7}$tail_note"
  decide allow "development @ ${sha:0:7} passed the full test; fast-forwarding staging"
else
  tag=$(grep -Eo 'client-build/[A-Za-z0-9._+-]+' <<<"$cmd" | head -1)
  sha=$(git -C "$APP" rev-parse --verify -q "refs/tags/$tag^{commit}") || decide deny "tag $tag doesn't exist locally; create it first, in its own command"
  chk_left "fetching the app repo"
  git -C "$APP" fetch -q origin main 'refs/heads/release/*:refs/remotes/origin/release/*' || decide deny "can't fetch the app repo"
  on_branch "$APP" "$sha" main || decide deny "$tag (${sha:0:7}) isn't on main or a release branch"
  named "$sha" main "$fulls" || decide deny "$none main @ ${sha:0:7}$tail_note"
  decide allow "$tag is main @ ${sha:0:7}, which passed the full test"
fi
