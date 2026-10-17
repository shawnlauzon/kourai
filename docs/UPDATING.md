# Installing, updating and rolling back (P7 design)

An update is one reviewable step and a rollback is one command. The user
changes one line, `install.version`, in the installation's config. Then
`kourai-install plan` writes a single review file showing everything that
will change. `kourai-install apply` makes exactly those changes, after
backing up each file it touches. `kourai-install rollback` puts every one of
those files back and switches to the previous release, with no network.

Status: design only. Nothing here is built yet. Two facts are still to be
checked before building; they are marked **(verify)**.

## What an installation is made of

| Piece | Where | Written by | Changes on update |
|---|---|---|---|
| Config | `<state_dir>/kourai.toml` | the user | only `install.version`, plus any new keys the plan asks for |
| Release checkouts | `<state_dir>/kourai/releases/<version>/` | installer | a new folder is added; old ones stay for rollback |
| Local marketplace | `<state_dir>/kourai/.claude-plugin/marketplace.json` | installer | its one entry points at the active release |
| Gate hooks | `<state_dir>/kourai/hooks/<version>/` plus a sha256 manifest | installer | a new folder per version |
| Project settings | marked keys in `<repo>/.claude/settings.local.json`: `env.KOURAI_CONFIG`, `extraKnownMarketplaces`, `enabledPlugins`, the kourai `permissions.allow` lines, the hook registrations | installer | re-rendered |
| Auto-mode rules | the kourai block of `autoMode.allow` in `~/.claude/settings.json` (the classifier reads only user settings) | installer | re-rendered |
| Install record | `<state_dir>/kourai/installed.json` and `history.log` | installer | new version, previous version, hashes of everything written |
| Backups | `<state_dir>/kourai/backups/<timestamp>/` | installer | one folder per apply |

Nothing the installer writes lives in git. The project's repo keeps only
its own agents, project rules and adapters.

## Why a per-installation local marketplace

A plugin's version cannot be pinned in `enabledPlugins`, which takes only
`true` or `false`. The only pin is the `ref` or `sha` on a marketplace or
plugin source. A marketplace name is also unique per user. If RunnerCity
and livecorrectly-site both used the shared `kourai` marketplace, both would
have to run the same version. During the pilot, livecorrectly-site must be
able to run a newer version while RunnerCity stays put.

So each installation gets its own small marketplace, named
`kourai-<project.name>`, in its state folder. Its single entry points at
`./releases/<version>`. The plugin keeps the name `kourai`, so agents are
still `kourai:card-manager` in every project. A plugin in a marketplace
added from a local path loads in place, so `${CLAUDE_PLUGIN_ROOT}` is the
release folder itself. Each release folder is a read-only checkout of the
tag `kourai--v<version>`, and its commit is checked against the tag.

- **(verify)** `extraKnownMarketplaces` takes a local-directory source in the
  project's `settings.local.json`, not only in `settings.json`. Fallback:
  `claude plugin marketplace add <dir> --scope local`, run by the installer.
- **(verify)** Switching the entry to another release folder, then running
  `/reload-plugins` or starting a new session, loads the new folder. The docs
  say updates are found by comparing versions. Each release has its own
  `version` in `plugin.json`, so the version differs on every switch.

The documented alternative is to install from GitHub with
`"source": {"source": "github", "repo": "shawnlauzon/kourai", "ref": "kourai--v0.2.0"}`.
It is kept as the fallback if a check above fails. Its cost is one version
per machine, and the GitHub credentials have to work without a prompt.

## Gate trust

The gates are the one part agents cannot change, and an update must keep
it that way:

- Hooks never run from the release folder or from `${CLAUDE_PLUGIN_ROOT}`.
  `apply` copies them to `<state_dir>/kourai/hooks/<version>/`, together
  with their own copy of `kourai-config` and the defaults. It records each
  file's sha256 and registers the hooks by absolute path, with `--config`
  written into the command.
- `kourai-install check`, and `board-wait` on every poll, compare the
  registered files with the recorded hashes. They print `GATE DRIFT` on a
  mismatch (fail closed).
- `check` also compares the active release folder with its tag. This is
  agent-flow's kit-verify idea: it catches local edits to plugin files. It
  also lists project agents that override plugin agents of the same name.
- In the kourai repo, changes under `hooks/`, `installer/` and the bot
  identity script always need the user's review.

## The commands

`kourai-install` is run only by the user, attended. Agents never run it,
as with `apply-settings-section.sh` today.

### `plan`

Reads the target version from `install.version` in the config. It needs the
network once, to fetch the tag into a new release folder, and does nothing
else that has effects. It renders every output into
`<state_dir>/kourai/staged/<version>/` and writes one review file,
`<state_dir>/kourai/plans/<from>-to-<to>.md`, with:

1. The kourai changelog between the two versions, from `CHANGELOG.md` and the
   commit list.
2. The plugin diff: a file list for agents, rules and scripts, and the full
   diff for `hooks/` and `installer/`.
3. The settings diff: each permissions line added or removed, each auto-mode
   rule, the hook registrations, and the env.
4. Gate changes: old and new hashes per hook.
5. The config checked against the new defaults: keys that became required,
   keys removed or renamed (errors), and new keys with their defaults.
6. Project agents that override plugin agents, and allow lines that the
   installer does not own and that look stale (listed, never removed).

Exit codes: 0 means nothing to change, 10 means a plan was written, and 1
means the config is invalid under the new version (the plan says what to
add).

### `apply`

Applies exactly the staged plan. It refuses if any input has changed since
`plan`: the config, the settings files, or the release folder (it compares
the hashes recorded in the plan). It refuses while a board watcher or a
card agent is running (`agent-state.sh`). Updates land between batches,
like `[AGENTS]` merges today. Then it:

1. Copies every file it will write into `backups/<timestamp>/`, and the
   config as it stood at `plan`.
2. Copies the gate hooks and records their hashes.
3. Rewrites only the keys and blocks it owns in the two settings files.
   Everything else in those files stays byte-for-byte.
4. Points the local marketplace entry at the new release.
5. Writes `installed.json` with `previous` set to the old version, and adds
   a line to `history.log`.

It prints the next step: start `/kourai:run-board` in a new session, or run
`/reload-plugins` in an open one.

### `rollback`

One command, no network, no plan needed. It restores every file from the
newest backup, which also puts back the config's old `install.version`. It
points the marketplace entry back at the previous release folder, which is
still on disk, re-registers the old hook copies, and records the rollback in
`history.log`. If the config was edited after the apply, rollback first
shows that diff and asks before overwriting it.

### `check`

Read-only and fast. It reports the config's validity, gate drift, plugin
drift against the tag, settings drift (a kourai-owned key changed by hand),
and overrides. `board-wait` runs the gate part of it.

### `prove`

Attended. It runs each command the auto-mode rules are meant to allow once,
so a rule that does not match fails while the user is present, not on the
unattended board.

## Releasing a kourai version

1. Update `CHANGELOG.md` and set `version` in `.claude-plugin/plugin.json`.
   - **Major:** a config break, meaning a key removed or renamed, a new
     required key, or a change to the comment protocol between agents.
   - **Minor:** new keys with defaults, or new behavior.
   - **Patch:** fixes.
2. Run `tests/run.sh` and `claude plugin validate --strict .`.
3. Run `claude plugin tag --push`. It creates `kourai--v<version>`, after
   checking that the manifest and the marketplace agree.

## The update path, end to end

| Step | Who | What |
|---|---|---|
| 1 | user | Set `install.version = "0.3.0"` in `<state_dir>/kourai.toml` |
| 2 | user | `kourai-install plan` |
| 3 | user (or the workflow verifier, reading the plan file) | Review `plans/0.2.0-to-0.3.0.md` |
| 4 | user, with the board stopped between batches | `kourai-install apply` |
| 5 | user | Start `/kourai:run-board` in a new session |
| Back out | user | `kourai-install rollback`, then step 5 |

On RunnerCity's board, steps 2 to 4 can be one `[AGENTS]` card. Its review
file is attached as a comment, and the user's approval of the card is the
review.

## Testing the installer

Its tests follow the repo rule: fakes first on `PATH`. The kourai remote is
a local bare repo reached by a `file://` path. The `git` fake must then allow
`fetch` and `clone` for `file://` URLs only. `claude` is a fake that records
`plugin marketplace` calls. `~/.claude/settings.json` and the project
settings are temporary copies, passed as `--user-settings` and
`--project-settings`, so a test can never touch the real ones.

## Open questions for the user

1. Is the per-installation local marketplace acceptable, or is one kourai
   version per machine fine? One version per machine would allow the
   simpler GitHub source pin.
2. Should `apply` refuse while any board agent runs, or only while the
   watcher runs?
3. Should tag protection be set on `kourai--v*` in the kourai repo?
4. Where should kourai's own tests run in CI? There is no self-hosted runner
   for this repo, and GitHub-hosted minutes are paid out of pocket.
