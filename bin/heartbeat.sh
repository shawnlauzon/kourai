#!/bin/bash
# Leftover heartbeat files. Agents write no heartbeats since the switch to the
# new workflow (rules.md, Liveness comes from transcripts); what's left:
#   heartbeat.sh path <name>     the path of a keep-alive file, for scripts that
#                                still keep $CARD_HEARTBEAT fresh while they run
#   heartbeat.sh remove <name>   delete a leftover file, for an agent the board
#                                watcher confirmed dead
# <name> is a card short link or a role: letters, digits and '-' only.
# Exit 0; 2 usage. Override (tests): HEARTBEAT_DIR (default
# paths.heartbeat_dir).
set -u
. "$(dirname "${BASH_SOURCE[0]}")/kourai-env.sh"

dir=${HEARTBEAT_DIR:-$(kc paths.heartbeat_dir)}
usage() { echo "usage: heartbeat.sh path|remove <name>" >&2; exit 2; }
[ $# -eq 2 ] || usage
cmd=$1 name=$2
[[ "$name" =~ ^[A-Za-z0-9-]+$ ]] || { echo "heartbeat.sh: bad name '$name'" >&2; exit 2; }
case "$cmd" in
  path) echo "$dir/$name" ;;
  remove) rm -f "$dir/$name" ;;
  *) usage ;;
esac
