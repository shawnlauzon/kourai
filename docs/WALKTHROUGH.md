# A card's life, step by step

An app or server card, from the user's approval to a release. Names are the comment phrases
agents write on the card (`rules/core.md`, "Comment glossary"); the board watcher and the
scripts act on those exact phrases.

1. **PROPOSED to TODO.** You approve a card by moving it. Agents never take from PROPOSED.
2. **TODO to TESTING.** The board watcher takes the top card when a card test server is free
   and starts a card manager for it (one manager per card).
3. **BEFORE.** The card manager starts the feature tester, which writes the card's new UI and API
   tests before any code and runs them: they must fail for the right reason. It posts `BEFORE:`
   (or `BEFORE FIXED:` / `REPRODUCED:` for a bug).
4. **BUILDING.** The card moves to BUILDING and holds no test server. The builders (project
   agents) work in their own worktrees and open PRs. The card manager comments `PR: <url>` and
   the PR line is added to the description. A production-code PR gets a code review
   (`CODE REVIEW:`).
5. **AFTER.** The card goes back to TESTING for the AFTER run on the builders' code, with
   captioned screenshots on the PR.
6. **Review policy.** The policy script decides: a PR that changes what users see goes to REVIEW
   (you approve on GitHub); everything else goes to MERGING.
7. **MERGING.** The merger merges the card when CI and unit tests pass, in the list's top-down
   order. A conflict or a refresh sends a fix to the top card only.
8. **MERGED to RELEASING.** When a release is due, the promoter pins a pair of commits, runs the
   full tests, deploys to staging, tags, smoke-tests and promotes.
9. **DONE.** Released cards land in DONE for you to archive. A card made by someone else waits in
   VERIFY for its reporter's check first.

A workflow card (`[AGENTS]`) takes a different path: PROPOSED to WORKFLOW, a plan round (the
workflow builder posts `PLAN:`, the workflow verifier answers `PLAN AGREED:` or `PLAN CHANGES:`),
the build, `AWAITING VERIFIED:`, then `VERIFIED:`, and MERGING or REVIEW by the review policy.

When something needs you, it is a card in QUESTIONS (a decision) or a card with the Blocked label
and a `WAITS FOR: you: ...` comment (a manual step).
