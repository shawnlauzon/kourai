#!/usr/bin/env bash
# Whether each open PR of a card is ready to move on, in one line per PR, for
# the card manager (instead of a gh pr view, a gh pr checks and a policy check
# per PR).
#
# Usage: pr-ready.sh <shortLink>
#
# For each open **PR:** line of the card's description (closed, replaced,
# reverted or included ones left out), prints:
#   <owner/repo>#<n> | head <sha> | <state> | CI: <GREEN | RED a, b | RUNNING a; RED b | NO CHECKS | ERROR>
#     | <MERGEABLE | CONFLICTING | UNKNOWN> | feature test: <yes | missing | placeholder>
#     | App-visible: <yes | no | missing> | <the review policy's verdict>
# "placeholder" means a builder's "Behavior tests: …" or "pending" line is still
# in the body; App-visible is the PR body's `App-visible:` line (mobile and server PRs alike). The verdict is the first word
# group of review-policy.sh check (NO REVIEW NEEDED, APPROVED, REVIEW NEEDED, ERROR).
# CI: NO CHECKS only when gh says "no checks reported"; any other gh pr checks
# failure is CI: ERROR (its message on stderr): read it again later.
# Exit 0; 1 when the Trello read or a gh pr view fails; 2 usage. Reads only.
# Test overrides: TRELLO_ENV_FILE, TRELLO_API_BASE, REVIEW_POLICY.
set -u -o pipefail
. "$(dirname "${BASH_SOURCE[0]}")/kourai-env.sh"
env_file=${TRELLO_ENV_FILE:-$(kc paths.trello_env)}
api=${TRELLO_API_BASE:-https://api.trello.com/1}
policy=${REVIEW_POLICY:-}
short=${1:-}
[[ "$short" =~ ^[A-Za-z0-9]{8}$ ]] || { echo "usage: pr-ready.sh <shortLink>" >&2; exit 2; }
set -a
# shellcheck disable=SC1090 # the env file is the caller's (default: paths.trello_env in the config)
. "$env_file"
set +a

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
curl -sf -o "$tmp/card" "$api/cards/$short?fields=desc&key=$TRELLO_KEY&token=$TRELLO_TOKEN" \
  || { echo "pr-ready: Trello request failed" >&2; exit 1; }

prs=$(python3 -I - "$tmp/card" <<'PY'
import json, re, sys
for line in json.load(open(sys.argv[1])).get("desc", "").splitlines():
    m = re.match(r"\*\*PR:\*\*\s+([\w.-]+/[\w.-]+)#(\d+)", line)
    if m and not re.search(r"\(closed|replaced by|\(reverted by|\(included in", line):
        print(m.group(1), m.group(2))
PY
) || exit 1

[ -n "$prs" ] || { echo "no open PRs"; exit 0; }
while read -r repo n; do
  gh pr view "$n" --repo "$repo" --json state,headRefOid,mergeable,body >"$tmp/pr" 2>/dev/null \
    || { echo "pr-ready: gh pr view $repo#$n failed" >&2; exit 1; }
  # gh pr checks exits non-zero while checks fail or are pending, and when there
  # are none: the JSON, or its "no checks reported" message, is the answer.
  gh pr checks "$n" --repo "$repo" --json name,bucket >"$tmp/checks" 2>"$tmp/checks.err"
  if grep -qi 'no checks reported' "$tmp/checks.err"; then
    ci_none=true
  else
    ci_none=false
  fi
  # The policy exits 1 for REVIEW NEEDED and 2 for ERROR: its line is the answer.
  if [ -n "$policy" ]; then verdict=$("$policy" check "$repo#$n" 2>/dev/null | head -n 1) || true
  else verdict=$(kourai-hook review-policy.sh check "$repo#$n" 2>/dev/null | head -n 1) || true; fi
  python3 -I - "$repo" "$n" "$tmp/pr" "$tmp/checks" "${verdict:-ERROR: no answer}" "$ci_none" "$tmp/checks.err" <<'PY'
import json, re, sys
repo, n, pr_file, checks_file, verdict, none, err_file = sys.argv[1:]
pr = json.load(open(pr_file))
try:
    checks = json.load(open(checks_file))
except ValueError:
    checks = None   # no JSON: gh failed, or there are no checks (decided below)
def names(*buckets): return ", ".join(c["name"] for c in checks if c["bucket"] in buckets)
if checks:
    parts = []
    if names("pending"): parts.append("RUNNING " + names("pending"))
    if names("fail", "cancel"): parts.append("RED " + names("fail", "cancel"))
    ci = "; ".join(parts) or "GREEN"
elif none == "true":
    ci = "NO CHECKS"
else:
    ci = "ERROR"
    err = " ".join(open(err_file).read().split())[:200] or "no output"
    print(f"pr-ready: gh pr checks {repo}#{n} failed: {err}", file=sys.stderr)
body = pr.get("body") or ""
if re.search(r"^Behavior tests: the feature tester's|pending \(feature-tester\)", body, re.M):
    ft = "placeholder"
elif re.search(r"^## Feature test", body, re.M):
    ft = "yes"
else:
    ft = "missing"
m = re.search(r"^App-visible:\s*(yes|no)\b", body, re.M | re.I)
av = m.group(1).lower() if m else "missing"
print(f"{repo}#{n} | head {pr['headRefOid']} | {pr['state']} | CI: {ci} | {pr.get('mergeable') or 'UNKNOWN'}"
      f" | feature test: {ft} | App-visible: {av} | {verdict.split(':')[0]}")
PY
done <<<"$prs"
