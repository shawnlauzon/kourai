# Switching RunnerCity onto kourai

A runbook for the user, to run attended, one step at a time. Nothing in it is done by an agent
except where it says so. RunnerCity keeps running on its own `.claude/` copy until step 6; every
step before that can be stopped and undone.

The RunnerCity half lives on the branch `kourai-switch` of `RunnerCityOrg/runnercity-app` (never
merged until step 5): the project rules file, the project agents, the staying scripts, the example
config `config/runnercity.example.toml`, and `CLAUDE.md`. Keep `docs/SYNC.md` current: its port table
must have no open row before you start.

## Before you start

- The kourai pull request is approved and merged, and the release is tagged `kourai--v0.1.0-rc1`
  (the tag needs your approval too).
- `kourai-switch` contains the latest runner_city `main`
  (`git merge origin/main` on it; it is never rebased) and `tests/run.sh` is green on both repos.
- `tests/prove-real-agent.sh` printed PROVEN for all three pieces. If one printed UNPROVEN, read its
  line and stop here: the piece is a precondition. In particular, if the plugin's `bin/` is not on a
  project agent's PATH there is no fallback, and this runbook stops at step 1.
- You have time for the whole sequence, about an hour.

## Steps

1. **Drain.** Let the cards in flight finish or reach a safe stop, with no `[AGENTS]` PR open. Check
   nothing runs: `agent-state.sh` prints no live agent. Do not start anything new.
2. **Hold the main checkout.** Stop the board watcher. Then write the hold file by hand so the slow
   check does not fast-forward the live checkout while you work: `<state_dir>/main-checkout-hold`
   (any text, naming why). The live hooks and scripts stay as they are.
3. **Write the config.** Copy `config/runnercity.example.toml` from `kourai-switch` to
   `<state_dir>/kourai.toml`, outside git. Check it with `<release checkout>/bin/kourai-config check`
   (`kourai-config` is not on PATH before the install). `kourai-install check` flags a config changed since
   the apply (`CONFIG DRIFT`), because the config decides the gates; keep the file out of reach of agents.
4. **Plan and apply.** From a release checkout of the tag:
   `installer/kourai-install --config <state_dir>/kourai.toml plan`. Read the plan file (the hooks diff
   and the settings diff first). Then you run `apply`; it copies the hooks first. It adds the plugin and
   rewrites only the marked keys, and it refuses while any agent runs. Run `check`; the new gates are
   registered next to the old ones. Do not remove the old registrations yet.
5. **Merge the switch (the main session, attended; the watcher is stopped, so nothing else moves the card).**
   The main session opens a pull request from `kourai-switch` into runner_city `main` through
   `as-claude.sh RunnerCityOrg/runnercity-app` (`gh api` `POST repos/RunnerCityOrg/runnercity-app/pulls`), puts it
   on the switch-over card (`PR:`, then `AWAITING VERIFIED:`), and starts the workflow verifier and an
   independent reviewer by hand, as the watcher would. `workflow-checks.sh` must print 0 FAIL on the branch
   (precondition; see the branch's `.claude/bin/workflow-checks.sh`). The review policy sends it to REVIEW:
   you approve on GitHub at the head the main session names. The main session first writes the merge message
   to a file in the state folder (a first line, a blank line, then the two trailer lines `Watcher: restart`
   and `Main checkout: hold` on lines of their own), then merges it, still by hand:
   `as-claude.sh RunnerCityOrg/runnercity-app gh pr merge <n> --repo RunnerCityOrg/runnercity-app --merge --match-head-commit <sha> --body-file <that file>`
   (the merge gate refuses a command with a newline in it, so the message never goes in `--body`; a default
   merge message would not carry the trailers). Nobody else merges it.
   Between step 4 (the installer's apply) and step 7 the auto-mode rules still describe the old layout, so an
   attended start of a `kourai:` agent (the verifier, the reviewer) may ask for permission: allow it by hand.
6. **Fast-forward the main checkout** (`git -C <checkout> merge --ff-only origin/main`), then delete
   the hold file.
7. **Rewrite the auto-mode rules (before the board starts).** The classifier reads the rules in
   `~/.claude/settings.json`, and they still name the old layout: `runner_city/.claude/bin/` scripts,
   unprefixed agents ("only for agents defined in runner_city/.claude/agents/"), the verifier's refusal scan
   at the old path. The switch carries a settings section for them (section 52 of
   `.claude/board/user-setup-changes.md` in runner_city). Run, from the fast-forwarded main checkout,
   `.claude/bin/apply-settings-section.sh 52`, then check:
   - `.claude/bin/apply-settings-section.sh 52 --check` exits 0;
   - `grep -c 'runner_city/.claude/bin' ~/.claude/settings.json` prints 0 (an old path left means a rule was
     missed or edited since: the apply names it);
   - `grep -c 'kourai:workflow-builder' ~/.claude/settings.json` prints more than 0;
   - `grep -c 'plugin-root)/bin/verify/refusal_scan.py' ~/.claude/settings.json` prints 1.
   Do not start the board before these pass: an agent start by a `kourai:` name or a `kourai-project` call is
   otherwise judged by rules that describe the old layout. The script backs up the file first
   (`settings.json.bak-<date>-s52`); `kourai-install rollback` restores the file from its own backup taken at the apply (before this step), which holds the old rules (see Rolling back, step 5).
8. **Start the board.** In a new Claude Code session in the project, run `/kourai:run-board`. Watch the
   first pass attended: the watcher must report its agents with the `kourai:` prefix and list nothing it
   cannot start.
9. **Prove the gates fire.** For each registered gate, run its registered command with a payload that
   must be refused, and expect a reply containing `"permissionDecision": "deny"`:
   - merge-gate: tool Bash, command `gh pr merge 999999 --repo <repo slug> --merge` (no head commit);
   - staging-gate: tool Bash, a push of the all-zero sha to `refs/heads/staging` of the server repo,
     written exactly as the gate's header describes (`<sha>:refs/heads/staging`);
   - merged-comment-gate: tool `mcp__trello__trelloWriteCard`, a comment `MERGED: <repo slug>#999999 @ 0000000`;
   - one payload that reaches the config: `kourai-hook review-policy.sh check <repo slug>#999999` must print
     `ERROR:` (exit 2) after it read `github.user_login` and the repo table, not `needs KOURAI_BIN`.
   Then `kourai-install prove`. Any gate that allows these is a stop: roll back.
10. **Remove the old gate registrations** in the project settings (the ones that point at the repo's
   `.claude/hooks/`) once step 9 passed. The switch merge already deleted those files, so they now guard a
   missing file and do nothing.

## Rolling back

The order matters: **the gates are never off while the board runs.** After the switch merge the repo's
`.claude/hooks/` files are gone, so the old registrations (`[ ! -f <file> ] || bash <file>`) pass everything
until the revert is back in the checkout. Settings are therefore the last thing to roll back, never the first.

1. **Stop the board** (the watcher and every agent; `agent-state.sh` prints no live agent). Nothing starts
   again until step 5. The kourai gates stay registered and keep guarding the main session.
2. **Revert the switch commit on runner_city `main`**: a pull request carrying the revert (the merge message
   has `Watcher: restart`), approved by you on GitHub and merged by the main session as in step 5. This is a
   push, so **it needs the network**. Without the network do not go on: leave the kourai gates registered and
   the board stopped until it is back (never roll back the settings first).
3. **Fast-forward the checkout** (`git -C <checkout> merge --ff-only origin/main`). The old
   `.claude/hooks/*.sh` files are back.
4. **Prove an old gate denies**, as step 9 does for the kourai gates but with the old command
   (`bash <checkout>/.claude/hooks/merge-gate.sh` with the same payload): a reply containing
   `"permissionDecision": "deny"`. If it does not, stop; do not roll back the settings.
5. **Roll back the settings**: put the old registrations back from the backup folder
   `<state_dir>/kourai/backups/<timestamp>/`, then `installer/kourai-install --config <state_dir>/kourai.toml rollback`
   (this step alone needs no network; it restores the whole `~/.claude/settings.json` from the backup, so
   re-apply any unrelated edit made since the apply). Restart `/run-board`.

## Follow-ups after the switch

- A per-poll gate-drift check in `board-wait` (today only `kourai-install check` and `kourai-hook` check the hashes).
- Keep `kourai-switch` and `docs/SYNC.md` current for as long as RunnerCity's own workflow changes keep merging.
- Decide where kourai's tests run (no CI today) and set tag protection on `kourai--v*`.
