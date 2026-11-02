#!/bin/bash
# Id and path scan (plan K2/K7). Fails when kourai's tree, or what a branch adds over its base, carries a real
# identity: a 24-hex id that is not a listed fake, the real board id, a /Users/<name> path, or a project name
# outside the files allowed to mention it as provenance.
#   tests/scan-ids.sh            scan the working tree
#   tests/scan-ids.sh <base>     also scan every line added in <base>..HEAD
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$here"
allow_ids=tests/scan-allow-ids.txt        # fake 24-hex ids (one per line)
allow_names=tests/scan-allow-names.txt    # files that may name the origin project
fail=0
bad_pat='[0-9a-f]{24}|7Tch9xIX|/Users/shawn|runnercity|runner_city|RunnerCity'
check() { # stdin: "file:line:text" lines
  while IFS= read -r l; do
    f=${l%%:*}; rest=${l#*:}; txt=${rest#*:}
    for id in $(grep -oE '\b[0-9a-f]{24}\b' <<<"$txt"); do
      grep -qx "$id" "$allow_ids" || { echo "SCAN: unlisted id $id in $f"; fail=1; }
    done
    grep -qE '7Tch9xIX' <<<"$txt" && { [ "$f" = "tests/scan-ids.sh" ] || { echo "SCAN: real board id in $f"; fail=1; }; }
    # a /Users/shawn path is fine only as a fake example path (…/Development/example_files, …/github/example-*),
    # or in the test guard that must name the live checkout it refuses (tests/lib.sh)
    if grep -qE '/Users/shawn' <<<"$txt" && [ "$f" != "tests/scan-ids.sh" ] && [ "$f" != "tests/lib.sh" ]; then
      grep -oE '/Users/shawn[^ "'"'"'`]*' <<<"$txt" | grep -vE '^/Users/shawn/Development/(example_files|github/example-)' | grep -q . \
        && { echo "SCAN: real user path in $f"; fail=1; }
    fi
    if grep -qiE 'runnercity|runner_city' <<<"$txt"; then
      grep -qxF "$f" "$allow_names" || { echo "SCAN: project name in $f (not in $allow_names): ${txt:0:100}"; fail=1; }
    fi
  done
}
check < <(git ls-files -z | xargs -0 grep -InE "$bad_pat" 2>/dev/null | grep -vE '^tests/scan-')
if [ "${1:-}" ]; then
  check < <(git diff -U0 "$1"..HEAD -- . ':!tests/scan-*' | awk '/^\+\+\+ b\//{f=substr($0,7)} /^\+[^+]/{print f":0:"substr($0,2)}' | grep -E "$bad_pat")
fi
[ "$fail" = 0 ] && echo "SCAN OK"
exit $fail
