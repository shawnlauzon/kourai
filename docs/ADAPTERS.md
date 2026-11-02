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

## Rule for adding one

Code goes in `adapters/<name>/`, with its tests under `tests/`; the agents change only where they
name the old tool. Anything touching `hooks/`, `installer/` or the identity script needs the
user's review.
