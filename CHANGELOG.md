# Changelog

## 0.1.0-rc1

The first release candidate: the RunnerCity workflow, extracted.

- Nine plugin agents (board watcher, card manager, merger, workflow builder, workflow verifier,
  code reviewer, time optimizer, token auditor, Sentry triager) and `/kourai:run-board`.
  Plugin agents start as `kourai:<name>`; a project's own agents start by bare name. The
  `[agents]` table in the config lists both.
- `rules/core.md` and a project rules file made from `rules/project-template.md`. Rules markers
  are `[core: <heading>]` and `[project: <heading>]`; `rules-ranges.sh check` verifies both.
- Every id, path, repo name, limit and timeout reads from one TOML config via `kourai-config`;
  env overrides the scripts already had keep winning.
- `kourai-hook` and `kourai-project` run a version-pinned gate or a project script by name.
- Gates (`merge-gate`, `staging-gate`, `merged-comment-gate`, `review-policy`) copied by hash
  into the installation, never run from the plugin folder.
- `installer/kourai-install`: plan, apply, rollback, check, prove, with a per-installation
  local marketplace, backups and a one-command rollback.
- Liveness (agent-state, agents-status, board-wait) accepts the `kourai:` agent-type prefix.
- Tests: the ported script tests on a fixture config, the installer test on scratch, the real
  `claude plugin validate --strict .`, `tests/prove-real-agent.sh` (one real `claude -p` run),
  and an id scan over the diff and the tree.
- Ported up to RunnerCity workflow change RunnerCityOrg/runnercity-app#493 (Sentry triage
  code-freeze rule).
- Review fixes: the permission template allows named scripts only (no command runners, no identity
  scripts) and `kourai-project` takes a script name, never a path; the review policy tests flag
  paths before free paths (live order); `board-wait` and `pr-ready` run the installed policy through
  `kourai-hook`; project scripts are named `kourai-project <script>` in the agents and core rules;
  `kourai-install check` reports `CONFIG DRIFT`, `plan` lists stale settings lines; the rollback order
  keeps the gates on; the docs say what a project must supply.
- Docs: getting started, walkthrough, how it runs, config, variables, updating, adapters,
  switch-over, sync.

Not in this version: an adapter implementation, a per-poll gate-drift check in `board-wait`,
CI.
- Send-back round 2: the watcher reload reads the board watcher from the plugin once the project's copy
  is gone; `rules/core.md` has a Placeholders table mapping each setting placeholder to its
  `kourai-config get` key (tested); the installer's stale-line check catches relative mentions of the
  project's `.claude/` folders; `kourai-hook review-policy.sh check` is allowed; the workflow verifier
  runs the refusal scan and the read-only drift check by full path; `docs/SWITCH-OVER.md` has a step that
  rewrites the auto-mode rules before the board starts.
