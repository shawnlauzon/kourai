# <project>: project rules

Copy this file to your project, set `project.rules_file` in your config (docs/CONFIG.md) to its path, and fill it in. The board's shared rules are kourai's `rules/core.md`; this file holds what only your project decides.

Agents read the parts below by their heading (`[project: Project settings]`, `[project: Tests]`, `[project: Releasing]`, `[project: Test servers]`), so keep these four headings, in this order, and keep every heading free of " to " and "]". `rules-ranges.sh check` fails when one is missing. Add your own `## ` parts after them; an agent file of yours can name them in a `[project: <heading>]` marker.

The roles that read **Project settings** (a setting named in the core rules is looked up here by its name): the board watcher, workflow builder, workflow verifier and promoter read this file whole; card manager, merger, code reviewer, time optimizer, token auditor and Sentry triager read the Project settings part. Whatever a role needs to know before it acts on a setting belongs in the table, not in your agent files.

## Project settings

| Setting | Value |
|---|---|
| Card test servers | <how many, and what a card gets> |
| CI jobs at once | <number, and how many are kept for the merger> |
| Release due | <when merged cards make a release due> |
| Failures before QUESTIONS | <number of `TEST FAILED:` comments on a card before it goes to QUESTIONS> |
| Releases at once | <number> |
| Gap between releases | <hours> |
| Urgent fix deadline | <hours from a urgent card's filing to its fix> |
| Context ceiling | <tokens in an agent's latest request> |
| Code review | <the review depth, and the rounds before QUESTIONS> |
| Wake re-arm | <minutes> |
| Idle agent | <minutes without a transcript write before `STUCK:`> |
| Wait limit | <seconds a foreground wait may last> |

## Tests

<The buckets your cards and releases run (unit, API, UI, smoke, ...), who runs each, the commands, and what a failure means. The core rules refer to a bucket by the name you give it here.>

## Releasing

<How a release is cut: what makes one due, the steps (pin, full test, deploy, tag, smoke, promotion), and who does each. If the project has no release step, say so in one line.>

## Test servers

<The servers a card test borrows, how one is brought up and taken down, and what a lost host means. If the project has none, say so in one line.>
