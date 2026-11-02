#!/bin/bash
# Runs one command as the installation's GitHub App (github.bot_name). Every GitHub write an
# agent makes goes through it (pushes, PRs, PR comments and edits, merges,
# workflow dispatch / rerun / cancel), so it shows as <bot name>[bot],
# never as the user.
#
#   as-claude.sh <owner/repo> git push -u origin <branch>
#   as-claude.sh <owner/repo> gh pr create --repo <owner/repo> ...
#
# Sets GH_TOKEN (used by gh) and points git's credential helper at gh for this
# command only. The token lasts an hour and is never printed. Whoever runs
# `gh pr merge` (the merger), the merge-gate hook checks the merge: the review
# policy, and a VERIFIED: for the PR's head on an [AGENTS] card.
set -euo pipefail
repo=${1:?usage: as-claude.sh <owner/repo> <command...>}
shift
GH_TOKEN=$("$(dirname "$0")/gh-app-token.sh" "$repo")
export GH_TOKEN
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
export GIT_CONFIG_KEY_1=credential.helper GIT_CONFIG_VALUE_1='!gh auth git-credential'
exec "$@"
