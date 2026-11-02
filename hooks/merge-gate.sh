#!/bin/bash
# Claude Code PreToolUse hook (Bash): lets a `gh pr merge` through only when the
# review policy allows that PR to merge and, on an [AGENTS] card, the workflow
# verifier agreed with its head. For every other command it prints nothing, so
# normal permission handling applies.
#
# Only a command that IS a merge is checked: one that starts with `gh pr merge`,
# or with `as-claude.sh <owner/repo> gh pr merge`. A command that merely contains
# the words (a heredoc, a quoted string, a script being written, a commit message)
# is not a merge and gets no decision here. A merge command must be the whole
# command: anything chained after it (`;`, `&&`, `||`, `|`, a redirect, a new line,
# `$(…)` or backticks) is denied, so nothing rides along on the allow. It must
# name the PR and `--match-head-commit <40-char sha>`, so GitHub merges exactly
# the commit that was checked.
#
# A merge is allowed when all of these hold:
#   - `review-policy.sh check <repo>#<n> <sha>` (next to this hook) says NO
#     REVIEW NEEDED or APPROVED: the PR changes nothing the user reviews, or the
#     user approved it on GitHub (on its head, or on a commit after which it only
#     took merges of its base). A GitHub approval is the only acceptance; a card
#     the user drags on Trello approves nothing;
#   - at least one card on the board has a comment naming
#     the PR's URL (its `PR:` line). The board is read newest first in pages of 300
#     back over the last 14 days (RC_GATE_DAYS); when no card is found in that
#     window the read goes on, page by page, until 35 s have passed. So "every card
#     naming the PR" (the next item) means every such card the read reached: the cards
#     whose `PR:` line is inside the window or was found by the extended read; an older
#     second card beyond the stop is not read (the user approved this narrowing with
#     the plan of card zE1yLOpq, 2026-11-01). No card found denies
#     `merge-gate: NO PR CARD (read back to <date>): …`; the merger posts a fresh `PR:`
#     line on its card and retries once (merger.md);
#   - on every such card that is an [AGENTS] card (its name starts with
#     `[AGENTS]`, or with 🚨 or 🪲 and then `[AGENTS]`): a comment
#     `VERIFIED: <repo>#<n> @ <sha>` names exactly this head (the workflow
#     verifier's, or the main session's after an independent review) and no
#     newer `VERIFY FAILED: <repo>#<n> @ <sha>` names the same head (the newest
#     of the two for this PR and head decides); or, when no verdict names this
#     head, an earlier VERIFIED: carries to it: a conflict-only fix (the user's
#     decision, 2026-10-18, card mWg2nZnw). The newest verdict for this PR is a
#     VERIFIED: at a commit A, no send-back (VERIFY FAILED:, CHECK FAILED:,
#     CHANGES REQUESTED:, REVERTED:) is newer than it, at least one
#     `CONFLICT RESOLVED: <repo>#<n>: …` or `REFRESHED: <repo>#<n>: …` is newer
#     and every such comment says "no behavior change" on its first line, and
#     `verified-carry.sh <repo>#<n> <A> <head>` (in ../bin) prints CARRIED: (only
#     merges of the base and empty commits since A). A card with a VERIFIED: for
#     this PR whose carry fails is denied with a reason that starts
#     `merge-gate: NOT CARRIED: <repo>#<n> @ <head7>: <why>`; the merger keys on
#     that text (merger.md), so keep it exact.
#   - Screenshots are never in git: a mobile PR that adds or changes a file under
#     docs/ui_tests/ is denied with `merge-gate: SCREENSHOTS IN GIT: <repo>#<n> adds or
#     changes <files>; …`; a file list that can't be read is denied with
#     `merge-gate: CANNOT LIST FILES: <repo>#<n>: <why>` (the merger keys on both).
# A green* merge check (some tests passed only on their rerun) needs no sign-off:
# the user's decision of 2026-10-15 makes the user the manual gate only for a
# green* push to staging (staging-gate.sh).
# Anything else, including any error, denies the merge (fail closed). That includes the
# clock: the hook has one deadline (RC_HOOK_DEADLINE, 50 s; see gate-common below) and a
# Trello request is tried at most twice. The reasons the merger keys on, written in full:
#   `merge-gate: TIMED OUT: <step> at <n>s`    the deadline ran out
#   `merge-gate: TRANSIENT: <step> (<why>)`    two tries at one Trello read both failed
#   `merge-gate: CRASHED: <step>`              stderr, exit 2: the hook itself broke
# These three are retried once with the same command; a second one is the merger's manual step.
# Fail-closed on the 60 s timeout needs `"onFailure": "block"` on the hook's settings entry
# (user-setup-changes.md); without it Claude Code lets the call through when it cancels a hook.
#
# Only reads Trello, with the key in paths.trello_env
# (that token can write too, so this hook only ever sends GETs).
# Never prints the key or token.
set -u -o pipefail

. "${KOURAI_BIN:?this hook needs KOURAI_BIN (the installer hook registration sets it)}/kourai-env.sh"
BOARD=$(kc board.id)
TRELLO_ENV=$(kc paths.trello_env)
POLICY() { "$KOURAI_BIN/kourai-hook" review-policy.sh "$@"; }
CARRY="$KOURAI_BIN/verified-carry.sh"

input=$(cat)
cmd=$(jq -r '.tool_input.command // ""' <<<"$input")
cwd=$(jq -r '.cwd // ""' <<<"$input")

decide() { # decide allow|deny <reason>
  jq -n --arg d "$1" --arg r "merge-gate: $2" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
  exit 0
}

GATE=merge-gate
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

# Merging through the REST API would skip the checks below; only `gh pr merge` is allowed.
if grep -Eq 'pulls/[0-9]+/merge|mergePullRequest' <<<"$cmd"; then
  decide deny "merge PRs only with \`gh pr merge\`, so the approval can be checked"
fi

# Is this command a merge? Only when it starts with `gh pr merge`, optionally
# behind `as-claude.sh <owner/repo>` (by any path, optionally run with `bash`).
merge_re='^[[:space:]]*((bash[[:space:]]+)?[^[:space:]]*as-claude\.sh[[:space:]]+[^[:space:]]+[[:space:]]+)?gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
[[ "$cmd" =~ $merge_re ]] || exit 0
GATED=1   # from here on this gate is deciding: a crash or a timeout blocks

# The merge must be the whole command, so the allow covers nothing else.
nl=$'\n'
case "$cmd" in
  *"$nl"*|*';'*|*'&'*|*'|'*|*'<'*|*'>'*|*'`'*|*'$('*)
    decide deny "a merge must be its own plain command (nothing chained, piped, redirected or substituted)" ;;
esac

# The words after `gh pr merge`.
args=${cmd#"${BASH_REMATCH[0]}"}
read -r -a words <<<"$args"
repo="" target="" match=""
i=0
while [ $i -lt ${#words[@]} ]; do
  w=${words[$i]}
  case "$w" in
    --repo|-R) i=$((i+1)); repo=${words[$i]:-} ;;
    --repo=*) repo=${w#--repo=} ;;
    --match-head-commit) i=$((i+1)); match=${words[$i]:-} ;;
    --match-head-commit=*) match=${w#--match-head-commit=} ;;
    -*) ;;
    *) [ -z "$target" ] && target=$w ;;
  esac
  i=$((i+1))
done
target=${target//\"/}; target=${target//\'/}
repo=${repo//\"/}; repo=${repo//\'/}
match=${match//\"/}; match=${match//\'/}

if [[ "$target" =~ ^https://github\.com/([^/]+/[^/]+)/pull/([0-9]+) ]]; then
  repo=${BASH_REMATCH[1]}; num=${BASH_REMATCH[2]}
else
  if [ -z "$repo" ]; then
    url=$(git -C "${cwd:-.}" remote get-url origin 2>/dev/null) || decide deny "can't tell which repo (no --repo and no git remote)"
    repo=$(sed -E 's#(git@github\.com:|https://github\.com/)##; s#\.git$##' <<<"$url")
  fi
  if [[ "$target" =~ ^[0-9]+$ ]]; then
    num=$target
  else
    decide deny "name the PR to merge by its number or URL"
  fi
fi
pr_url="https://github.com/$repo/pull/$num"
ref="$repo#$num"
[[ "$match" =~ ^[0-9a-f]{40}$ ]] || decide deny "add --match-head-commit <the PR's 40-character head sha>, so GitHub merges exactly the commit that was checked"

# 1. The review policy: no review needed, or approved on GitHub.
chk_left "the review policy"
policy=$(POLICY check "$ref" "$match" 2>/dev/null)
[ $? = 0 ] || decide deny "${policy:-ERROR: the review policy printed nothing}"

# 1b. Screenshots are never in git (the user's decision, 2026-10-22, card 6U8HrveL):
# a mobile PR that adds or changes any file under docs/ui_tests/ is denied; deleting
# one is allowed. A file list that cannot be read (or is the API's 3000-file cap) denies.
# The merger keys on both texts (merger.md), so keep them exact.
# A repo with no_add_paths (config): a PR that adds or changes a file under one is denied; deleting one is allowed.
no_add=$(kourai-config json repos | jq -r --arg r "$repo" '[.[] | select(.slug == $r or ((.legacy_slugs // []) | index($r) != null))] | first | (.no_add_paths // [])[]')
if [ -n "$no_add" ]; then
  chk_left "the file list of $ref"
  files=$(gh api --paginate "repos/$repo/pulls/$num/files?per_page=100" --jq '.[] | [.status, .filename] | @tsv' 2>&1) \
    || decide deny "CANNOT LIST FILES: $ref: $(head -c 200 <<<"$files" | tr '\n' ' ')"
  [ "$(grep -c . <<<"$files")" -lt 3000 ] || decide deny "CANNOT LIST FILES: $ref: the file list reached GitHub's 3000-file cap"
  bad=$(awk -F'\t' -v prefixes="$no_add" 'BEGIN { n = split(prefixes, p, "\n") } $1 != "removed" { for (i = 1; i <= n; i++) if (p[i] != "" && index($2, p[i]) == 1) { print $2; break } }' <<<"$files" | head -5 | paste -sd, -)
  [ -z "$bad" ] || decide deny "SCREENSHOTS IN GIT: $ref adds or changes $bad; screenshots are card attachments only (rules.md, Screenshots)"
fi

# 2. The cards that name this PR.
[ -r "$TRELLO_ENV" ] || decide deny "$policy; but can't read the Trello credentials"
TRELLO_KEY=$(sed -n 's/^TRELLO_KEY=//p' "$TRELLO_ENV")
TRELLO_TOKEN=$(sed -n 's/^TRELLO_TOKEN=//p' "$TRELLO_ENV")
# every name of the repo (its slug and legacy_slugs): a card that names the PR may use an older one
names=""
while IFS= read -r nm; do [ -n "$nm" ] && names+="${names:+|}${nm//./\\.}"; done < <(kourai-config json repos \
  | jq -r --arg r "$repo" '([.[] | select(.slug == $r or ((.legacy_slugs // []) | index($r) != null)) | [.slug] + (.legacy_slugs // [])] | first) // [$r] | .[]')
[ -n "$names" ] || names="${repo//./\\.}"
# and counts as naming it only on a "PR:" line, by its full URL or as <owner>/<repo>#<n>
pattern="^PR:[^\n]*(github\\.com/(${names})/pull/${num}|(^|[^A-Za-z0-9_./-])(${names})#${num})([^0-9]|$)"
cards="" before="" pages=0 cutoff=$(gate_cutoff) readback=""
while :; do
  pages=$((pages + 1))
  board_page "$pages" "$before"
  page=$TG_OUT
  STEP="reading board page $pages"
  n=$(jq length <<<"$page") || decide deny "can't read the Trello board"
  cards+=$(jq -r --arg p "$pattern" '.[] | select((.data.text | split("\n")[0]) | test($p)) | .data.card.id' <<<"$page")$'\n'
  [ "$n" -lt "$PAGE" ] && break   # the whole board has been read
  last=$(jq -r '.[-1].date // ""' <<<"$page")
  before=$(jq -r '.[-1].id' <<<"$page")
  readback=${last%%T*}
  # Past the window: stop when a card was found; else read on, up to 35 s in all.
  if [ -n "$last" ] && [[ "$last" < "$cutoff" ]]; then
    [ -n "$(grep -v '^$' <<<"$cards")" ] && break
    [ $((SECONDS - T0)) -ge 35 ] && break
  fi
done
cards=$(grep -v '^$' <<<"$cards" | sort -u)
[ -n "$cards" ] || decide deny "NO PR CARD (read back to ${readback:-the start of the board}): no Trello card has a comment starting with PR: that names $pr_url (or $ref)"

# A comment's first line names this PR at this head: "<PHRASE> <repo>#<n> @ <7 to 40 hex>".
names_head() { # names_head <phrase> <first line>
  local re="^$1 (${ref//./\\.}|${alt//./\\.}#${num}) @ ([0-9a-f]{7,40})([^0-9a-f]|\$)"
  [[ "$2" =~ $re ]] && [[ "$match" == "${BASH_REMATCH[2]}"* ]]
}

# 3. Every [AGENTS] card naming the PR has a VERIFIED: for this head that no
# newer VERIFY FAILED: for the same PR and head follows. The card's comments are
# sorted newest first by their action date (not by the order the API returns
# them), and the NEWEST comment naming this PR at this head under either phrase
# decides; a date tie counts as VERIFY FAILED:, a comment with no date fails
# closed. A VERIFY FAILED: for another PR or an older head decides nothing, and a
# later VERIFIED: for the same head allows again. An [AGENTS] card's name starts
# with [AGENTS], or with 🚨 or 🪲 and then [AGENTS] (rules.md, Card titles and
# labels; board-wait.py uses the same rule).
agents_re='^((🚨|🪲)[[:space:]]*)?\[AGENTS\]'
# The carry check's patterns (3b): this PR under either mobile repo name.
pr_re="(${ref//./\\.}|${alt//./\\.}#${num})"
verdict_re="^(VERIFIED|VERIFY FAILED): $pr_re @ ([0-9a-f]{7,40})([^0-9a-f]|\$)"
sendback_re='^(VERIFY FAILED|CHECK FAILED|CHANGES REQUESTED|REVERTED):'
resolved_re="^(CONFLICT RESOLVED|REFRESHED): $pr_re([^0-9]|\$)"
for card in $cards; do
  trello_get "card $card" "can't read Trello card $card" "/cards/$card" --data-urlencode fields=name,shortUrl
  info=$TG_OUT
  name=$(jq -r .name <<<"$info"); short=$(jq -r .shortUrl <<<"$info")
  [[ "$name" =~ $agents_re ]] || continue
  trello_get "the comments of card $card" "can't read the comments of Trello card $card" "/cards/$card/actions" \
    --data-urlencode filter=commentCard --data-urlencode limit=1000
  lines=$(jq -r '[.[] | {d: (.date | if type == "string" then . else error("comment with no date") end),
                     t: ((.data.text // "") | split("\n")[0])}]
             | sort_by([.d, (.t | startswith("VERIFY FAILED:"))]) | reverse | .[].t' <<<"$TG_OUT" 2>/dev/null) \
    || decide deny "can't read $short's comments"
  verdict=""
  while IFS= read -r line; do
    if names_head "VERIFIED:" "$line"; then verdict=verified; break; fi
    if names_head "VERIFY FAILED:" "$line"; then verdict=failed; break; fi
  done <<<"$lines"
  [ "$verdict" != failed ] || decide deny "$short (\"$name\") has a VERIFY FAILED: $ref @ ${match:0:7} newer than any VERIFIED: for this head"
  [ "$verdict" = verified ] && continue
  # 3b. No verdict names this head: does an earlier VERIFIED: carry to it (a conflict-only fix)?
  # Scanned newest first on the same date-sorted lines. A card with no VERIFIED: for this PR at all
  # keeps the plain deny.
  any_re="^VERIFIED: $pr_re @ [0-9a-f]{7,40}([^0-9a-f]|\$)"
  any=""
  while IFS= read -r line; do [[ "$line" =~ $any_re ]] && { any=1; break; }; done <<<"$lines"
  [ -n "$any" ] || decide deny "$short (\"$name\") is an [AGENTS] card with no VERIFIED: $ref @ ${match:0:7}"
  from="" why="" resolved=0
  while IFS= read -r line; do
    if [[ "$line" =~ $verdict_re ]]; then
      if [ "${BASH_REMATCH[1]}" = VERIFIED ]; then from=${BASH_REMATCH[3]}
      else why="the newest verdict for $ref is a VERIFY FAILED: at ${BASH_REMATCH[3]:0:7}"; fi
      break
    fi
    if [[ "$line" =~ $sendback_re ]]; then why="a ${BASH_REMATCH[1]}: is newer than the card's newest VERIFIED: for $ref"; break; fi
    if [[ "$line" =~ $resolved_re ]]; then
      case "$line" in
        *"no behavior change"*) resolved=$((resolved+1)) ;;
        *) why="a ${BASH_REMATCH[1]}: for $ref since its VERIFIED: does not say \"no behavior change\""; break ;;
      esac
    fi
  done <<<"$lines"
  if [ -z "$why" ] && [ "$resolved" = 0 ]; then
    why="no CONFLICT RESOLVED: or REFRESHED: for $ref saying \"no behavior change\" is newer than its VERIFIED: at ${from:0:7}"
  fi
  if [ -z "$why" ]; then
    chk_left "the carry check of $ref"
    carry=$("$CARRY" "$ref" "$from" "$match" 2>/dev/null) && continue
    why=${carry:-ERROR: verified-carry.sh printed nothing}
  fi
  decide deny "NOT CARRIED: $ref @ ${match:0:7}: $short (\"$name\") has no VERIFIED: for this head and no earlier one carries to it: $why"
done
decide allow "$policy; every card naming $pr_url is clear"
