# Sync with runner_city

kourai is built from a copy of runner_city's workflow files while the
RunnerCity board keeps running on its own copy. Every workflow change that
merges into runner_city after the baseline must be ported here before the
switch-over (P9). P9 cannot start while a row below is open.

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
| none yet | | | | |
