#!/bin/bash
# Proves that a merge of the base into a card branch (a conflict fix or a
# refresh) dropped nothing from either side. Reads only the local git repo of
# the current directory, or the one -C names; no network. See remerge-check.py
# for the rules.
#
# Usage:
#   remerge-check.sh [-C <repo>] <merge commit>
#       Check one merge (parent 1: the branch before, parent 2: the base).
#       The builder runs it on its merge commit before pushing.
#   remerge-check.sh [-C <repo>] --all <base ref> <head>
#       Check every merge of <base ref> in <base ref>..<head>. A line a merge
#       dropped that a later commit put back counts as fixed. The card manager
#       and the merger run it on a PR's head.
#
# Prints one finding per line, then one verdict line:
#   REMERGE CHECK PASSED: … (exit 0) or REMERGE CHECK FAILED: … (exit 1);
#   exit 2 for a usage error or a commit that is not a two-parent merge.
# A line dropped on purpose is named in the merge commit's message as
#   Remerge-allow: <path>: <the line>
set -u
exec python3 -I "$(cd "$(dirname "$0")" && pwd)/remerge-check.py" "$@"
