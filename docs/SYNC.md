# Sync with runner_city

kourai is built from a copy of runner_city's workflow files while the
RunnerCity board keeps running on its own copy. Every workflow change that
merges into runner_city after the baseline must be ported here before the
switch-over (`docs/SWITCH-OVER.md`). The switch-over cannot start while a row below is open.

## Baseline

| Repo | Branch | Commit | Date |
|---|---|---|---|
| RunnerCityOrg/runnercity-app | mobile (`main`) | `22fe69b554009078de6f7ff2a27bb64e734fa672` | 2026-11-01 23:08 -0600 |

The four gate hooks were compared by hash with the live ones on disk
(`docs/PORT-TABLE.md` lists them; the comparison is in the PR body). The files
are copied from the baseline with `git archive 22fe69b5 .claude/<path>`, never
from a working tree, and swept so that every id, path and repo name reads from
config (`tests/scan-ids.sh` keeps it so).

## What counts as a workflow change

A runner_city mobile PR that touches `.claude/agents/`, `.claude/commands/`,
`.claude/board/` (except `user-setup-changes.md` history), `.claude/bin/`
or `.claude/hooks/`. A settings section the user applies also counts.

## Ports

| runner_city PR | Merged | What it changes | kourai commit or PR | Ported |
|---|---|---|---|---|
| RunnerCityOrg/runnercity-app#493 (`d30865c3`, with `26ada1a7`, `0c1087ad`, `7c757355`) | 2026-11-02 | Sentry triage code freeze rule, ignore parameters, 404 prefix lookup, `SERIOUS:` relay by the board watcher and the run-board command | `agents/sentry-triager.md`, `agents/board-watcher.md`, `commands/run-board.md` in the K9 commit of this PR (its number is on the card) | yes |
| Rows after 22fe69b5 up to `d30865c3` | | `.claude/board/WORKFLOW.md` (4 lines) and `decisions/2026-11-02-XrBUW2w0.md` stay in RunnerCity (no kourai file) | not ported by design | n/a |
