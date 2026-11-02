# Getting started with a new project

This sets up one installation of kourai for one project. Plan about an hour; the Trello board
and the GitHub App are the slow parts. Nothing here touches another project's installation.

## 1. What you need

- A Trello board with the lists in `rules/core.md` ("The board"): PROPOSED, BUG REPORTS, TODO,
  WORKFLOW, QUESTIONS, BUILDING, TESTING, REVIEW, MERGING, MERGED, RELEASING, VERIFY, DONE.
  Find the list ids with `trelloReadList` action `list_by_board`; the labels the workflow uses
  are listed in `config/defaults.toml` under `[board.labels]`.
- A Trello account for the agents (a member separate from you) and the Trello MCP connected.
- A GitHub App the agents act as, with its private key file on disk (outside git), so every
  push, PR and comment is made through `as-claude.sh` and never as you.
- Claude Code 2.1.302 or later, Python 3.11 or later, `bash`, `jq`, `git`, `gh`.
- The project's repos checked out locally.

## 2. Write the config

Copy `config/example.toml` to `<state_dir>/kourai.toml` (outside git; `state_dir` is any folder
for logs, locks and secrets) and fill it in. Set only what differs from `config/defaults.toml`.
`docs/CONFIG.md` explains the format and `docs/VARIABLES.md` lists every key. Check it:

```
KOURAI_CONFIG=<state_dir>/kourai.toml bin/kourai-config check
```

It prints `CONFIG OK` or each problem. The `[agents]` table must list your project's own agents
(`project = [...]`) so a start by bare name is recognised; plugin agents start as `kourai:<name>`.

## 3. Write the project rules

Copy `rules/project-template.md` into your repo (RunnerCity keeps it at `.claude/board/rules.md`)
and fill in the four headings the template keeps: Project settings, Tests, Releasing, Test servers.
Set `project.rules_file` in the config to its path. Check the headings:

```
RULES_PROJECT=<your rules file> AGENTS_DIR=<your agents folder> bin/rules-ranges.sh check
```

## 4. Add your project agents

The plugin ships the roles that do not know a stack. Add the roles that do to the repo's
`.claude/agents/`: at least a builder for each repo (it opens PRs), usually a feature tester for
cards that change what users see, a promoter if you release. Name the rules parts they read in
`[core: <heading>]` and `[project: <heading>]` markers, call plugin scripts by bare name, and
call your own scripts through `kourai-project <script>` (it reads `paths.project_bin`).

## 5. Install

```
installer/kourai-install --config <state_dir>/kourai.toml plan
```

Read the plan file it writes. When it looks right, with the board stopped:

```
installer/kourai-install --config <state_dir>/kourai.toml apply
installer/kourai-install --config <state_dir>/kourai.toml check
installer/kourai-install --config <state_dir>/kourai.toml prove
```

`docs/UPDATING.md` explains each step and the one-command `rollback`.

## 6. Run it

Start a new Claude Code session in the project and run `/kourai:run-board`. It starts the board
watcher and does nothing else itself. Put a small card in TODO and watch it go through
(`docs/WALKTHROUGH.md`). The first run should be attended.

## What goes wrong first

- `CONFIG INVALID`: the message names the key.
- `GATE DRIFT`: an installed gate no longer matches its recorded hash; run `check`, then re-apply.
- An agent not found: its name is missing from the `[agents]` table, or a plugin agent was started
  by bare name (it must be `kourai:<name>`).
