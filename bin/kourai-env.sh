#!/bin/bash
# Sourced by the board scripts: puts the plugin's bin/ on PATH (so scripts find each other by bare name)
# and defines two readers of the installation's config (docs/CONFIG.md):
#   kc  <key>             the value, or exits with kourai-config's error
#   kc_or <key> <default> the value, or the default when the key is unknown
KOURAI_BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export KOURAI_BIN
case ":$PATH:" in *":$KOURAI_BIN:"*) ;; *) PATH="$KOURAI_BIN:$PATH"; export PATH ;; esac
kc() { kourai-config get "$1"; }
kc_or() { kourai-config get "$1" 2>/dev/null || printf '%s\n' "$2"; }
