# Workflow variables: the inventory

Every value in RunnerCity's workflow that another project may want to change,
with its value, where it was hard-coded when the inventory was taken (the
"Where today" column; line numbers are RunnerCity's files at that baseline,
not kourai's), and the config key that replaces it. Read from runner_city mobile main `913585a3` (2026-10-17) plus
the four live hooks on disk (marked "live"); paths are relative to
`runner_city/.claude/`. R = `board/rules.md`, W = `board/WORKFLOW.md`.

Every key in `config/defaults.toml` appears here (`tests/test-defaults.sh`
checks it). "Default" is the shipped default; "RunnerCity" is its value
today when it differs or when the key has no default. Identities have no
default and are required.

## Install

| Key | Default | RunnerCity | Where today | What it does |
|---|---|---|---|---|
| `install.version` | `0.1.0-rc1` | n/a | new | kourai version the installation runs (tag `kourai--v<version>`) |
| `install.source_repo` | `shawnlauzon/kourai` | n/a | new | Where releases come from |

## Project and paths

| Key | Default | RunnerCity | Where today | What it does |
|---|---|---|---|---|
| `project.name` | required | `runnercity` | prose everywhere ("RunnerCity Development board") | Messages, card names |
| `project.state_dir` | `~/Development/{project.name}_files` | `~/Development/runner_city_files` | 83 hits in 36 files; `bin/board-wait.py:109`, `bin/pause-lib.sh:12`, `bin/heartbeat.sh:13`, every hook | State, logs, locks, secrets |
| `project.transcripts_dir` | `auto` | `~/.claude/projects/-Users-shawn-Development-github-runner-city` | `bin/agent-state.sh:83,99`, `agents/token-auditor.md:12`, `agents/workflow-verifier.md:25` (env `AGENT_TRANSCRIPTS_DIR`) | Liveness and token audit read transcripts here |
| `project.rules_file` | `""` | `.claude/board/rules.md` | `bin/rules-ranges.sh:24` (env `RULES_FILE`) | The project part of the rules |
| `paths.trello_env` | `{project.state_dir}/trello.env` | same | every hook; `bin/release-gap.sh:22`, `card-summary.sh:32`, `pr-ready.sh:21`, `board-snapshot.sh:38`, `agents-status.sh:52`, `board-wait.py:171`, `board-watch.sh:10` (env `TRELLO_ENV_FILE` in bin only) | Trello key and token |
| `paths.locks_dir` | `{project.state_dir}/locks` | same | `bin/dev-merge-lock.sh:32`, `bin/run-locked.sh:31` (env `RC_LOCK_DIR`) | Named locks |
| `paths.pause_dir` | `{project.state_dir}/pause` | same | `bin/pause-lib.sh:12` (env `RC_PAUSE_DIR`) | Per-card pause files |
| `paths.heartbeat_dir` | `{project.state_dir}/heartbeats` | same | `bin/heartbeat.sh:13` (env `HEARTBEAT_DIR`) | Keep-alive files |
| `paths.test_server_state_dir` | `{project.state_dir}/test-servers` | same | `bin/card-test-server.sh:71` (env `RC_TEST_SERVER_DIR`) | Which card holds which server |
| `paths.test_server_up_dir` | `{project.state_dir}/test-server-up` | same | `bin/test-server.sh:195` (env `RC_UP_DIR`) | Bring-up jobs |
| `paths.agents_status_cache` | `{project.state_dir}/agents-status-cache` | same | `bin/agents-status.sh:54` (env `AGENTS_STATUS_CACHE`) | Comment cache |
| `paths.board_wait_state` | `{project.state_dir}/board-wait.state.json` | same | `bin/board-wait.py:132` (env `BOARD_WAIT_STATE`) | Watcher cursor |
| `paths.board_watcher_heartbeat` | `{project.state_dir}/board-watcher.heartbeat` | same | `bin/board-wait.py:133` (env `BOARD_WAIT_HEARTBEAT`), `commands/run-board.md:11` | Watcher liveness for /run-board |
| `paths.hooks_dir` | `{project.state_dir}/kourai/hooks` | n/a | new (today the hooks run from `.claude/hooks/`) | Installed, hash-recorded gate copies |
| `paths.worktree_root` | `.claude/worktrees` | same | `bin/agent-worktree.sh:44,51`, `bin/schema-dump.sh:21`, R256 | Agent worktrees inside each repo |

## Board (Trello)

| Key | Default | RunnerCity | Where today | What it does |
|---|---|---|---|---|
| `board.provider` | `trello` | same | implied everywhere | Tracker |
| `board.id` | required | `<board-id>` | R27; `bin/board-wait.py:111`, `board-snapshot.sh:40`, `release-gap.sh:24`, `board-watch.sh:17`; hooks `merge-gate.sh:24` (live :38), `staging-gate.sh:22` (live :27) | The board |
| `board.name` | `""` | `RunnerCity Development` | R1, `commands/run-board.md:2`, `agents/board-watcher.md:3` | Prose name |
| `board.label_prefix` | `""` | `ari:cloud:trello::label/workspace/<workspace-id>/` | R78 | Label ids for the Trello MCP |
| `board.members.user` | required | `<id>` | `hooks/merge-gate.sh:26`, `merged-comment-gate.sh:32`, live `staging-gate.sh:31`, `bin/board-watch.sh:11`, `board-snapshot.sh:41` | Whose comments are instructions and sign-offs |
| `board.members.agent` | required | `<id>` | `bin/board-wait.py:112`, `card-summary.sh:59`, `agents-status.sh:76`, `board-snapshot.sh:42` | The account agents post as |
| `board.lists.<role>.name` | the 11 names below | same | `bin/board-wait.py:279-280` (13 words with retired names), `release-gap.sh:46-47`, `board-snapshot.sh:113-114`, R31-41 | Finds a list by its name word |
| `board.lists.<role>.id` | `""` | merging `<id>`, merged `<id>`, done `<id>` | live `merged-comment-gate.sh:29-31`; tracked `merge-gate.sh:25`, `merged-comment-gate.sh:29-31` (old APPROVED and INTEGRATION_TEST ids) | Gates check list ids |
| `board.lists.<role>.aliases` | proposed `BRAINSTORM`, questions `WAITING FOR CLARITY`, merging `APPROVED`, merged `READY FOR STAGING` | same | `bin/board-wait.py:279-280`, `agents/token-auditor.md:71` | Retired names still matched |
| `board.labels.active` | `""` | `<id>` | R82, `bin/board-wait.py:116` | Actively worked (green) |
| `board.labels.blocked` | `""` | `<id>` | R83, `bin/board-wait.py:113` | Blocked (dark red) |
| `board.labels.no_action` | `""` | `<id>` | R84, `bin/board-wait.py:117` | No action required (purple) |
| `board.labels.conflict` | `""` | `<id>` | R85, `bin/board-wait.py:115`, `agents/merger.md:39` | Merge conflict (orange) |
| `board.labels.attended` | `""` | `<id>` | R86, `bin/board-wait.py:114`, `agents/workflow-builder.md:71` | Needs attended session (yellow) |

The 11 list roles, in board order: `proposed` (PROPOSED), `bugs` (BUG REPORTS), `todo` (TODO), `questions` (QUESTIONS), `building` (BUILDING), `testing` (TESTING), `review` (REVIEW), `merging` (MERGING), `merged` (MERGED), `releasing` (RELEASING), `done` (DONE). Their keys: `board.lists.proposed.name`, `board.lists.proposed.id`, `board.lists.proposed.aliases`, `board.lists.bugs.name`, `board.lists.bugs.id`, `board.lists.bugs.aliases`, `board.lists.todo.name`, `board.lists.todo.id`, `board.lists.todo.aliases`, `board.lists.questions.name`, `board.lists.questions.id`, `board.lists.questions.aliases`, `board.lists.building.name`, `board.lists.building.id`, `board.lists.building.aliases`, `board.lists.testing.name`, `board.lists.testing.id`, `board.lists.testing.aliases`, `board.lists.review.name`, `board.lists.review.id`, `board.lists.review.aliases`, `board.lists.merging.name`, `board.lists.merging.id`, `board.lists.merging.aliases`, `board.lists.merged.name`, `board.lists.merged.id`, `board.lists.merged.aliases`, `board.lists.releasing.name`, `board.lists.releasing.id`, `board.lists.releasing.aliases`, `board.lists.done.name`, `board.lists.done.id`, `board.lists.done.aliases`.

There are no per-list WIP numbers today. The WIP limits are `limits.card_test_servers` (TESTING), `limits.conflict_fixes_at_once` (MERGING fixes) and `limits.releases_at_once` (RELEASING).

## GitHub

| Key | Default | RunnerCity | Where today | What it does |
|---|---|---|---|---|
| `github.user_login` | required | `shawnlauzon` | `bin/board-wait.py:119`, `hooks/merge-gate.sh:27`, `merged-comment-gate.sh:33`, live `review-policy.sh:65` | Only this login's review approves |
| `github.app_id` | required | `5190062` | `bin/gh-app-token.sh:11` | App the agents act as |
| `github.app_key_file` | required | `<app key file>` | `bin/gh-app-token.sh:12` | App private key |
| `github.bot_name` | `""` | `runnercity-claude` | `bin/as-claude.sh:2-5`, `bin/gh-app-token.sh:38`, R253 | Bot identity in prose and errors |
| `guarded.paths` | `.github/`, `.claude/hooks/`, `.claude/settings*.json`, `.mcp.json` | also `.claude/board/user-setup-changes.md`, `as-claude.sh`, `gh-app-token.sh`, `dev-merge-lock.sh`, `run-locked.sh`, `apply-settings-section.sh`, `fraud-stripe.sh`, `schema-dump.sh`, `agent-worktree.sh`, server `infra/` | live `review-policy.sh:100-104` | Always need the user's review |

## Repos (`repos`: one entry each, in merge order)

RunnerCity: server first (`RunnerCityOrg/runnercity-api-server`, base `development`, release branch `staging`, card tag `server #`), then mobile (`RunnerCityOrg/runnercity-app`, base `main`, prose "mobile", release tag `client-build/`, legacy `shawnlauzon/runner_city`).

| Key | Default | RunnerCity | Where today | What it does |
|---|---|---|---|---|
| `repos[].id` | required | `server`, `mobile` | `bin/card-kind.sh`, `bin/agent-worktree.sh:31-35` | Short name |
| `repos[].slug` | required | as above | about 330 hits in 26 files; `bin/card-kind.sh:64,72`, `gh-app-token.sh:30-31`, `board-wait.py:122`, `board-snapshot.sh:79,93-94`, `pr-ready.sh:86`, live `merge-gate.sh:121`, `merged-comment-gate.sh:109`, `review-policy.sh:66-67`, `staging-gate.sh:27-28` | GitHub repo |
| `repos[].legacy_slugs` | `[]` | mobile `shawnlauzon/runner_city` | `bin/gh-app-token.sh:30-31`, `card-kind.sh:64`; tracked `base-push-gate.sh:14,62` still uses it as the real name | Old names still accepted |
| `repos[].path` | required | `~/Development/github/runnercity-api-server`, `~/Development/github/runner_city` | `bin/agent-worktree.sh:39,41` (env `RC_MOBILE_ROOT`, `RC_SERVER_ROOT`), live `staging-gate.sh:28-29`, live `review-policy.sh:68-69`, `apply-settings-section.sh:40`, `commands/run-board.md:7` | Main checkout |
| `repos[].base` | `main` | `development`, `main` | `bin/agent-worktree.sh:39,41`, hooks `staging-gate.sh` (live :112-123), R173, R247, R259 | Branch cards merge into |
| `repos[].prose_name` | `""` | `development`, `mobile` | R246, `board/agent-rules.md:49` | What prose calls the base |
| `repos[].release_branch` | `""` | server `staging` | live `staging-gate.sh:43,110-114`, `agents/promoter.md:14,157` | Promoter-only release branch |
| `repos[].release_tag_prefix` | `""` | mobile `client-build/` | live `staging-gate.sh:45,119`, R194, `agents/promoter.md:98-100` | Tag that triggers a client build |
| `repos[].card_name_tag` | `#` | `server #`, `#` | R66 | Card name suffix `(#N, server #M)` |
| `repos[].adapter` | `""` | (not read yet: no adapter implementation) `rails`, `flutter` | stack knowledge in the builder, tester and promoter agents | Stack adapter |
| `repos[].deps_commands` | `[]` | `bundle install --quiet`; `flutter pub get` | `bin/agent-worktree.sh:74,76` (env `RC_SKIP_DEPS`) | Worktree setup |
| `repos[].worktree_env_placeholders` | `[]` | mobile `.env .env.development .env.staging .env.production .env.local` | `bin/agent-worktree.sh:59` | Empty env files in worktrees |
| `repos[].worktree_env_links` | `[]` | mobile `.env .env.e2e`; server `.env.development.local .env.localhost` | `bin/agent-worktree.sh:63,67` | Env files linked into worktrees |
| `repos[].worktree_env_placeholder_roles` | `[]` | mobile `[]` (set per project) | `bin/agent-worktree.sh` | Roles that get the empty env placeholder files |
| `repos[].worktree_env_link_roles` | `[]` | mobile and server builder roles | `bin/agent-worktree.sh` | Roles that get the env files linked in |
| `repos[].worktree_git_exclude` | `false` | `true` for the mobile repo | `bin/agent-worktree.sh` | Add the placeholder env files to the worktree's git exclude |
| `repos[].review.always_paths` | `[]` | server `config/routes.rb app/controllers/* app/views/* app/channels/* app/mailers/* config/locales/*`; mobile `lib/* assets/* android/* ios/* web/* macos/* linux/* windows/*` | live `review-policy.sh:119-127` | Always needs review |
| `repos[].review.free_paths` | `[]` | mobile `test/* integration_test/* test_driver/* docs/* tool/* backlog/* .claude/* *.md analysis_options.yaml dart_test.yaml devtools_options.yaml .gitignore`; server `test/* tests/* docs/* .claude/* *.md .rubocop.yml .gitignore` | live `review-policy.sh:119-127`, R134 | Never needs review. Order of the policy: guarded paths, `always_paths`, `flag_paths`, `free_paths`, `default`; a `*` matches `/`, so a repo that frees `*.md` lists `assets/* android/* ios/* web/* macos/* linux/* windows/*` in `always_paths` (a test pins it) |
| `repos[].review.default` | `"review"` | mobile `review`; server `flag` | review-policy.sh | What a file in no review list needs: `review` or `flag` |
| `repos[].no_add_paths` | `[]` | mobile `docs/ui_tests/` | merge-gate.sh | Prefixes a PR may not add or change files under (screenshots are never in git) |
| `repos[].review.flag_paths` | `[]` | server: everything else (needs `App-visible:`) | live `review-policy.sh:95,125-127`, `bin/pr-ready.sh:87` | Review only when the PR says `App-visible: yes` |
| `repos[].review.keep_approval_paths` | `[]` | mobile `test/ integration_test/ docs/`; server `test/ tests/ docs/` | live `review-policy.sh:182`, R134 | Commits after approval that keep it |
| `repos[].kind.agents_paths` | `[]` | mobile `.claude/* CLAUDE.md *.md docs/* backlog/*` (not `docs/ui_tests/*`); server `.claude/* *.md docs/*` | `bin/card-kind.sh:64-78` | [AGENTS] kind |
| `repos[].kind.tests_paths` | `[]` | mobile `test/* integration_test/* test_driver/* tool/* .github/* analysis_options.yaml dart_test.yaml devtools_options.yaml .gitignore`; server `test/* tests/* .github/* .rubocop.yml .gitignore` | `bin/card-kind.sh:64-78` | Tests kind |
| `repos[].ci.docs_only_check` | `""` | mobile `flutter-test` | R173, R263-264, `agents/merger.md:41` | Check that may be absent on docs-only PRs |
| `repos[].ci.docs_only_paths` | `[]` | mobile `.claude/** docs/** **.md` | same | Paths that count as docs-only |

## Limits (WIP and sizes)

| Key | Default | Where today | What it does |
|---|---|---|---|
| `limits.card_test_servers` | `3` | R11, R210, W64, `bin/card-test-server.sh:72-73` (env `RC_CARD_TEST_SERVERS`), `agents/card-manager.md:184`, `feature-tester.md:108` | TESTING WIP: one card per server. Planned to become 5 |
| `limits.ci_jobs_at_once` | `3` | R12, W65 | CI jobs at once, one kept for the merger |
| `limits.releases_at_once` | `1` | R15, R187, `agents/promoter.md:52`, `board-watcher.md:183` | Releases in progress |
| `limits.conflict_fixes_at_once` | `2` | R18, W72, `agents/board-watcher.md:181` | Conflict fixes or refreshes at once |
| `limits.failures_before_questions` | `3` | R14, R316, `agents/card-manager.md:90` | Failed AFTER runs before QUESTIONS |
| `limits.builders_per_aspect` | `1` | `agents/card-manager.md:62` | Builders per aspect |
| `limits.context_ceiling_tokens` | `150000` | R19, R229, `bin/board-wait.py:145` (env `BOARD_WAIT_CONTEXT_CEILING`), `agents/board-watcher.md:26,209` | CONTEXT: hand-off threshold |
| `limits.context_ceiling_roles` | card-manager, promoter, feature-tester, mobile-builder, server-builder, test-builder | `bin/board-wait.py:147` | Roles checked against it |
| `limits.watcher_compact_tokens` | `100000` | `agents/board-watcher.md:6` (`autoCompactWindow`), W56 | Watcher's own compaction |
| `limits.merger_full_unit_files` | `100` | `agents/merger.md:41` | Changed files that force a full unit run |
| `limits.handoff_note_lines` | `20` | `agents/board-watcher.md:224` | HANDOFF: note size |

## Release

| Key | Default | Where today | What it does |
|---|---|---|---|
| `release.enabled` | `true` | implied | Releases on or off (off for the livecorrectly-site pilot) |
| `release.due_cards` | `5` | R13, W67 | Due at this many cards in MERGED |
| `release.due_urgent_cards` | `1` | R13, R72 | Due at this many 🚨 cards |
| `release.due_max_wait_hours` | `24` | R13, `agents/promoter.md:55`, `bin/board-wait.py:825` | Due when a card waited this long |
| `release.gap_hours` | `12` | R16, W69, W117, `bin/release-gap.sh:25` (env `RELEASE_GAP_HOURS`), `bin/board-wait.py:39` (docstring), `agents/board-watcher.md:45,183`, `promoter.md:54` | Hours between releases (4 until 2026-10-17) |
| `release.urgent_skips_gap` | `true` | R16 | 🚨 releases ignore the gap |
| `release.urgent_fix_deadline_hours` | `24` | R17, R204, `bin/board-wait.py:817`, `agents/board-watcher.md:138` | 🚨 fix deadline before a revert |
| `release.urgent_deadline_rewake_hours` | `2` | `bin/board-wait.py:818`, `agents/board-watcher.md:45,142` | Repeat wakes after it passed |
| `release.release_server` | `integration` | `bin/dev-merge-lock.sh:33-41`, `bin/test-server.sh:210` | The promoter's test server |

## Tests

| Key | Default | Where today | What it does |
|---|---|---|---|
| `tests.reruns_per_failing_test` | `1` | R156, W103, `agents/merger.md:44`, `promoter.md:77,155`, `feature-tester.md:45,69,82` | Flake policy (`--rerun-failed-once`) |
| `tests.void_reruns` | `1` | `agents/promoter.md:68,82` | Void release runs retried |
| `tests.flaky_fix_proof_runs` | `5` | `agents/test-builder.md:41` | Green runs that prove a flake fixed |

## Timeouts and cadences

| Key | Default | Where today | What it does |
|---|---|---|---|
| `timeouts.wait_limit_seconds` | `530` | R21 says 540, W75 and `board-watcher.md:44` say 9 minutes; scripts use 530: `bin/board-wait.py:128`, `ci-wait.sh:36`, `run-wait.sh:32`, `test-server.sh:617` (envs `BOARD_WAIT_LIMIT`, `CI_WAIT_LIMIT`, `RUN_WAIT_LIMIT`, `RC_UP_LIMIT`); `watch-results ... 530` in `feature-tester.md:30`, `promoter.md:18` | Longest foreground wait |
| `timeouts.bash_timeout_ms` | `600000` | R221, `agents/board-watcher.md:44`, `bin/board-wait.sh:3` | Bash tool timeout for waits |
| `timeouts.board_poll_seconds` | `30` | `bin/board-wait.py:129` (env `BOARD_WAIT_POLL`) | Trello polls |
| `timeouts.board_slow_check_seconds` | `120` | `bin/board-wait.py:130` (env `BOARD_WAIT_SLOW`) | GitHub and deadline checks |
| `timeouts.board_slow_margin_seconds` | `60` | `bin/board-wait.py:131` (env `BOARD_WAIT_SLOW_MARGIN`) | No slow check near the limit |
| `timeouts.release_gap_recheck_seconds` | `300` | `bin/board-wait.py:140` (env `BOARD_WAIT_GAP_RECHECK`) | Release-gap checks |
| `timeouts.start_repeat_seconds` | `300` | `bin/board-wait.py:141` (env `BOARD_WAIT_START_REPEAT`), W214 | Repeat START: |
| `timeouts.stuck_repeat_seconds` | `600` | `bin/board-wait.py:142` (env `BOARD_WAIT_STUCK_REPEAT`) | Repeat STUCK: |
| `timeouts.stuck_grace_seconds` | `180` | `bin/board-wait.py:143` (env `BOARD_WAIT_STUCK_GRACE`) | Before STUCK: is printed |
| `timeouts.agent_idle_minutes` | `30` | R20, R326, W74, `bin/board-wait.py:144` (env `BOARD_WAIT_IDLE`, seconds) | Idle agent is STUCK |
| `timeouts.safety_wake_hours` | `4` | `bin/board-wait.py:59,893`, `agents/board-watcher.md:21`, W76 | Safety wake |
| `timeouts.workflow_work_rewake_hours` | `2` | `bin/board-wait.py:853`, `agents/board-watcher.md:24,69,188` | Re-send WORKFLOW WORK: |
| `timeouts.todo_held_hours` | `2` | `bin/board-wait.py:861-862`, `agents/board-watcher.md:25` | Held TODO wake |
| `timeouts.watcher_heartbeat_stale_minutes` | `25` | `commands/run-board.md:11` | /run-board liveness |
| `timeouts.card_manager_hours` | `4` | `agents/card-manager.md:180` | Card manager hand-off |
| `timeouts.agent_dead_quiet_minutes` | `20` | R216, W212 | Silent agent with no report is dead |
| `timeouts.agent_dead_api_error_minutes` | `2` | W212 | After an API error |
| `timeouts.ci_poll_seconds` | `20` | `bin/ci-wait.sh:72` (env `CI_WAIT_POLL`) | CI polls |
| `timeouts.ci_no_checks_after_seconds` | `120` | `bin/ci-wait.sh:102` (env `CI_WAIT_NO_CHECKS_AFTER`) | "No checks" verdict |
| `timeouts.run_wait_poll_seconds` | `5` | `bin/run-wait.sh:35` (env `RUN_WAIT_POLL`) | Background-run polls |
| `timeouts.lock_wait_seconds` | `14400` | `bin/run-locked.sh:13,56` (env `RUN_LOCKED_TIMEOUT`) | Named-lock wait |
| `timeouts.heartbeat_interval_seconds` | `60` | `bin/run-locked.sh:36`, `bin/test-server.sh:207` (env `HEARTBEAT_INTERVAL`) | Heartbeat touches |
| `timeouts.pause_poll_seconds` | `10` | `bin/pause-lib.sh:52` (env `RC_PAUSE_POLL`) | Pause checks |
| `timeouts.stop_grace_seconds` | `10` | `bin/pause-lib.sh:64` (env `RC_STOP_GRACE`) | TERM to KILL |
| `timeouts.pr_conflicts_tries` | `5` | `bin/pr-conflicts.sh:31` (env `PR_CONFLICTS_TRIES`) | Mergeability retries |
| `timeouts.pr_conflicts_wait_seconds` | `6` | `bin/pr-conflicts.sh:32` (env `PR_CONFLICTS_WAIT`) | Between them |
| `liveness.lookback_hours` | `24` | `bin/agent-state.sh:348` (env `AGENT_STATE_HOURS`) | Transcript window |
| `liveness.grace_seconds` | `120` | same (env `AGENT_STATE_GRACE`) | Start grace |
| `liveness.quiet_seconds` | `900` | same (env `AGENT_STATE_QUIET`) | QUIET threshold |
| `liveness.background_max_seconds` | `14400` | same (env `AGENT_STATE_BG_MAX`) | Longest background run |
| `liveness.stale_seconds` | `1200` | same (env `AGENT_STATE_STALE`) | Stale last write |
| `liveness.card_roles` | card-manager, mobile-builder, server-builder, test-builder, feature-tester | `bin/agent-state.sh:110` | Card from the first prompt |
| `liveness.floating_roles` | merger, promoter, workflow-builder, workflow-verifier | `bin/agent-state.sh:113` | Card from the last touch |
| `liveness.shared_roles` | board-watcher, merger, promoter, workflow-builder, workflow-verifier, token-auditor, fraud-watcher, sentry-triager | `bin/usage/agg.py:100,120` (also lists `cani-agent`, `general-purpose`, `Explore`) | Left out of per-card cost |

The fixed set of 15 agent types in `bin/agent-state.sh:107-109` becomes the keys of `models` plus the project's own agents (liveness is prefix-tolerant: `kourai:card-manager` and `card-manager` are the same type).

## Optional agents and their schedules

| Key | Default | RunnerCity | Where today | What it does |
|---|---|---|---|---|
| `agents.workflow_verifier.enabled` | `true` | on | `agents/workflow-verifier.md` | PR checks and drift check |
| `agents.workflow_verifier.every_days` | `7` | same | `bin/board-wait.py:123-125`, `board-watcher.md:23,185`, W77 | Drift check cadence |
| `agents.workflow_verifier.workflow_doc_id` | `""` | `8ced18ad-14e7-4b3e-b9db-ac2182c2c472` | `agents/workflow-verifier.md:15`, W5 | Claude Doc it compares against |
| `agents.token_auditor.enabled` | `true` | on | `agents/token-auditor.md` | Token audit |
| `agents.token_auditor.every_days` | `7` | same | `bin/board-wait.py:123-125`, `token-auditor.md:33,48` | Cadence and window |
| `agents.sentry_triager.enabled` | `false` | on | `agents/sentry-triager.md` | Sentry triage |
| `agents.sentry_triager.every_days` | `1` | same | `bin/board-wait.py:123-125` | Cadence |
| `agents.sentry_triager.org` | `""` | `runnercity-20` | `agents/sentry-triager.md:14` | Sentry org |
| `agents.sentry_triager.projects` | `[]` | `flutter`, `ruby-rails`, `webapp` | same | Sentry projects |
| `agents.sentry_triager.history_days` | `90` | same | `agents/sentry-triager.md:16` | History window |
| `agents.fraud_watcher.enabled` | `false` | on | `agents/fraud-watcher.md` | Money check |
| `agents.fraud_watcher.every_days` | `1` | same | `bin/board-wait.py:123-125` | Cadence |
| `agents.app_builders.enabled` | `false` | on | `agents/android-builder.md`, `ios-builder.md` | Store builds in a release |

No time of day is set anywhere today; schedules are cadences driven by board-wait's deadline wakes.

## Models

Each agent file's `model:` line (line 4) is rendered from these. Project agents add their own keys (`models` is an open table).

| Key | Default | Where today |
|---|---|---|
| `models.board-watcher` | `sonnet` | `agents/board-watcher.md:4` |
| `models.card-manager` | `sonnet` | `agents/card-manager.md:4` |
| `models.feature-tester` | `opus` | `agents/feature-tester.md:4` |
| `models.feature-tester-before` | `sonnet` | R23, W48, `agents/card-manager.md:52` (a trial) |
| `models.test-builder` | `opus` | `agents/test-builder.md:4` |
| `models.merger` | `sonnet` | `agents/merger.md:4` |
| `models.promoter` | `sonnet` | `agents/promoter.md:4` |
| `models.workflow-builder` | `sonnet` | `agents/workflow-builder.md:4` |
| `models.workflow-verifier` | `opus` | `agents/workflow-verifier.md:4` |
| `models.token-auditor` | `sonnet` | `agents/token-auditor.md:4` |
| `models.sentry-triager` | `sonnet` | `agents/sentry-triager.md:4` |
| `models.fraud-watcher` | `sonnet` | `agents/fraud-watcher.md:4` |

RunnerCity's project agents add `mobile-builder = "opus"`, `server-builder = "opus"`, `android-builder = "haiku"`, `ios-builder = "haiku"`. The token audit's price table (`bin/usage/agg.py:22`, `permodel.py:32`) is a fact about models, not a setting, and stays in code.

## Adapter settings (the `adapters` table; nothing reads it yet, see `docs/ADAPTERS.md`)

Stack and infrastructure values move into `[adapters.<name>]` of the same config file, so they too change without a code change. Each adapter documents its own keys. RunnerCity's today:

| Adapter value | RunnerCity | Where today |
|---|---|---|
| Test-host autoscaling group, max size | `runnercity-testhost`, `7` | `bin/test-server.sh:177-178` (env `RC_TEST_ASG`, `RC_TEST_ASG_MAX`) |
| AWS profile and region for agents | `runnercity-agents`, `us-east-2` | `bin/test-server.sh:179-180` |
| Tailscale host user and tag | `root`, `tag:testhost` | `bin/test-server.sh:181-182` |
| Slot host parameter | `/test-host/slots/<n>/HOST` | `bin/test-server.sh:243` |
| Scale-up timeout, retry, poll; host setup; API check | `900`, `300`, `15`, `1200`, `15` seconds | `bin/test-server.sh:183-194` |
| Server names, API and emulator ports | integration `3101`/`5556`; test-server-1..5 `3102`..`3106` / `5558`..`5566`; development emulator `5554` | `bin/test-server.sh:210-237`, `agents/feature-tester.md:110-111` |
| "Taken" server numbers | `1 2 3 4` (fixed; does not follow the server count) | `bin/test-server.sh:465` |
| Test host pool limit | 9 (6 servers and 3 CI jobs) | R11, W64 |
| Gradle builds at once on the Mac | `2` | `agents/android-builder.md:46`, `feature-tester.md:117` |
| Server unit parallel workers | `PARALLEL_WORKERS=1` | `agents/merger.md:44`, `server-builder.md:60,64` |
| CI workflows and runner labels | `integration.yml`, `test.yml`, `deploy_staging.yml`; `[self-hosted, linux, runnercity]` | R173, `agents/merger.md:49`, `promoter.md:93` |
| Staging URL and health path | `https://api-staging.runnercity.xyz`, `/api/v1/status` | `agents/promoter.md:94,106` |
| Development URL agents must not test on | `api-dev.runnercity.xyz` | `agents/feature-tester.md:111` |
| Store lanes and tracks | `fastlane android staging`, `fastlane ios staging`, `promote_beta`; Play internal and Closed beta, TestFlight Closed Beta | `agents/android-builder.md:48`, `ios-builder.md:46`, `promoter.md:110,127,133`, R197 |
| Release notes limit and fallback | `500` characters; `Bug fixes and performance improvements.` | `agents/promoter.md:99` |
| Smoke list | `integration_test/smoke.txt` | R149 |
| Scratch database | `runnercity_scratch_<shortLink>` | `bin/schema-dump.sh:27` |
| Fraud AWS profile, report bucket, Stripe key file | `runnercity-fraud-watcher`, `s3://runnercity-anomaly-reports-production/`, `{state_dir}/fraud-watcher/stripe-key` | `agents/fraud-watcher.md:15-16`, `bin/fraud-stripe.sh:22` |

## Not variables

These stay in code: they are protocol between agents and gates, or facts.

- The comment phrases (`BLOCKED:`, `WAITS FOR:`, `MERGED: <repo>#<n> @ <sha>`, `VERIFIED:`, `FULL SUITE GREEN:`, `GREEN*:`, the ship/hold answer and the rest, R288-357, `bin/board-wait.py:149-153`).
- Title markers (🚨, 🪲, `[AGENTS]`, `⛔ BLOCKED:`) and the PR-line markers.
- Exit codes and verdict words; sha, short-link and card-id formats.
- Trello, GitHub and Stripe API bases and versions.
- Trello read page sizes and output trimming widths in the scripts.
- The `rules-ranges.sh` markers: they are heading names, `[core: <heading>]` and `[project: <heading>]`.
- RunnerCity code conventions in `board/agent-rules.md` (they move to that project's rules).

## Drift found while taking the inventory

Reported, not fixed (kourai copies runner_city as it is):

1. The wait limit is 540 seconds in R21, "about 9 minutes" in W75 and `board-watcher.md:44`, and 530 in every script. The default here is 530, what runs.
2. The full API suite takes "9 to 25 minutes" in `merger.md:76` and W115, "about 9 to 15 minutes" in W96.
3. `bin/test-server.sh:465` checks servers 1 to 4 as taken, whatever the server count.
4. The tracked `hooks/base-push-gate.sh` maps `main` to `shawnlauzon/runner_city`; live hooks use `RunnerCityOrg/runnercity-app`.
5. List id `<id>` is `APPROVED_LIST` in the tracked hooks and `MERGING_LIST` live.
6. The hooks have no overrides at all (board, `trello.env`, member and list ids), while most bin scripts accept env overrides.
7. The 12-hour gap is written in `release-gap.sh:25` and again in the `board-wait.py:39` docstring.

## Added by the script sweep

| Key | Default | RunnerCity | Where today | What it does |
|---|---|---|---|---|
| `paths.project_bin` | `{repos.0.path}/.claude/bin` | same | new | Where `kourai-project` finds the project layer's own scripts |
| `paths.active_card_dir` | `{project.state_dir}/active` | same | `active-card.sh` | Active-card files |
| `paths.board_watch_since` | `{project.state_dir}/board-watch.since` | same | `board-watch.sh` | Since-cursor of the old watch script |
| `paths.agent_state_cache` | `{project.state_dir}/agent-state-cache` | same | `agent-state.sh` | Transcript scan cache |
| `paths.workflow_checks_cache` | `{project.state_dir}/workflow-checks-cache` | same | `workflow-checks.sh` | Check cache |
| `paths.ci_unstick_dir` | `{project.state_dir}/ci-unstick` | same | `ci-wait.sh` | ci-unstick marks |
| `board.workspace_id` | `""` | the board's workspace | `card-summary.sh`, `standing-card.sh` | Trello workspace id |
| `board.members.internal` | `[]` | the team's member ids | `merged-cards.sh` | Members whose cards are not a reporter's |
| `board.labels.waiting_resource` | `""` | the label | `board-wait.py` | Waiting-on-a-resource label |
| `agents.plugin` | the nine plugin agents | same | new | Agents started as `kourai:<name>` |
| `agents.project` | `[]` | the project agents | new | Agents started by bare name |
| `paths.disk_folders` | `~/.gradle` | `~/.gradle`, the agents' temp folder | `board-wait.py` | Folders board-wait offers to clean |
| `liveness.worktree_roles` | the five builder/tester roles | same | `board-wait.py` | Roles whose worktree folders board-wait cleans |
