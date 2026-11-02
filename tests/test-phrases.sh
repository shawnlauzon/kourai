#!/usr/bin/env bash
# Every comment phrase in rules/phrases.txt stands in each kourai file it lists (a `project:` file is the
# project layer's and is checked there).
. "$(dirname "$0")/lib.sh"
require_fakes
n=0
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  phrase=${line%% | *}; files=${line#* | }
  IFS=',' read -r -a fs <<<"$files"
  for f in "${fs[@]}"; do
    f=${f# }
    case "$f" in project:*) continue ;; esac
    n=$((n + 1))
    if grep -qF -- "$phrase" "$KOURAI_ROOT/$f" 2>/dev/null; then pass; else fail "phrase [$phrase] is not in $f"; fi
  done
done < "$KOURAI_ROOT/rules/phrases.txt"
assert_eq "some kourai files were checked" 1 "$([ "$n" -gt 50 ] && echo 1 || echo 0)"
finish
