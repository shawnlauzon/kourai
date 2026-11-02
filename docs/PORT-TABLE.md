# Port table

Every path under `.claude/{agents,commands,bin,hooks,board,skills}` of runner_city main `22fe69b5` and where it goes (plan K0). `moves` = into kourai; `stays` = the RunnerCity layer (the `kourai-switch` branch); `both` = kourai ships a config-driven copy and RunnerCity keeps its own; `retired` = not ported. Generated files (the installed hook copies, the per-installation marketplace, `kourai.toml`) are made by the installer and are in no repo.

| Path | What | Goes to | Note |
|---|---|---|---|
| `.claude/agents/android-builder.md` | stays |  | project agent; workflow-script paths rewritten to bare names or kourai-project |
| `.claude/agents/board-watcher.md` | moves | `agents/board-watcher.md` | prose swept, markers by file |
| `.claude/agents/card-manager.md` | moves | `agents/card-manager.md` | prose swept, markers by file |
| `.claude/agents/code-reviewer.md` | moves | `agents/code-reviewer.md` | prose swept, markers by file |
| `.claude/agents/feature-tester.md` | stays |  | project agent; workflow-script paths rewritten to bare names or kourai-project |
| `.claude/agents/fraud-watcher.md` | stays |  | project agent; workflow-script paths rewritten to bare names or kourai-project |
| `.claude/agents/integration-tester.md` | retired |  | not ported (retired agent) |
| `.claude/agents/ios-builder.md` | stays |  | project agent; workflow-script paths rewritten to bare names or kourai-project |
| `.claude/agents/merger.md` | moves | `agents/merger.md` | prose swept, markers by file |
| `.claude/agents/mobile-builder.md` | stays |  | project agent; workflow-script paths rewritten to bare names or kourai-project |
| `.claude/agents/project-manager.md` | retired |  | not ported (retired agent) |
| `.claude/agents/promoter.md` | stays |  | project agent; workflow-script paths rewritten to bare names or kourai-project |
| `.claude/agents/sentry-triager.md` | moves | `agents/sentry-triager.md` | prose swept, markers by file |
| `.claude/agents/server-builder.md` | stays |  | project agent; workflow-script paths rewritten to bare names or kourai-project |
| `.claude/agents/test-builder.md` | stays |  | project agent; workflow-script paths rewritten to bare names or kourai-project |
| `.claude/agents/time-optimizer.md` | moves | `agents/time-optimizer.md` | prose swept, markers by file |
| `.claude/agents/token-auditor.md` | moves | `agents/token-auditor.md` | prose swept, markers by file |
| `.claude/agents/workflow-builder.md` | moves | `agents/workflow-builder.md` | prose swept, markers by file |
| `.claude/agents/workflow-verifier.md` | moves | `agents/workflow-verifier.md` | prose swept, markers by file |
| `.claude/bin/active-card.sh` | moves | `bin/active-card.sh` | swept |
| `.claude/bin/agent-phrases.txt` | moves | `bin/agent-phrases.txt` | read by board-wait.py and card-summary.sh next to themselves |
| `.claude/bin/agent-state.sh` | moves | `bin/agent-state.sh` | swept |
| `.claude/bin/agent-worktree.sh` | moves | `bin/agent-worktree.sh` | swept |
| `.claude/bin/agents-status.sh` | moves | `bin/agents-status.sh` | swept |
| `.claude/bin/apply-settings-section.sh` | stays |  |  |
| `.claude/bin/as-claude.sh` | both | `bin/as-claude.sh` | kourai ships a config-driven copy; RunnerCity keeps its own because tool/ and the server call it by path |
| `.claude/bin/board-snapshot.sh` | moves | `bin/board-snapshot.sh` | swept |
| `.claude/bin/board-wait.py` | moves | `bin/board-wait.py` | swept |
| `.claude/bin/board-wait.sh` | moves | `bin/board-wait.sh` | swept |
| `.claude/bin/board-watch.sh` | moves | `bin/board-watch.sh` | swept |
| `.claude/bin/builder-trial.sh` | stays |  |  |
| `.claude/bin/card-kind.sh` | moves | `bin/card-kind.sh` | swept |
| `.claude/bin/card-summary.sh` | moves | `bin/card-summary.sh` | swept |
| `.claude/bin/card-test-server.sh` | stays |  |  |
| `.claude/bin/ci-unstick.py` | stays |  |  |
| `.claude/bin/ci-unstick.sh` | stays |  |  |
| `.claude/bin/ci-wait.sh` | moves | `bin/ci-wait.sh` | swept |
| `.claude/bin/code-review-check.sh` | moves | `bin/code-review-check.sh` | swept |
| `.claude/bin/code-review-wait.sh` | moves | `bin/code-review-wait.sh` | swept |
| `.claude/bin/decisions-index.sh` | moves | `bin/decisions-index.sh` | swept |
| `.claude/bin/dev-merge-lock.sh` | moves | `bin/dev-merge-lock.sh` | swept |
| `.claude/bin/fixtures/hooks-before-section-19/base-push-gate.sh` | stays |  | fixtures of the section 19 tests |
| `.claude/bin/fixtures/hooks-before-section-19/merge-gate.sh` | stays |  | fixtures of the section 19 tests |
| `.claude/bin/fixtures/hooks-before-section-19/merged-comment-gate.sh` | stays |  | fixtures of the section 19 tests |
| `.claude/bin/fixtures/hooks-before-section-19/review-policy.sh` | stays |  | fixtures of the section 19 tests |
| `.claude/bin/fixtures/hooks-before-section-19/staging-gate.sh` | stays |  | fixtures of the section 19 tests |
| `.claude/bin/fixtures/settings-before-section-19.json` | stays |  | fixtures of the section 19 tests |
| `.claude/bin/fraud-stripe.sh` | stays |  |  |
| `.claude/bin/ft-prepare.sh` | stays |  |  |
| `.claude/bin/ft-report.sh` | stays |  |  |
| `.claude/bin/gh-app-token.sh` | moves | `bin/gh-app-token.sh` | swept |
| `.claude/bin/heartbeat.sh` | both | `bin/heartbeat.sh` | kourai ships a config-driven copy; RunnerCity keeps its own because tool/ and the server call it by path |
| `.claude/bin/merged-cards.sh` | moves | `bin/merged-cards.sh` | swept |
| `.claude/bin/pause-lib.sh` | both | `bin/pause-lib.sh` | kourai ships a config-driven copy; RunnerCity keeps its own because tool/ and the server call it by path |
| `.claude/bin/pr-conflicts.sh` | moves | `bin/pr-conflicts.sh` | swept |
| `.claude/bin/pr-ready.sh` | moves | `bin/pr-ready.sh` | swept |
| `.claude/bin/release-gap.sh` | moves | `bin/release-gap.sh` | swept |
| `.claude/bin/remerge-check.py` | moves | `bin/remerge-check.py` | swept |
| `.claude/bin/remerge-check.sh` | moves | `bin/remerge-check.sh` | swept |
| `.claude/bin/rules-ranges.sh` | moves | `bin/rules-ranges.sh` | swept |
| `.claude/bin/run-bg.sh` | moves | `bin/run-bg.sh` | swept |
| `.claude/bin/run-locked.sh` | moves | `bin/run-locked.sh` | swept |
| `.claude/bin/run-wait.sh` | moves | `bin/run-wait.sh` | swept |
| `.claude/bin/schema-dump.sh` | stays |  |  |
| `.claude/bin/server-probe.sh` | stays |  |  |
| `.claude/bin/staging-smoke.sh` | stays |  |  |
| `.claude/bin/standing-card.sh` | moves | `bin/standing-card.sh` | swept |
| `.claude/bin/test-agent-state.sh` | moves | `tests/test-agent-state.sh` | ported with fixture config (K7) |
| `.claude/bin/test-agents-status.sh` | moves | `tests/test-agents-status.sh` | ported with fixture config (K7) |
| `.claude/bin/test-app-visible-policy.sh` | moves | `tests/test-app-visible-policy.sh` | ported with fixture config (K7) |
| `.claude/bin/test-board-content.sh` | moves | `tests/test-board-content.sh` | ported with fixture config (K7) |
| `.claude/bin/test-board-scripts.sh` | moves | `tests/test-board-scripts.sh` | ported with fixture config (K7) |
| `.claude/bin/test-board-wait.sh` | moves | `tests/test-board-wait.sh` | ported with fixture config (K7) |
| `.claude/bin/test-builder-trial.sh` | stays |  | test of a staying script |
| `.claude/bin/test-cardtimes.sh` | moves | `tests/test-cardtimes.sh` | ported with fixture config (K7) |
| `.claude/bin/test-ci-unstick.sh` | stays |  | test of a staying script |
| `.claude/bin/test-code-review-check.sh` | moves | `tests/test-code-review-check.sh` | ported with fixture config (K7) |
| `.claude/bin/test-code-review-wait.sh` | moves | `tests/test-code-review-wait.sh` | ported with fixture config (K7) |
| `.claude/bin/test-decisions-index.sh` | moves | `tests/test-decisions-index.sh` | ported with fixture config (K7) |
| `.claude/bin/test-emulator-boot.sh` | stays |  | test of a staying script |
| `.claude/bin/test-ft-scripts.sh` | stays |  | test of a staying script |
| `.claude/bin/test-gh-app-token.sh` | moves | `tests/test-gh-app-token.sh` | ported with fixture config (K7) |
| `.claude/bin/test-hook-trello-retry.sh` | moves | `tests/test-hook-trello-retry.sh` | ported with fixture config (K7) |
| `.claude/bin/test-merge-gate-screenshots.sh` | moves | `tests/test-merge-gate-screenshots.sh` | ported with fixture config (K7) |
| `.claude/bin/test-merge-gate-short-form.sh` | moves | `tests/test-merge-gate-short-form.sh` | ported with fixture config (K7) |
| `.claude/bin/test-merged-comment-gate-short-form.sh` | moves | `tests/test-merged-comment-gate-short-form.sh` | ported with fixture config (K7) |
| `.claude/bin/test-read-helpers.sh` | moves | `tests/test-read-helpers.sh` | ported with fixture config (K7) |
| `.claude/bin/test-release-gap.sh` | moves | `tests/test-release-gap.sh` | ported with fixture config (K7) |
| `.claude/bin/test-remerge-approval.sh` | moves | `tests/test-remerge-approval.sh` | ported with fixture config (K7) |
| `.claude/bin/test-remerge-check.sh` | moves | `tests/test-remerge-check.sh` | ported with fixture config (K7) |
| `.claude/bin/test-rules-ranges.sh` | moves | `tests/test-rules-ranges.sh` | ported with fixture config (K7) |
| `.claude/bin/test-run-folders.sh` | moves | `tests/test-run-folders.sh` | ported with fixture config (K7) |
| `.claude/bin/test-section-19-hooks.sh` | stays |  | test of a staying script |
| `.claude/bin/test-server-probe.sh` | stays |  | test of a staying script |
| `.claude/bin/test-server.sh` | stays |  | test of a staying script |
| `.claude/bin/test-settings-section-19.sh` | stays |  | test of a staying script |
| `.claude/bin/test-setup-helpers.sh` | moves | `tests/test-setup-helpers.sh` | ported with fixture config (K7) |
| `.claude/bin/test-staging-smoke.sh` | stays |  | test of a staying script |
| `.claude/bin/test-standing-card.sh` | moves | `tests/test-standing-card.sh` | ported with fixture config (K7) |
| `.claude/bin/test-timereads.sh` | moves | `tests/test-timereads.sh` | ported with fixture config (K7) |
| `.claude/bin/test-ui-test-hang.sh` | stays |  | test of a staying script |
| `.claude/bin/test-ui-test-launch.sh` | stays |  | test of a staying script |
| `.claude/bin/test-ui-test-package-service.sh` | stays |  | test of a staying script |
| `.claude/bin/test-urgent-hold.sh` | moves | `tests/test-urgent-hold.sh` | ported with fixture config (K7) |
| `.claude/bin/test-usage-cost.sh` | moves | `tests/test-usage-cost.sh` | ported with fixture config (K7) |
| `.claude/bin/test-verified-carry.sh` | moves | `tests/test-verified-carry.sh` | ported with fixture config (K7) |
| `.claude/bin/test-wait-helpers.sh` | moves | `tests/test-wait-helpers.sh` | ported with fixture config (K7) |
| `.claude/bin/test-watch-results.sh` | moves | `tests/test-watch-results.sh` | ported with fixture config (K7) |
| `.claude/bin/test-watcher-reload.sh` | moves | `tests/test-watcher-reload.sh` | ported with fixture config (K7) |
| `.claude/bin/test-workflow-checks.sh` | moves | `tests/test-workflow-checks.sh` | ported with fixture config (K7) |
| `.claude/bin/test-zero-file-pr.sh` | moves | `tests/test-zero-file-pr.sh` | ported with fixture config (K7) |
| `.claude/bin/urgent-hold.sh` | moves | `bin/urgent-hold.sh` | swept |
| `.claude/bin/usage/agg.py` | moves | `bin/usage/agg.py` |  |
| `.claude/bin/usage/cardtimes.py` | moves | `bin/usage/cardtimes.py` |  |
| `.claude/bin/usage/cmwake.py` | moves | `bin/usage/cmwake.py` |  |
| `.claude/bin/usage/cost.py` | moves | `bin/usage/cost.py` |  |
| `.claude/bin/usage/excess.py` | moves | `bin/usage/excess.py` |  |
| `.claude/bin/usage/first.py` | moves | `bin/usage/first.py` |  |
| `.claude/bin/usage/gaps.py` | moves | `bin/usage/gaps.py` |  |
| `.claude/bin/usage/noop.py` | moves | `bin/usage/noop.py` |  |
| `.claude/bin/usage/permodel.py` | moves | `bin/usage/permodel.py` |  |
| `.claude/bin/usage/reqcat.py` | moves | `bin/usage/reqcat.py` |  |
| `.claude/bin/usage/rules.py` | moves | `bin/usage/rules.py` |  |
| `.claude/bin/usage/timereads.py` | moves | `bin/usage/timereads.py` |  |
| `.claude/bin/usage/tokens.py` | moves | `bin/usage/tokens.py` |  |
| `.claude/bin/usage/toolout.py` | moves | `bin/usage/toolout.py` |  |
| `.claude/bin/verified-carry.sh` | moves | `bin/verified-carry.sh` | swept |
| `.claude/bin/verify/refusal_scan.py` | moves | `bin/verify/refusal_scan.py` |  |
| `.claude/bin/verify/test-refusal-scan.sh` | moves | `bin/verify/test-refusal-scan.sh` |  |
| `.claude/bin/watcher-reload.sh` | moves | `bin/watcher-reload.sh` | swept |
| `.claude/bin/workflow-checks.sh` | moves | `bin/workflow-checks.sh` | swept |
| `.claude/board/WORKFLOW.md` | stays |  | pointer to kourai plus one decisions file |
| `.claude/board/agent-rules.md` | stays |  | RunnerCity code conventions |
| `.claude/board/decisions-log.md` | stays |  | closed history |
| `.claude/board/decisions/2026-10-17-vxH50GCK.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-18-496Pj8NM.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-18-4c7e6CKa.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-18-4v8Bu0t0.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-18-8gdVEilT.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-18-APdmmy6U.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-18-N7IHnW9T.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-18-YypeUgvL.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-18-ZQGivsh3.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-18-b0nDvYXt.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-18-dJs8XMNx.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-18-hTyBAdDh.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-18-jbhFp2CH.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-18-lz3m0kLq.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-18-mWg2nZnw.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-18-oNbCnvC3.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-18-qh16Livk.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-18-sinK9XzX.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-18-tdqpCHDJ.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-18-vthc1NyR.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-18-x1xaWJMi.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-19-1JaJ3Imh.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-19-7LcHfGu5.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-19-Ci50PVPJ.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-19-O6PJ58xL.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-19-PCy4I5Oe.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-19-WTdqr2dy.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-19-XIJxta12.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-19-izrjFWLu.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-19-qtMtmwQe.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-19-sIH6mqGF.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-19-sYH8NCtC.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-19-xUEx4rdv.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-20-pXUj5UEA.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-21-CEgF3XU4.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-21-J5726Go0.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-22-6U8HrveL.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-22-UD2L732X.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-22-iRazJpGZ.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-23-3JIEhgFL.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-23-4xykvASo.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-23-9nGTzwPf.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-23-V2DWqki2.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-23-bdw5I00z.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-23-lAnGhQv5.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-26-LLmoMGID.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-27-VUJggOkg.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-27-dApvrFkP.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-27-pHMNmeq0.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-28-57O5oWD0.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-28-HWd2DhDL.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-28-PJwb2r5G.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-28-YIkKHMzF.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-29-l6vf0GGC.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-29-rigTiU5N.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-30-CSyAbSsC.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-10-30-egTvjp80.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-11-01-EUvQUP4d.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-11-01-z06G73J1.md` | stays |  | user decisions |
| `.claude/board/decisions/2026-11-01-zE1yLOpq.md` | stays |  | user decisions |
| `.claude/board/phrases.txt` | moves | `rules/phrases.txt` | paths rewritten; project: files checked in the project layer |
| `.claude/board/release-foundation-globs.txt` | stays |  | RunnerCity release data |
| `.claude/board/rules.md` | moves | `rules/core.md (+ project rules stay)` | split: core / Settings, Tests, Releasing, Test servers project |
| `.claude/board/user-setup-changes.md` | stays |  | settings sections are the project's |
| `.claude/commands/run-board.md` | moves | `commands/run-board.md` | started as /kourai:run-board |
| `.claude/hooks/merge-gate.sh` | moves | `hooks/merge-gate.sh` | source copy; the installer registers a hash-checked copy |
| `.claude/hooks/merged-comment-gate.sh` | moves | `hooks/merged-comment-gate.sh` | source copy; the installer registers a hash-checked copy |
| `.claude/hooks/review-policy.sh` | moves | `hooks/review-policy.sh` | source copy; the installer registers a hash-checked copy |
| `.claude/hooks/staging-gate.sh` | moves | `hooks/staging-gate.sh` | source copy; the installer registers a hash-checked copy |
| `.claude/skills/new-feature/SKILL.md` | stays |  | the new-feature skill is the project's |
