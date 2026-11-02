# Adapters (the seam, not an implementation)

Today kourai talks to Trello for the board, GitHub for code, PRs and CI, and Claude Code for the
agent runtime. Each of those is a set of scripts under `bin/` that read their settings from the
config: `board-wait.py`, `board-snapshot.sh`, `card-summary.sh` (Trello), `as-claude.sh`,
`gh-app-token.sh`, `pr-*.sh`, `ci-wait.sh` (GitHub), `agent-state.sh`, `agents-status.sh` (runtime).
No adapter interface is implemented in 0.1.0-rc1. This page records where the seam runs, so a
second tracker or host can be added without rewriting the agents.

## What an agent depends on

- The **comment protocol**: the phrases in `rules/core.md` ("Comment glossary") and
  `rules/phrases.txt`. Agents write them; hooks and `board-wait.py` act on them. A tracker that
  can hold a list-per-state board, comments and labels can carry the protocol.
- The **board model**: lists with owners, a card's name, description, labels, comments, checklist,
  position, and member assignment.
- The **repo model**: a branch per card, a PR per repo, required checks, a review state.

## What a second tracker would provide

Reads: lists and cards in order, a card's comments newest-first, labels, members, activity.
Writes: move a card, add a comment, set the description and name, add or remove a label. All
writes are the `trello*` calls in the agents and the label script today; an adapter would put
them behind one script name each so the agents stop naming the Trello MCP.

## What a second host would provide

A pull request with checks and an approval state; a way to merge with a head-sha match; a bot
identity separate from the user (today `as-claude.sh`).

## What a project must supply (the project layer)

The plugin ships the board's agents, rules, gates and board scripts. It does not ship a test host, a
builder, a release or a check script: the project supplies them, in its own checkout, and the plugin
names them. A project that supplies none of this still gets the board, the gates and the workflow
agents, but every step that names one of the items below stops with a clear error.

**Project agents** (`<repo>/.claude/agents/`, listed in the config's `[agents] project`, started by their bare
name; the plugin's agents are started as `kourai:<name>`). The card manager and the board watcher start these
names, so a project either provides each or leaves the step out of its rules:
- `mobile-builder` and `server-builder` (one builder per aspect of a card; their repos are `repos[]` in the config),
  `test-builder` (behavior tests only), `feature-tester` (the BEFORE and AFTER runs);
- `promoter` (a release), `android-builder` and `ios-builder` (the app builds of a release), `fraud-watcher`
  (a daily check): only when the project releases or watches money (`[release] enabled`).

**Project scripts** (the folder `paths.project_bin`, run as `kourai-project <script> [args]`; a name, never a path):
- `card-test-server.sh` (give a card one of the test servers and take it back: `assign`, `release`, `list`,
  `waiting`, `release-hold`), `test-server.sh` (`ports`, bring a test server up), `server-probe.sh` (is a held
  server's host reachable: `scan`), `ci-unstick.sh` (`scan`: a queued CI job that capacity should have run);
- `ft-report.sh` (the feature tester's report), `builder-trial.sh` (the mobile builder trial ledger, optional);
- `workflow-checks.sh` (the mechanical checks the workflow builder runs on a workflow PR) and
  `apply-settings-section.sh` (apply and `--check` one section of `.claude/board/user-setup-changes.md`).
A project without test servers sets `limits.card_test_servers` to 0 and writes rules that skip the BEFORE and
AFTER runs.

**Project files**:
- `.claude/board/agent-rules.md`: the project's and the user's rules that every agent that starts without
  `CLAUDE.md` reads first (`agents/code-reviewer.md`); code conventions, test rules, the writing rules;
- the project rules file (`project.rules_file`, default `<repo>/.claude/board/rules.md`): what only this project
  decides (the settings table, the release steps, test and area rules); `rules/core.md` is the plugin half;
- `CLAUDE.md` in each repo, read by the agents that start with it.

**Config** (`<state_dir>/kourai.toml`, outside git): the ids and paths in `docs/VARIABLES.md`, the review tables of
each repo (`always_paths` for every folder a user can see, listed because a glob like `*.md` matches in every
folder), and `guarded.paths`.

## Rule for adding one

Code goes in `adapters/<name>/`, with its tests under `tests/`; the agents change only where they
name the old tool. Anything touching `hooks/`, `installer/` or the identity script needs the
user's review.
