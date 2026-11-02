#!/bin/bash
# rules-ranges.sh: markers resolve against the core rules and the project template; each failure shows.
. "$(dirname "$0")/lib.sh"
here=$KOURAI_ROOT
require_fakes
tmp=$(new_tmp)
mkdir -p "$tmp/agents"
cp "$here/rules/project-template.md" "$tmp/project.md"
cat > "$tmp/agents/a.md" <<'MD'
Read only your parts of the rules first. Your parts: [core: Settings to Merging], [project: Project settings], [project: Tests].
MD
run() { RULES_CORE="$here/rules/core.md" RULES_PROJECT="$tmp/project.md" AGENTS_DIR="$tmp/agents" "$here/bin/rules-ranges.sh" "$@" 2>&1; }

out=$(run check); rc=$?
assert_eq "template and core resolve" 0 "$rc"; assert_contains "three markers" "3 markers checked, 0 wrong" "$out"
out=$(run list); assert_contains "list names the project part" "Project settings" "$out"; assert_contains "list names the core part" "Comment glossary" "$out"

echo "Your parts: [core: No such heading]" > "$tmp/agents/a.md"
out=$(run check); rc=$?
assert_eq "a missing core heading fails" 1 "$rc"
assert_contains "missing heading names the file" "no such section in the core rules" "$out"

printf 'Read only your parts of the rules first. [core: Merging to Settings]\n' > "$tmp/agents/a.md"
out=$(run check); assert_contains "reversed pair" "last section comes before the first" "$out"

printf 'Your parts: [rules.md: Settings to Merging]\n' > "$tmp/agents/a.md"
out=$(run check); assert_contains "old marker form is refused" "retired marker form" "$out"

printf 'Your parts: [project: Releasing]\n' > "$tmp/agents/a.md"
grep -v '^## Releasing' "$tmp/project.md" > "$tmp/p2.md"
out=$(RULES_CORE="$here/rules/core.md" RULES_PROJECT="$tmp/p2.md" AGENTS_DIR="$tmp/agents" "$here/bin/rules-ranges.sh" check 2>&1)
assert_contains "a project without a required heading fails" 'lack the required heading "## Releasing"' "$out"
finish
