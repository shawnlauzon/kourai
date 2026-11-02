# How it runs

The moving parts, who starts whom, and where state lives.

## Who starts whom

You run `/kourai:run-board` in a Claude Code session (the main session). It starts the **board
watcher** in the background and relays what it says. The board watcher owns every card in every
list. It starts a **card manager** per card in BUILDING or TESTING, the **merger**, the **workflow
verifier**, the periodic checkers (code reviewer, time optimizer, token auditor, Sentry triager)
and, through the card manager, the project's builders and testers. The main session alone starts
the **workflow builder**, because it changes the watcher's own rules.

A plugin agent is started as `kourai:<name>`; a project agent by its bare name. The `[agents]`
table in the config is the one list; `tests/test-start-names.sh` checks every start phrase in the
agent files against it.

## The waiting loop

The board watcher waits in `board-wait.sh` (`bin/board-wait.py`). It polls Trello and GitHub on a
fast check and a slower one, reloads the config on every poll, and wakes the watcher with one line
per event (a move, a new comment, a PR state change, a dead agent). The slow check also
fast-forwards the project's main checkout, so the installed gates and scripts equal what merged.

## Liveness comes from transcripts

`agent-state.sh` and `agents-status.sh` read each agent's own transcript to say whether it is
running, waiting, finished or stuck. They accept both `kourai:card-manager` and `card-manager` as
the agent type. One owner per card: an agent runs `agent-state.sh --owner` first and stands down
if an older copy holds the card.

## Gates

Three hooks guard what agents cannot be trusted with: `merge-gate` (a merge needs its checks),
`staging-gate` (a deploy needs a recorded green full suite) and `merged-comment-gate` (a `MERGED:`
comment needs a merged PR). They are registered by the installer by absolute path with
`KOURAI_BIN` and `KOURAI_CONFIG` in the command, run from a hash-checked copy under
`<state_dir>/kourai/hooks/<version>/`, and fail closed. `review-policy.sh` is a helper the gates
and the watcher call.

## Where state lives

| What | Where |
|---|---|
| Config | `<state_dir>/kourai.toml` |
| Installed releases, hooks, plans, backups | `<state_dir>/kourai/` |
| Agent run folders and logs | under `<state_dir>` as the core rules say |
| Secrets (Trello env, the App key) | `<state_dir>`, never git |
| Cards, comments | Trello |
| Code, PRs | the project's repos |

## Project layer

The project's repo holds its own rules file, its stack agents, its stack scripts (reached with
`kourai-project <script>`), and its decisions. kourai never reads another project's files.
