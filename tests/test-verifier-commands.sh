#!/usr/bin/env bash
# The workflow verifier's runnable commands must work from any folder after the switch: the refusal scan by the
# plugin's full path (bin/verify/refusal_scan.py exists there), the drift check by the installer's full path
# (kourai-install is not on the PATH), and no guard that a stale allow entry can satisfy.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
f=$here/agents/workflow-verifier.md
fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
[ -f "$here/bin/verify/refusal_scan.py" ] && pass "refusal_scan.py ships in the plugin's bin/verify" || fail "bin/verify/refusal_scan.py is missing"
grep -q 'plugin-root)/bin/verify/refusal_scan.py' "$f" && pass "the scan runs by the plugin path" || fail "the scan is not run by the plugin path"
grep -q 'python3 -I verify/refusal_scan.py' "$f" && fail "a cwd-relative scan path is back" || pass "no cwd-relative scan path"
grep -q 'grep -c refusal_scan ~/.claude/settings.json' "$f" && fail "the guard 'grep -c refusal_scan' passes on a stale old-path entry" || pass "the guard names the new path"
grep -q 'plugin-root)/installer/kourai-install" check' "$f" && pass "the drift check runs the installer by its full path" || fail "the drift check runs kourai-install bare"
grep -q 'Run `kourai-install check`' "$f" && fail "bare kourai-install check is back" || pass "no bare kourai-install check"
grep -q 'The one exception is `check`' "$here/docs/UPDATING.md" && pass "UPDATING.md allows the verifier's check" || fail "UPDATING.md still says agents never run check"
[ "$fails" -eq 0 ] && echo "ALL PASSED" || echo "$fails FAILED"
[ "$fails" -eq 0 ]
