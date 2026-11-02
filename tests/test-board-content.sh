#!/usr/bin/env bash
# Tests the board's live content: the cases that read the agent files, commands, skills,
# hooks, scripts and rules.md themselves, so a wording change on main can fail them.
# They used to sit inside the long test-board-scripts.sh, test-board-wait.sh and
# test-usage-cost.sh; each of those now calls this script once, and workflow-checks.sh
# runs it on a PR's head (check `content`).
#
# Usage: tests/test-board-content.sh [<root>]
#   <root> is a plugin folder holding agents, commands, hooks, bin and rules/core.md (default: this
#   plugin). The cases that read the project agents (promoter, the builders, feature-tester) and the
#   project rules live with the project layer. Reads only; no network; under 2 seconds.
#
# One `PASS <case>` line per passing case, one `FAIL <case>: <detail>` line per offending
# item (a grep hit, an uncovered glossary phrase), then `ALL PASSED` or `<n> FAILED`.
# Exits 0 when every case passes, 1 otherwise, 2 for a usage error (no such folder).
set -uo pipefail
export KOURAI_CONFIG=${KOURAI_CONFIG:-$(cd "$(dirname "$0")" && pwd)/fixtures/config.toml}
export KOURAI_BIN=${KOURAI_BIN:-$(cd "$(dirname "$0")/../bin" && pwd)}

here=$(cd "$(dirname "$0")/../bin" && pwd)
root=${1:-$(cd "$here/.." && pwd)}
[ -d "$root/agents" ] || { echo "test-board-content.sh: no agents folder in $root" >&2; exit 2; }
c=$root
rules=$root/rules/core.md

failures=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; failures=$((failures + 1)); }
# fail_lines <case> <lines>: one FAIL line per offending line (empty = pass)
check_empty() {
  local name=$1 lines=$2 l
  if [ -z "$lines" ]; then pass "$name"; return; fi
  while IFS= read -r l; do fail "$name" "$l"; done <<<"$lines"
}

# 1. Nothing posts a comment with curl and trello.env (the user's account): agents, commands,
# skills, hooks and scripts use the Trello MCP; the tests' own fixtures are excluded.
hits=$(grep -rln "actions/comments" "$c/agents" "$c/commands" "$c/hooks" "$c/bin" 2>/dev/null | grep -v "/test-" | sed "s|^$root/||" || true)
check_empty "nothing in agents, commands, skills, hooks or scripts posts to actions/comments" "$hits"

# 2. Every glossary phrase an agent posts starts with a prefix of agent-phrases.txt. Skipped: rows that are
# not comments (a message, a board-wait.sh line, a CI log line, a card name, a report's first line, a
# commit trailer) and the phrases a person may write or the Blocked label code handles: BLOCKED:,
# WAITS FOR:, NEXT FOR YOU:, READY FOR YOU:, UNBLOCKED:, RESOLVED:, USER REPLY, "Next:" (the second part
# of an INVESTIGATED: comment), and CHANGES REQUESTED: (the board watcher posts it, but the user may type
# it on the card too, rules.md, The review policy).
if [ -f "$rules" ] && [ -f "$c/bin/agent-phrases.txt" ]; then
  glossary_py() { python3 -I - "$@" <<'PY'
import re, sys
rules, phr = sys.argv[1], sys.argv[2]
prefixes = tuple(l.rstrip("\n") for l in open(phr) if l.strip() and not l.startswith("#"))
skip = ("Next:", "BLOCKED:", "WAITS FOR:", "NEXT FOR YOU:", "READY FOR YOU:", "UNBLOCKED:", "RESOLVED:", "USER REPLY", "CHANGES REQUESTED:")
text = open(rules).read().split("## Comment glossary", 1)[1]
rows = 0
for line in text.splitlines():
    if not line.startswith("| `"):
        continue
    cells = [c.strip() for c in line.strip().strip("|").split(" | ")]
    first, by = cells[0], cells[1] if len(cells) > 1 else ""
    if re.search(r"\(a message|board-wait\.sh. line|a CI log line|\(a card name\)|a report's first line|a message to|a commit trailer|ci-wait\.sh., exit 6", first + " " + by):
        continue
    for m in re.finditer(r"(?:^\| |` / |, )`([^`]+)`", "| " + first if not first.startswith("|") else first):
        ph = m.group(1)
        if ph.startswith(skip) or not re.match(r"[A-Z]", ph):
            continue
        rows += 1
        if not ph.startswith(prefixes):
            print("not covered: " + ph)
if rows < 40:
    print(f"only {rows} glossary phrases found: the table changed shape")
PY
  }
  miss=$(glossary_py "$rules" "$c/bin/agent-phrases.txt")
  check_empty "every glossary phrase an agent posts starts with a prefix of agent-phrases.txt" "$miss"
else
  fail "glossary coverage" "no rules/core.md or bin/agent-phrases.txt in $root"
fi

# 3. Server skills are read by path from origin/development (the Skill tool does not list them in the
# mobile checkout): every agent line that names one carries the read form for that skill, never the
# server main checkout's own (stale) file. (That the three files exist on origin/development needs the
# server repo and stays in test-board-scripts.sh.)
for n in stripe-plans notification-channels deploy-environments; do
  bad=$(grep -n -- "$n" "$c"/agents/*.md 2>/dev/null | grep -v -- "origin/development:.claude/skills/$n/SKILL.md" | grep -v -- "/.claude/worktrees/.*\.claude/skills/$n/SKILL.md" | sed "s|^$root/||" || true)
  check_empty "every agent line naming $n carries the read form" "$bad"
  bad=$(grep -n -- "example-api/\.claude/skills/$n" "$c"/agents/*.md "$rules" 2>/dev/null | grep -v "/\.claude/worktrees/" | sed "s|^$root/||" || true)
  check_empty "no agent or rules line reads the server main checkout's $n file" "$bad"
done

# 4. promoter.md and rules.md wording the board-wait tests depend on.

# 5. Compaction windows: five agent files have autoCompactWindow of at least 200000, the board watcher
# has 200000, and every agent file with a window (the board watcher aside) is in limits.context_ceiling_roles.
win() { head -12 "$c/agents/$1.md" 2>/dev/null | sed -n 's/^autoCompactWindow: *//p'; }
for f in workflow-builder workflow-verifier merger card-manager; do
  n=$(win $f)
  if [ -n "$n" ] && [ "$n" -ge 200000 ] 2>/dev/null; then pass "compaction: $f has autoCompactWindow of at least 200000"; else fail "compaction: $f has autoCompactWindow of at least 200000" "got '${n:-none}'"; fi
done
if [ "$(win board-watcher)" = 200000 ]; then pass "compaction: the board watcher has autoCompactWindow 200000"; else fail "compaction: the board watcher has autoCompactWindow 200000" "got '$(win board-watcher)'"; fi
ceiling=$("$here/kourai-config" json limits.context_ceiling_roles 2>/dev/null)
for f in "$c"/agents/*.md; do
  b=$(basename "$f" .md); [ "$b" = board-watcher ] && continue
  head -12 "$f" | grep -q "^autoCompactWindow:" || continue
  if grep -q "\"$b\"" <<<"$ceiling"; then pass "context: $b is in limits.context_ceiling_roles"; else fail "context: $b is in limits.context_ceiling_roles" "missing in limits.context_ceiling_roles"; fi
done

# 6. No wording that ranks by raw tokens (cost is model- and token-type-weighted).
if [ -d "$c/agents" ] && [ -d "$c/bin/usage" ]; then
  # grep exits 0 (a hit), 1 (none) or 2 (an error: a bad path); exit 2 fails the case, it is never read as "no hit".
  # RC_CONTENT_RAW_PATHS (a test fixture hook) overrides the folders the case reads.
  # shellcheck disable=SC2086
  raw=$(grep -rniE "rank (and compare )?by raw tokens|raw tokens first" ${RC_CONTENT_RAW_PATHS:-"$c/agents" "$c/bin/usage"} 2>&1 | sed "s|^$root/||"; exit "${PIPESTATUS[0]}")
  gs=$?
  if [ "$gs" = 2 ]; then fail "no ranking-by-raw-tokens wording in agents/ or bin/usage/" "grep failed (exit 2): $raw"
  else check_empty "no ranking-by-raw-tokens wording in agents/ or bin/usage/" "$raw"; fi
else
  fail "no ranking-by-raw-tokens wording" "no agents or bin/usage folder in $root"
fi

# 7. Lost test host (card CSyAbSsC): the release is replaced and retried once, a second loss is held.
need() { # need <case> <file> <fixed text>
  if [ -f "$2" ] && grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1" "$2 does not name: $3"; fi
}
need "rules.md: a manual step is tried with a board tool first" "$rules" "try the board tool that can fix it once first"
need "card-manager.md: shows the first loss" "$c/agents/card-manager.md" "SHOW LOST HOST:"
need "run-board.md: shows the first loss" "$c/commands/run-board.md" "SHOW LOST HOST:"
need "time-optimizer.md: run-time headroom check" "$c/agents/time-optimizer.md" "80%"
need "time-optimizer.md: reads job times with gh run view" "$c/agents/time-optimizer.md" "gh run view <id> --repo <repo> --json jobs"

# Transient failures: show it, retry once, then ask (card egTvjp80)
need "rules.md: the transient-failure section" "$rules" "**A transient failure: show it, retry once, then ask**"
need "rules.md: RETRYING: is open only until a later closing comment" "$rules" "A \`RETRYING:\` is open only while no \`RETRIED:\`"
need "rules.md: RETRYING:, RETRIED:, RESTARTED: and SHOW RETRY: in the glossary" "$rules" "| \`RESTARTED: <agent> on <card>: died"
need "rules.md: the second death in a row compares ids" "$rules" "the dead row's id differs from the id in the newest \`RESTARTED:\`"
need "rules.md: a second death is a BLOCKED question" "$rules" "died twice in a row on <card>"
need "rules.md: no promoter start while the status card is Blocked" "$rules" "No promoter start while the release status card is Blocked"
need "rules.md: Blocked means the newest WAITS FOR: has no later UNBLOCKED:" "$rules" "status card's newest \`WAITS FOR:\` has no \`UNBLOCKED:\` or \`RESOLVED:\` after it"
need "rules.md: unavailable means failed twice" "$rules" "the same call failed twice, about 10 seconds apart"
need "board-watcher.md: counts dead agents by id" "$c/agents/board-watcher.md" "the same death"
need "board-watcher.md: second death is a BLOCKED question" "$c/agents/board-watcher.md" "died twice in a row on <card>"
need "board-watcher.md: no promoter start while the status card is Blocked" "$c/agents/board-watcher.md" "no promoter start of any kind"
need "board-watcher.md: Blocked means the newest WAITS FOR: has no later UNBLOCKED:" "$c/agents/board-watcher.md" "its newest \`WAITS FOR:\` has no \`UNBLOCKED:\` or \`RESOLVED:\` after it"
need "board-watcher.md: the merger is not counted" "$c/agents/board-watcher.md" "The merger is not counted"
need "board-watcher.md: idle status card created before the promoter start" "$c/agents/board-watcher.md" "before you start a promoter when none exists"
need "card-manager.md: counts its dead children" "$c/agents/card-manager.md" "RESTARTED: <agent> on <card>: died"
need "card-manager.md: a feature tester transient" "$c/agents/card-manager.md" "ends \`transient:"
need "merger.md: one retry of a 5xx merge" "$c/agents/merger.md" "SHOW RETRY: merge of"
need "run-board.md: shows SHOW RETRY:" "$c/commands/run-board.md" "SHOW RETRY:"
need "board-watcher.md: the weekly drift check without a card has its own restart rule" "$c/agents/board-watcher.md" "The weekly drift check has no card"
need "board-watcher.md: the drift restart prompt searches PROPOSED first" "$c/agents/board-watcher.md" "Search PROPOSED for cards filed since the first run started before you file any"
need "run-board.md: shows the card-less SHOW BLOCKED: weekly drift check" "$c/commands/run-board.md" "SHOW BLOCKED: weekly drift check:"

if [ "$failures" -eq 0 ]; then echo "ALL PASSED"; exit 0; fi
echo "$failures FAILED"; exit 1
