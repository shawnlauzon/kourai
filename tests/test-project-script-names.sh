#!/usr/bin/env bash
# No agent file, command or core rule names a project script bare: the project's scripts are not on PATH, they run as
# `kourai-project <script>`. And a bare review-policy.sh call is not a command: it runs as `kourai-hook review-policy.sh`.
set -u
. "$(dirname "$0")/lib.sh"
require_fakes
cd "$KOURAI_ROOT" || exit 2
out=$(python3 -I - <<'PY'
import glob, re
names = r'(card-test-server|test-server|builder-trial|server-probe|ft-report|ci-unstick)\.sh'
bare = re.compile(r'(?<![\w./-])' + names)
rp = re.compile(r'(?<![\w./-])review-policy\.sh check')
for f in sorted(glob.glob('agents/*.md') + glob.glob('commands/*.md') + ['rules/core.md']):
    for n, line in enumerate(open(f, encoding='utf-8'), 1):
        for m in bare.finditer(line):
            if not line[:m.start()].endswith('kourai-project '):
                print(f'{f}:{n}: bare {m.group(0)}')
        for m in rp.finditer(line):
            if not line[:m.start()].endswith('kourai-hook '):
                print(f'{f}:{n}: bare review-policy.sh')
PY
)
assert_eq "no project script or policy named bare" "" "$out"
finish
