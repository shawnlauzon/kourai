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
# detached at origin/main (mobile) or origin/development (server). Then:
#   mobile, mobile-builder and merger: empty .env placeholders (unit tests never
#     read them), then flutter pub get;
#   mobile, feature-tester, test-builder and promoter: symlinks to the main
#     checkout's .env (the app reads it) and .env.e2e (the UI test scripts read
#     it), when they exist; never copies, and never .env.development, .env.staging,
#     .env.production or .env.local (nothing they run reads those); then flutter pub get;
#   server (server-builder, test-builder, feature-tester, merger, promoter):
#     `.claude/worktrees/` in the repo's .git/info/exclude, symlinks to
#     .env.development.local and .env.localhost when they exist, then bundle install.
# A worktree that exists is left on whatever it has checked out; only the env
# files and dependencies are refreshed. It never prints an env file.
# Prints `WORKTREE: <path>` last. Exit 0; 1 a git or install step failed; 2 usage.
# Overrides (tests): RC_MOBILE_ROOT, RC_SERVER_ROOT, RC_SKIP_DEPS=1.
set -u -o pipefail
. "$(dirname "${BASH_SOURCE[0]}")/kourai-env.sh"

usage() { echo "usage: agent-worktree.sh <agent> <shortLink|-> <mobile|server> (the promoter also: promoter 2 mobile)" >&2; exit 2; }
[ $# -eq 3 ] || usage
agent=$1 card=$2 repo=$3
[ "$card" = - ] || [[ "$card" =~ ^[A-Za-z0-9]{8}$ ]] || { [ "$agent:$card:$repo" = promoter:2:mobile ] || usage; }

case "$repo:$agent" in
  mobile:mobile-builder|mobile:merger) env_mode=placeholders ;;
  mobile:feature-tester|mobile:test-builder|mobile:promoter) env_mode=links ;;
  server:server-builder|server:test-builder|server:feature-tester|server:merger|server:promoter) env_mode=server ;;
  *) echo "agent-worktree: $agent has no $repo worktree" >&2; exit 2 ;;
esac

if [ "$repo" = mobile ]; then
  top=${RC_MOBILE_ROOT:-$(kc repos.app.path)} base=origin/$(kc repos.app.base)
else
  top=${RC_SERVER_ROOT:-$(kc repos.server.path)} base=origin/$(kc repos.server.base)
fi
# The promoter's culprit search runs two states at once on two servers: `promoter 2 mobile` makes its second
# mobile worktree, `.claude/worktrees/promoter-2`.
if [ "$card" = - ]; then name=$agent; else name=$agent-$card; fi
wt=$top/.claude/worktrees/$name

git -C "$top" fetch -q origin || { echo "agent-worktree: git fetch failed in $top" >&2; exit 1; }
if [ "$env_mode" = server ]; then
  exclude=$(git -C "$top" rev-parse --git-path info/exclude)
  case "$exclude" in /*) ;; *) exclude=$top/$exclude ;; esac
  mkdir -p "$(dirname "$exclude")"
  grep -qx '.claude/worktrees/' "$exclude" 2>/dev/null || echo '.claude/worktrees/' >>"$exclude"
fi
if [ ! -d "$wt" ]; then
  git -C "$top" worktree add -q --detach "$wt" "$base" || { echo "agent-worktree: git worktree add failed" >&2; exit 1; }
fi

case "$env_mode" in
  placeholders)
    for f in .env .env.development .env.staging .env.production .env.local; do
      [ -e "$wt/$f" ] || : >"$wt/$f"
    done ;;
  links)
    for f in .env .env.e2e; do
      [ -f "$top/$f" ] && ln -sfn "$top/$f" "$wt/$f"
    done ;;
  server)
    for f in .env.development.local .env.localhost; do
      [ -f "$top/$f" ] && ln -sfn "$top/$f" "$wt/$f"
    done ;;
esac

if [ "${RC_SKIP_DEPS:-0}" != 1 ]; then
  if [ "$repo" = mobile ]; then
    (cd "$wt" && flutter pub get >/dev/null) || { echo "agent-worktree: flutter pub get failed" >&2; exit 1; }
  else
    (cd "$wt" && bundle install --quiet) || { echo "agent-worktree: bundle install failed" >&2; exit 1; }
  fi
fi
echo "WORKTREE: $wt"
