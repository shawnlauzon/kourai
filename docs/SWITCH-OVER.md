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
   `<state_dir>/kourai.toml`, outside git. Check it with `kourai-config check`.
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
6. **Fast-forward the main checkout** (`git -C <checkout> merge --ff-only origin/main`), then delete
   the hold file.
7. **Start the board.** In a new Claude Code session in the project, run `/kourai:run-board`. Watch the
   first pass attended: the watcher must report its agents with the `kourai:` prefix and list nothing it
   cannot start.
8. **Prove the gates fire.** For each registered gate, run its registered command with a payload that
   must be refused, and expect a reply containing `"permissionDecision": "deny"`:
   - merge-gate: tool Bash, command `gh pr merge 999999 --repo <repo slug> --merge` (no head commit);
   - staging-gate: tool Bash, a push of the all-zero sha to `refs/heads/staging` of the server repo,
     written exactly as the gate's header describes (`<sha>:refs/heads/staging`);
   - merged-comment-gate: tool `mcp__trello__trelloWriteCard`, a comment `MERGED: <repo slug>#999999 @ 0000000`.
   Then `kourai-install prove`. Any gate that allows these is a stop: roll back.
9. **Remove the old gate registrations** in the project settings (the ones that point at the repo's
   `.claude/hooks/`) once step 8 passed, and delete those files in a normal card.

## Rolling back

In reverse, and each step on its own: put the old registrations back (they are in the backup folder
`<state_dir>/kourai/backups/<timestamp>/`), `installer/kourai-install --config <state_dir>/kourai.toml rollback`,
stop the board, revert the switch commit on runner_city `main` with `Watcher: restart` in the revert,
fast-forward the checkout, restart `/run-board`. Rollback needs no network.

## Follow-ups after the switch

- A per-poll gate-drift check in `board-wait` (today only `kourai-install check` and `kourai-hook` check the hashes).
- Keep `kourai-switch` and `docs/SYNC.md` current for as long as RunnerCity's own workflow changes keep merging.
- Decide where kourai's tests run (no CI today) and set tag protection on `kourai--v*`.
