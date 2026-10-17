# Sync with runner_city

kourai is built from a copy of runner_city's workflow files while the
RunnerCity board keeps running on its own copy. Every workflow change that
merges into runner_city after the baseline must be ported here before the
switch-over (P9). P9 cannot start while a row below is open.

## Baseline

| Repo | Branch | Commit | Date |
|---|---|---|---|
| RunnerCityOrg/runnercity-app | mobile (`main`) | `913585a3a39730a48d62896f7511ba5fcf8926e7` | 2026-10-17 10:47 -0500 |

The live hooks on disk (`runner_city/.claude/hooks/`, partly untracked)
were read on the same day for `docs/VARIABLES.md`. They are not part of
the commit. The runner_city card that puts them into git (R1) must merge
before they are ported.

Files are copied in from the baseline as each step needs them, with
`git archive 913585a3 .claude/<path>`, never from a working tree. Through
P2, nothing has been copied: the config loader and defaults are new, and
the inventory only reads the baseline.

## What counts as a workflow change

A runner_city mobile PR that touches `.claude/agents/`, `.claude/commands/`,
`.claude/board/` (except `user-setup-changes.md` history), `.claude/bin/`
or `.claude/hooks/`. A settings section the user applies also counts.

## Ports

| runner_city PR | Merged | What it changes | kourai commit or PR | Ported |
|---|---|---|---|---|
| none yet | | | | |
