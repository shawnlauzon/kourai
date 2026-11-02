#!/usr/bin/env bash
# Makes or refreshes an agent's own worktree in one command, so agents need no
# setup blocks with loops and chains (rules.md, Run commands plainly).
#
# Usage: agent-worktree.sh <agent> <shortLink | -> <mobile | server>
# (the promoter also: `promoter 2 mobile`, its second mobile worktree `promoter-2`, for the culprit search's second state)
#
# The worktree is <repo>/.claude/worktrees/<agent>-<shortLink> (a card's), or
# <repo>/.claude/worktrees/<agent> with "-" (the merger's and the promoter's role
# worktrees). It fetches origin and, when the worktree is missing, adds it
# detached at the repo's base. What each agent gets comes from the repo's config table
# (repos.<id>): worktree_env_placeholders (empty files, for the roles in
# worktree_env_placeholder_roles), worktree_env_links (symlinks to the main checkout's files
# when they exist, for the roles in worktree_env_link_roles; never copies), worktree_git_exclude
# (puts `.claude/worktrees/` in the repo's .git/info/exclude) and deps_commands (run in the
# worktree). A role in neither role list has no worktree there (exit 2). `app` is accepted for
# `mobile`. A worktree that exists is left on whatever it has checked out; only the env files
# and dependencies are refreshed. It never prints an env file.
# Prints `WORKTREE: <path>` last. Exit 0; 1 a git or install step failed; 2 usage.
# Overrides (tests): RC_MOBILE_ROOT, RC_SERVER_ROOT, RC_SKIP_DEPS=1.
set -u -o pipefail
. "$(dirname "${BASH_SOURCE[0]}")/kourai-env.sh"

usage() { echo "usage: agent-worktree.sh <agent> <shortLink|-> <mobile|server> (the promoter also: promoter 2 mobile)" >&2; exit 2; }
[ $# -eq 3 ] || usage
agent=$1 card=$2 repo=$3
[ "$repo" = app ] && repo=mobile  # `app` is the config name of the mobile repo (repos.app)
[ "$card" = - ] || [[ "$card" =~ ^[A-Za-z0-9]{8}$ ]] || { [ "$agent:$card:$repo" = promoter:2:mobile ] || usage; }

rid=$repo; [ "$repo" = mobile ] && rid=app   # the config ids: app and server
rk() { kourai-config json repos | jq -r --arg r "$rid" --arg k "$1" '[.[] | select(.id == $r)] | first | .[$k] // [] | if type == "array" then .[] else . end'; }
in_roles() { rk "$1" | grep -qxF -- "$agent"; }
placeholder=0 links=0
in_roles worktree_env_placeholder_roles && placeholder=1
in_roles worktree_env_link_roles && links=1
if [ "$placeholder" = 0 ] && [ "$links" = 0 ]; then
  echo "agent-worktree: $agent has no $repo worktree" >&2; exit 2
fi

top=$(kc "repos.$rid.path") base=origin/$(kc "repos.$rid.base")
[ "$rid" = app ] && top=${RC_MOBILE_ROOT:-$top}
[ "$rid" = server ] && top=${RC_SERVER_ROOT:-$top}
# The promoter's culprit search runs two states at once on two servers: `promoter 2 mobile` makes its second
# mobile worktree, `.claude/worktrees/promoter-2`.
if [ "$card" = - ]; then name=$agent; else name=$agent-$card; fi
wt=$top/.claude/worktrees/$name

git -C "$top" fetch -q origin || { echo "agent-worktree: git fetch failed in $top" >&2; exit 1; }
if [ "$(rk worktree_git_exclude)" = true ]; then
  exclude=$(git -C "$top" rev-parse --git-path info/exclude)
  case "$exclude" in /*) ;; *) exclude=$top/$exclude ;; esac
  mkdir -p "$(dirname "$exclude")"
  grep -qx '.claude/worktrees/' "$exclude" 2>/dev/null || echo '.claude/worktrees/' >>"$exclude"
fi
if [ ! -d "$wt" ]; then
  git -C "$top" worktree add -q --detach "$wt" "$base" || { echo "agent-worktree: git worktree add failed" >&2; exit 1; }
fi

if [ "$placeholder" = 1 ]; then
  while IFS= read -r f; do
    [ -n "$f" ] && { [ -e "$wt/$f" ] || : >"$wt/$f"; }
  done < <(rk worktree_env_placeholders)
fi
if [ "$links" = 1 ]; then
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$top/$f" ] && ln -sfn "$top/$f" "$wt/$f"
  done < <(rk worktree_env_links)
fi

if [ "${RC_SKIP_DEPS:-0}" != 1 ]; then
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    (cd "$wt" && bash -c "$c" >/dev/null) || { echo "agent-worktree: '$c' failed" >&2; exit 1; }
  done < <(rk deps_commands)
fi
echo "WORKTREE: $wt"
