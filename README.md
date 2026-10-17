# kourai

kourai is the RunnerCity board workflow, extracted into a reusable Claude Code
plugin: a Trello board drives a fleet of Claude Code agents that take each card
from approval through BEFORE/AFTER tests, review, merge and release.

Private. All rights reserved (see `LICENSE`).

## Status

Under construction, off the RunnerCity board's critical path. The plan is the
Claude Doc "Extracting the Board Workflow" (steps P1 to P10). Done so far:

| Step | What | State |
|---|---|---|
| P1 | This repo, its layout, the plugin and marketplace manifests | done |
| P2 | One config file per installation: defaults, loader, inventory | loader and defaults done; scripts move onto it as they are copied in |
| P7 | Installer, update and rollback | designed in `docs/UPDATING.md`, not built |

Nothing here is installed anywhere yet. RunnerCity still runs its own copy
under `runner_city/.claude/`; `docs/SYNC.md` records the baseline commit and
every workflow change that must be ported before the switch-over (P9).

## How it fits together

- **The plugin** (this repo) carries the agents, the `run-board` command, the
  scripts in `bin/` (on the Bash tool's PATH), the gate hook sources, the core
  rules and the installer. Each release is a git tag, `kourai--v<version>`.
- **One config file per installation**, outside git, holds every value a
  project may change: board and list ids, repos, WIP limits, timeouts, the
  release gap, the context ceiling, models. The plugin ships documented
  defaults in `config/defaults.toml`; scripts read values through
  `bin/kourai-config`. See `docs/CONFIG.md`.
- **The installer** (P7) turns the pinned plugin version plus the config into
  what a plugin cannot carry: permissions, auto-mode rules, hook registrations
  with recorded hashes. Updating is one reviewable step with one-step rollback.
  See `docs/UPDATING.md`.

## Layout

| Path | What |
|---|---|
| `.claude-plugin/` | `plugin.json` (the plugin) and `marketplace.json` (this repo is its own marketplace) |
| `agents/`, `commands/` | The board agents and `/kourai:run-board` (copied in from P3 on) |
| `bin/` | Scripts on the agents' PATH; today `kourai-config` and its library |
| `hooks/` | Gate sources; never registered from the plugin folder (see `docs/UPDATING.md`) |
| `rules/` | The core rulebook (P4) |
| `config/defaults.toml` | Every workflow variable with its default and what it does |
| `config/example.toml` | A starting point for an installation's config |
| `installer/` | `kourai-install` (P7) |
| `adapters/` | The adapter interface and reference adapters (P5) |
| `docs/` | `CONFIG.md`, `VARIABLES.md` (the inventory), `UPDATING.md`, `SYNC.md` |
| `tests/` | Script tests; `tests/run.sh` puts fake network tools first on PATH before any test runs |

## Requirements

- Claude Code 2.1.302 or later.
- Python 3.11 or later (`tomllib`) for `bin/kourai-config`.
- `bash`, `jq`, `git`, `gh`.

## Tests

```bash
tests/run.sh
```

No test touches the network: `tests/run.sh` first puts `tests/fakes/` at the
front of `PATH`, where `aws`, `tailscale`, `ssh`, `curl`, `gh` and the rest
fail loudly if called.

There is no CI workflow yet: GitHub-hosted runners cost Actions minutes, and
kourai has no self-hosted runner of its own (an open question in
`docs/UPDATING.md`).
