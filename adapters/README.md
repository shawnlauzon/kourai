# Adapters

kourai talks to Trello (the board), GitHub (code, PRs, CI) and a pair of Claude Code
runtimes. Today each of those is a set of scripts under `bin/` that read their
settings from the config. There is no adapter implementation yet: this folder marks
the seam, and `docs/ADAPTERS.md` says where it runs and what a second tracker or
host would have to provide.

A change that adds an adapter puts its code here, one folder per adapter, each with
its own tests under `tests/`.

What a project has to supply to use kourai at all (the project agents, the project scripts the plugin
calls, `agent-rules.md`) is in `docs/ADAPTERS.md`, "What a project must supply".
