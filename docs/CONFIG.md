# The installation config

Each installation has one config file, outside git, holding every workflow
value it changes. Everything it leaves out comes from the plugin's
documented defaults (`config/defaults.toml`). Changing a value never needs
a code change: scripts read it on every call.

## Where it lives

`<state_dir>/kourai.toml`, next to the installation's state and secrets.

| Installation | Config file |
|---|---|
| RunnerCity | `~/Development/runner_city_files/kourai.toml` |
| livecorrectly-site (pilot) | `~/Development/livecorrectly_files/kourai.toml` (proposed) |

It stays out of git on purpose (the user's decision, 2026-10-17): the
values are per machine and per installation, and some are paths to secrets.
The plugin's `.gitignore` also ignores any `kourai.toml`, so one can never be
committed here by mistake.

## How scripts find it

1. `--config <file>` on the command line, if given.
2. Otherwise `$KOURAI_CONFIG`. The installer (P7) sets it in the project's
   `.claude/settings.local.json` `env`, so every Bash command an agent runs
   in that project has it.
3. Otherwise there is no config: `kourai-config` prints `NO CONFIG` and
   exits 3. No script guesses a path.

Hooks get the path written into their registration by the installer, so a
gate never depends on the environment it happens to run in.

## Format: TOML

TOML rather than YAML, because:

- Python 3.11+ reads it with the standard library (`tomllib`); YAML needs
  PyYAML, which is not installed on this Mac, and the hooks must not depend
  on a pip install.
- It has comments, unlike JSON.
- Its types are explicit: `7Tch9xIX`, `0123` or `no` stay strings when
  quoted, where YAML would turn some of them into numbers or booleans.

Top-level keys (only `repos`) must come before the first `[table]`.

## Reading values

```bash
kourai-config check                         # CONFIG OK: <file>, or CONFIG INVALID: <file> and each problem
kourai-config get limits.card_test_servers  # 3
kourai-config get repos.0.base              # development (arrays index by number)
kourai-config get board.lists.merging       # a table prints as JSON
kourai-config json                          # the whole merged config
kourai-config shell limits                  # KOURAI_LIMITS_CARD_TEST_SERVERS=3 ... quoted for eval
kourai-config path                          # the config in use
kourai-config defaults                      # the defaults file in use
```

Exit codes: 0 ok, 1 invalid config, 2 usage or unknown key, 3 no config, 4
Python older than 3.11.

Python scripts import it directly:

```python
import kourai_config
cfg = kourai_config.load()          # raises kourai_config.ConfigError
gap = kourai_config.get(cfg, "release.gap_hours")
```

A long-running script (`board-wait.py`) calls `load()` again on each poll,
so an edit to the config applies at the next poll with no restart (the
"reload without a restart" idea from Symphony's workflow file).

## What check enforces

- **No unknown keys.** A key not in the defaults is an error, so a typo
  never falls back to a default silently. `models` and `adapters` are open:
  a project may add its own agents and adapter settings there.
- **Types match the default:** string, integer, float (integers accepted),
  boolean, array (each element typed like the default's first), table.
- **Required keys are set:** the board, its two members, the GitHub login
  and App, and each repo's `id`, `slug`, `path` and `base`.
- **References resolve:** `{project.state_dir}/trello.env` must name a key
  that exists and holds a string or number. A leading `~/` is the home folder.

## Writing one

Start from `config/example.toml`: copy it to `<state_dir>/kourai.toml` and
set only what differs from the defaults. `docs/VARIABLES.md` lists every
key, its default, RunnerCity's value and where it was hard-coded.

## Moving the scripts onto it (the rest of P2)

As each RunnerCity script is copied into `bin/`, its constants become
config reads. The env overrides scripts already accept (`RC_CARD_TEST_SERVERS`,
`BOARD_WAIT_POLL`, `RELEASE_GAP_HOURS` and the others listed in
`docs/VARIABLES.md`) keep working for tests, and win over the config when set.
P2 is done when no 24-character id, board link or `/Users/shawn` path is
left outside a config file, and the tests pass with a fake config.
