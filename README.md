# kourai

kourai is a Trello-driven board workflow for Claude Code, packaged as a plugin. A board of
lists drives a fleet of Claude Code agents that take each card from approval through tests,
code review, merge and release, with the user approving what users see.

It was extracted from the RunnerCity board and is private. All rights reserved (see `LICENSE`).

## Install

kourai is installed per project by the user with the installer, not by hand. The installer
adds a per-installation marketplace and enables the plugin from it, which is what this line
does for one project:

```
/plugin install kourai --marketplace shawnlauzon/kourai
```

Do not run it for a project that has an installation: `installer/kourai-install plan`
and `apply` pin the version and register the gates (`docs/UPDATING.md`,
`docs/GETTING-STARTED.md`).

## How it fits together

- **The plugin** (this repo) carries nine board agents, the `/kourai:run-board` command, the
  scripts in `bin/` (on the Bash tool's PATH), the gate hook sources, the core rules and the installer.
  Each release is a git tag, `kourai--v<version>`.
- **One config file per installation**, outside git, holds every value a project may change:
  board and list ids, repos, WIP limits, timeouts, the release gap, the context ceiling,
  models. The plugin ships documented defaults in `config/defaults.toml`; scripts read values
  through `bin/kourai-config` (`docs/CONFIG.md`, `docs/VARIABLES.md`).
- **Two rule files.** `rules/core.md` is the shared rulebook. Each project adds its own rules
  (tests, releasing, test servers, settings) from `rules/project-template.md`. Agents read the
  parts they need by heading: `[core: <heading>]` and `[project: <heading>]`.
- **Project agents** are the roles that know a stack (builders, feature tester, promoter, fraud
  watcher). They live in the project, not the plugin, and use the plugin's scripts by bare name.
- **The installer** turns the pinned version plus the config into what a plugin cannot carry:
  permissions, auto-mode rules and gate hooks with recorded hashes. An update is one reviewable
  step with a one-step rollback (`docs/UPDATING.md`).

## Layout

| Path | What |
|---|---|
| `.claude-plugin/` | `plugin.json` (the plugin) and `marketplace.json` (this repo is its own marketplace) |
| `agents/`, `commands/` | The board agents and `/kourai:run-board` |
| `bin/` | Scripts on the agents' PATH, `kourai-config` and its library, `kourai-hook`, `kourai-project` |
| `hooks/` | Gate sources and `registry.json`; never run from the plugin folder (`docs/UPDATING.md`) |
| `rules/` | `core.md`, `project-template.md`, the phrase manifests |
| `config/` | `defaults.toml` (every variable, documented) and `example.toml` |
| `installer/`, `templates/` | `kourai-install` and the permission and auto-mode templates |
| `adapters/` | The seam for other trackers and hosts (nothing implemented yet; `docs/ADAPTERS.md`) |
| `docs/` | Getting started, walkthrough, how it runs, config, variables, updating, adapters, switch-over, sync |
| `tests/` | Script tests; `tests/run.sh` puts fake network tools first on PATH before any test runs |

## Requirements

- Claude Code 2.1.302 or later (built and checked on 2.1.305).
- Python 3.11 or later (`tomllib`) for `bin/kourai-config`; `bin/kourai-config` finds one on the machine.
- `bash`, `jq`, `git`, `gh`.

## Tests

```bash
tests/run.sh                      # every script test, with fakes first on PATH
tests/scan-ids.sh origin/main     # no real id or path in the diff or the tree
tests/prove-real-agent.sh         # one real claude -p run (calls the model once; not in run.sh)
```

No test touches the network: `tests/run.sh` puts `tests/fakes/` first on `PATH`, where `aws`,
`tailscale`, `ssh`, `curl`, `gh` and the rest fail loudly if called, and fails the run on any
logged call. The installer test runs only against a scratch `CLAUDE_CONFIG_DIR`.

There is no CI workflow: GitHub-hosted runners cost Actions minutes, and kourai has no
self-hosted runner of its own.

## More

`docs/GETTING-STARTED.md` to set up a project, `docs/WALKTHROUGH.md` for a card's life,
`docs/HOW-IT-RUNS.md` for the moving parts, `docs/SWITCH-OVER.md` for moving RunnerCity onto kourai.
`CHANGELOG.md` lists each version.
