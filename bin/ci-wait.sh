#!/usr/bin/env bash
# Waits for GitHub checks, and ends on its own within the wait limit (rules.md,
# Waiting), so an agent's foreground wait never runs past it.
#
# Usage:
#   ci-wait.sh pr <owner/repo> <n>     a PR's checks
#   ci-wait.sh run <owner/repo> <id>   one workflow run
#
# pr prints one verdict line:
#   CI: GREEN                    every check passed (or was skipped)     exit 0
#   CI: RED <check>, <check>     a check failed or was cancelled         exit 1
#   CI: RUNNING <check>, …       still pending at the limit: call again  exit 3
#   CI: NO CHECKS                none reported after a while (rules.md,
#                                "CI is green", says when that counts)  exit 4
#   CI: STUCK <step>. Tried: <tried>   a queued job sat stuck while the test
#                                hosts had room and ci-unstick.sh could not
#                                (or may not) free it: the step is for the
#                                caller to put on a card as WAITS FOR:   exit 6
#   PAUSED                       the PR's card (from its card/<shortLink>-
#                                branch) has a pause file                exit 5
#   CI: ERROR gh: <what>         gh kept failing until the limit         exit 2
# run prints RUN: SUCCESS (0), RUN: FAILURE <failed jobs> (1), RUN: RUNNING
# (3) or RUN: STUCK <step>. Tried: <tried> (6); once the run has ended it also prints the run's last `VERDICT:` line (the
# API workflow's, printed as its step's last line), or `VERDICT: (none)`.
# Exit 2: usage, or gh failed (pr: `CI: ERROR …`).
#
# ci-unstick.sh's per-run state (RC_CI_UNSTICK_DIR) is read here: while it has
# cancelled a stuck run and not re-run it (or re-ran it under 3 minutes ago) a
# red or cancelled result reads RUNNING; state `failed` plus a still-pending
# result is the STUCK line (exit 6); a `failed` run that later completes gives
# the normal GREEN or RED. A closed PR is never re-run (ci-unstick.sh).
#
# Settings (tests): CI_WAIT_LIMIT (seconds, default 270), CI_WAIT_POLL (default
# 20), CI_WAIT_NO_CHECKS_AFTER (default 120), CI_RERUN_GRACE (default 180),
# RC_CI_UNSTICK_DIR, RC_PAUSE_DIR.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/kourai-env.sh"

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=pause-lib.sh source-path=SCRIPTDIR
. "$here/pause-lib.sh"

usage() { echo "usage: ci-wait.sh pr <owner/repo> <n> | run <owner/repo> <run id>" >&2; exit 2; }
[ $# -eq 3 ] || usage
mode=$1 repo=$2 id=$3
[[ "$repo" == */* ]] && [[ "$id" =~ ^[0-9]+$ ]] || usage

limit=${CI_WAIT_LIMIT:-270} poll=${CI_WAIT_POLL:-20}
tmp_err=$(mktemp) || exit 2
trap 'rm -f "$tmp_err"' EXIT
start=$SECONDS
unstick_dir=${RC_CI_UNSTICK_DIR:-$(kc paths.ci_unstick_dir)}
project_bin=${RC_PROJECT_BIN:-$(kc paths.project_bin)}
# st_file: the ci-unstick.sh state file of this wait (a PR's run, or the run id), or nothing.
st_file() {
  if [ "$mode" = run ]; then
    f="$unstick_dir/${repo//\//_}-$id.state"; [ -f "$f" ] && echo "$f"
  else
    # ci-unstick.sh is the project layer's own script (paths.project_bin); a project without it has no state.
    [ -x "$project_bin/ci-unstick.sh" ] || return 0
    RC_CI_UNSTICK_DIR="$unstick_dir" bash "$project_bin/ci-unstick.sh" state-of-pr "$repo" "$id" "$pr_sha" 2>/dev/null
  fi
}
st_get() { sed -n "s/^$2=//p" "$1" | head -1; }
# unstick_mask <verdict word>: sets stuck_line (exit 6) or masked=1 (read RUNNING).
stuck_line="" masked=0
unstick_mask() {
  stuck_line="" masked=0
  local f state now at
  # The PR's head is read once per call, here (st_file runs in a subshell, so it cannot keep it).
  if [ "$mode" = pr ] && [ -z "${pr_sha+x}" ]; then pr_sha=$(gh pr view "$id" --repo "$repo" --json headRefOid -q .headRefOid 2>/dev/null) || pr_sha=""; fi
  f=$(st_file); [ -n "$f" ] || return 0
  state=$(st_get "$f" state); now=$(date +%s)
  case "$state" in
    cancelled) [ "$1" != GREEN ] && masked=1 ;;
    rerun) at=$(st_get "$f" rerun_at); [ "$1" != GREEN ] && [ $((now - ${at:-0})) -lt "${CI_RERUN_GRACE:-180}" ] && masked=1 ;;
    failed) [ "$1" = RUNNING ] && stuck_line="STUCK $(st_get "$f" step). Tried: $(st_get "$f" tried)" ;;
  esac
  return 0
}
elapsed() { echo $((SECONDS - start)); }
# Sleep the poll, or the time left to the limit when that is shorter (floor 1 s), so the
# last read happens at the limit and a slice ends inside the 5-minute prompt cache.
nap() { local left=$((limit - SECONDS + start)); [ "$left" -lt 1 ] && left=1; [ "$left" -gt "$poll" ] && left=$poll; sleep "$left"; }

case "$mode" in
  pr)
    branch="" card="" gh_err=""
    while :; do
      if [ -z "$branch" ]; then
        branch=$(gh pr view "$id" --repo "$repo" --json headRefName -q .headRefName 2>"$tmp_err") || { branch=""; gh_err=$(head -c 200 "$tmp_err"); }
        if [[ "$branch" =~ ^card/([A-Za-z0-9]{8})- ]]; then card=${BASH_REMATCH[1]}; fi
      fi
      if rc_paused "$card"; then echo PAUSED; exit 5; fi
      # gh pr checks exits non-zero while checks fail or are pending, and when
      # there are none: the JSON, or its "no checks reported" message, is the answer.
      json=$(gh pr checks "$id" --repo "$repo" --json name,bucket 2>"$tmp_err")
      gh_rc=$? none=false
      if grep -qi 'no checks reported' "$tmp_err"; then none=true; elif [ -z "$json" ] && [ "$gh_rc" != 0 ]; then gh_err=$(head -c 200 "$tmp_err"); fi
      if [ -n "$branch" ] && [ -n "$json" ] && [ "$json" != "[]" ]; then
        gh_err=""
        verdict=$(printf '%s' "$json" | python3 -I -c '
import json, sys
checks = json.load(sys.stdin)
names = lambda b: ", ".join(c["name"] for c in checks if c["bucket"] in b)
if any(c["bucket"] == "pending" for c in checks):
    print("RUNNING " + names({"pending"}))
elif any(c["bucket"] in ("fail", "cancel") for c in checks):
    print("RED " + names({"fail", "cancel"}))
else:
    print("GREEN")')
        unstick_mask "${verdict%% *}"
        if [ "$masked" = 1 ]; then verdict="RUNNING (a stuck job is being re-run)"; fi
        if [ -n "$stuck_line" ]; then echo "CI: $stuck_line"; exit 6; fi
        case "$verdict" in
          GREEN) echo "CI: GREEN"; exit 0 ;;
          RED*) echo "CI: $verdict"; exit 1 ;;
        esac
      elif [ "$none" = true ] && [ -n "$branch" ] && [ "$(elapsed)" -ge "${CI_WAIT_NO_CHECKS_AFTER:-120}" ]; then
        echo "CI: NO CHECKS"; exit 4
      fi
      if [ "$(elapsed)" -ge "$limit" ]; then
        if [ -n "$gh_err" ]; then echo "CI: ERROR gh: $(printf '%s' "$gh_err" | tr '\n' ' ')"; exit 2; fi
        echo "CI: ${verdict:-RUNNING}"; exit 3
      fi
      nap
    done
    ;;
  run)
    while :; do
      json=$(gh run view "$id" --repo "$repo" --json status,conclusion,jobs 2>/dev/null) || { echo "gh run view $id failed" >&2; exit 2; }
      line=$(printf '%s' "$json" | python3 -I -c '
import json, sys
r = json.load(sys.stdin)
if r["status"] != "completed":
    print("RUNNING")
elif r["conclusion"] == "success":
    print("SUCCESS")
else:
    failed = [j["name"] for j in r.get("jobs", []) if j.get("conclusion") not in ("success", "skipped")]
    print("FAILURE " + ", ".join(failed or [r["conclusion"] or "unknown"]))')
      unstick_mask "${line%% *}"
      if [ -n "$stuck_line" ]; then echo "RUN: $stuck_line"; exit 6; fi
      if [ "$masked" = 1 ]; then line=RUNNING; fi
      if [ "$line" != RUNNING ]; then
        echo "RUN: $line"
        # The log can lag the run's end by a few seconds: try it a few times.
        # Its lines are `<job>\t<step>\t<timestamp> <text>` (the first after a
        # BOM): the verdict is the last text that starts `VERDICT: `. The step's
        # script, echoed indented before it runs, never matches; no line is (none).
        v=""
        for _ in 1 2 3; do
          if log=$(gh run view "$id" --repo "$repo" --log 2>/dev/null); then
            v=$(printf '%s\n' "$log" | awk -F'\t' '{ t=$3; sub(/^\xef\xbb\xbf/, "", t); sub(/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z /, "", t); if (t ~ /^VERDICT: /) v=t } END { if (v != "") print v }')
            break
          fi
          sleep "$poll"
        done
        echo "${v:-VERDICT: (none)}"
        [ "$line" = SUCCESS ] && exit 0 || exit 1
      fi
      if [ "$(elapsed)" -ge "$limit" ]; then echo "RUN: RUNNING"; exit 3; fi
      nap
    done
    ;;
  *) usage ;;
esac
