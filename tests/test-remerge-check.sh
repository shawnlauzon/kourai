#!/bin/bash
# Tests .claude/bin/remerge-check.sh: a merge of the base that drops a line
# from either side fails, a clean one passes.
#
# Usage: .claude/bin/test-remerge-check.sh
#
# Nothing real is touched: every case builds its own git repo in a temporary
# folder (no remote). aws, tailscale, ssh and gh fail at once. A few seconds.
# Exits 0 when every case passes, 1 otherwise.
set -u
export KOURAI_CONFIG=${KOURAI_CONFIG:-$(cd "$(dirname "$0")" && pwd)/fixtures/config.toml}
export KOURAI_BIN=${KOURAI_BIN:-$(cd "$(dirname "$0")/../bin" && pwd)}

bin=$(cd "$(dirname "$0")/../bin" && pwd)
check=$bin/remerge-check.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/nonet"
for c in aws tailscale ssh gh; do
  printf '#!/bin/bash\necho "test: %s is not allowed in tests" >&2\nexit 99\n' "$c" >"$T/nonet/$c"
  chmod +x "$T/nonet/$c"
done
export PATH="$T/nonet:$PATH"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

failures=0
n=0
R=""
g() { git -C "$R" "$@"; }

# new <name>: a fresh repo on main with one commit of the files written by the caller after it.
new() { n=$((n + 1)); R=$T/r$n-$1; git init -q -b main "$R"; }
put() { mkdir -p "$(dirname "$R/$1")"; printf '%b' "$2" >"$R/$1"; }
commit() { g add -A; g commit -q -m "$1"; }
# merge_base_in: merge main into card; leaves the work tree mid-merge (conflicted or not) for the caller.
merge_base_in() { g checkout -q card; g merge --no-ff --no-commit main >/dev/null 2>&1; }
finish() { g add -A; g commit -q --no-edit "$@"; }

ok() { # name, want exit, want text (grep -E), [args to remerge-check.sh, default: HEAD]
  local name=$1 want=$2 text=$3; shift 3
  local out rc
  if [ $# -eq 0 ]; then set -- HEAD; fi
  out=$("$check" -C "$R" "$@" 2>&1); rc=$?
  if [ "$rc" = "$want" ] && grep -qE -- "$text" <<<"$out"; then
    echo "PASS $name"
  else
    echo "FAIL $name: want exit $want and /$text/, got exit $rc:"
    sed 's/^/    /' <<<"$out"
    failures=$((failures + 1))
  fi
}
no() { # name, text that must not be in the last output: re-runs on HEAD
  local out; out=$("$check" -C "$R" HEAD 2>&1)
  if grep -qE -- "$2" <<<"$out"; then echo "FAIL $1: /$2/ found:"; sed 's/^/    /' <<<"$out"; failures=$((failures + 1)); else echo "PASS $1"; fi
}

# 1. Each side changes its own file: a clean merge passes.
new clean
put a.txt 'one\ntwo\n'; put b.txt 'x\ny\n'; commit base
g checkout -q -b card; put a.txt 'one\ntwo\nbranch line\n'; commit branch
g checkout -q main; put b.txt 'x\ny\nbase line\n'; commit base2
merge_base_in; finish
ok "clean merge, each side its own file: passes" 0 '^REMERGE CHECK PASSED: .*nothing dropped'

# 2. Both sides change the same line; the resolution keeps both: passes.
new both
put f.md 'title\nline A\nend\n'; commit base
g checkout -q -b card; put f.md 'title\nline A, branch\nend\n'; commit branch
g checkout -q main; put f.md 'title\nline A\nbase line\nend\n'; commit base2
merge_base_in; put f.md 'title\nline A, branch\nbase line\nend\n'; finish
ok "conflict resolved keeping both sides: passes" 0 '^REMERGE CHECK PASSED'

# 3. The resolution takes the branch's hunk and drops the base's new line: fails.
new ours
put f.md 'title\nline A\nend\n'; commit base
g checkout -q -b card; put f.md 'title\nline A, branch\nend\n'; commit branch
g checkout -q main; put f.md 'title\nline A, base\nend\n'; commit base2
merge_base_in; put f.md 'title\nline A, branch\nend\n'; finish
ok "taking the branch's side drops the base's line: fails" 1 '^DROPPED: f.md: from the base: line A, base$'
ok "  … and the verdict says so" 1 '^REMERGE CHECK FAILED: .*1 dropped'

# 4. The resolution takes the base's hunk and drops the branch's line: fails.
new theirs
put f.md 'title\nline A\nend\n'; commit base
g checkout -q -b card; put f.md 'title\nline A, branch\nend\n'; commit branch
g checkout -q main; put f.md 'title\nline A, base\nend\n'; commit base2
merge_base_in; put f.md 'title\nline A, base\nend\n'; finish
ok "taking the base's side drops the branch's line: fails" 1 '^DROPPED: f.md: from the branch: line A, branch$'

# 5. The base rewords a row; the resolution puts the old wording back (the #255 case).
new revive
put W.md '| a | old wording |\n| b | row b |\n'; commit base
g checkout -q -b card; put W.md '| a | old wording |\n| b | row b, branch |\n'; commit branch
g checkout -q main; put W.md '| a | new wording |\n| b | row b, base |\n'; commit base2
merge_base_in; put W.md '| a | old wording |\n| b | row b, branch |\n| b | row b, base |\n'; finish
ok "old wording the base replaced comes back: the new is DROPPED" 1 '^DROPPED: W.md: from the base: \| a \| new wording \|$'
ok "  … and the old is REVIVED" 1 '^REVIVED: W.md: removed by the base: \| a \| old wording \|$'

# 6. rules.md markers: the base renames a section; the branch still names the old one (and old numeric markers).
new ranges
put agents/m.md 'Read first: [rules.md: The board], [rules.md: Card writes to Comment glossary].\n'; commit base
g checkout -q -b card; put agents/m.md 'Read first: [rules.md: The board], [rules.md: Card writes to Comment glossary]. More.\n'; commit branch
g checkout -q main; put agents/m.md 'Read first: [rules.md: Settings to The board], [rules.md: Card writes to Comment glossary].\n'; commit base2
g branch save-card card
merge_base_in; put agents/m.md 'Read first: [rules.md: Settings to The board], [rules.md: Card writes to Comment glossary]. More.\n'; finish
ok "markers: base's section names kept: passes" 0 '^REMERGE CHECK PASSED'
g checkout -q -B card save-card
merge_base_in; put agents/m.md 'Read first: [rules.md: The board], [rules.md: Card writes to Comment glossary]. More.\n'; finish
ok "markers: the branch's sentence over the base's names: fails" 1 '^DROPPED: agents/m.md: from the base: Read first: \[rules.md: Settings to The board\]'
g checkout -q -B card save-card
merge_base_in; put agents/m.md 'Read first: [rules.md 5-49: Settings to The board], [rules.md 230-356: Card writes to Comment glossary]. More.\n'; finish
ok "an old numeric marker with the base's names reads as the same marker: passes" 0 '^REMERGE CHECK PASSED'

# 7. A line dropped on purpose, named in the merge commit's message: passes, and says so.
new allow
put f.md 'title\nline A\nend\n'; commit base
g checkout -q -b card; put f.md 'title\nline A, branch\nend\n'; commit branch
g checkout -q main; put f.md 'title\nline A, base\nend\n'; commit base2
merge_base_in; put f.md 'title\nline A, branch\nend\n'
finish -m "Merge main into card" -m "Remerge-allow: f.md: line A, base"
ok "a Remerge-allow line in the merge message allows the drop" 0 '^ALLOWED \(Remerge-allow\) DROPPED: f.md: from the base: line A, base$'
ok "  … and the verdict counts it" 0 '^REMERGE CHECK PASSED: .*1 allowed by Remerge-allow'
g commit -q --amend -m "Merge main into card" -m "Remerge-allow: other.md: line A, base"
ok "a Remerge-allow line for another file allows nothing" 1 '^DROPPED: f.md: from the base: line A, base$'

# 8. Conflict markers committed: fails.
new markers
put f.md 'title\nline A\nend\n'; commit base
g checkout -q -b card; put f.md 'title\nline A, branch\nend\n'; commit branch
g checkout -q main; put f.md 'title\nline A, base\nend\n'; commit base2
merge_base_in; finish
ok "conflict markers left in the file: fails" 1 '^CONFLICT MARKER: f.md: <<<<<<< '

# 9. The base renames a file the branch edits: the edit is compared at the new path.
new rename
put old/name.md 'one\ntwo\nthree\nfour\nfive\n'; commit base
g checkout -q -b card; put old/name.md 'one\ntwo\nthree, branch\nfour\nfive\n'; commit branch
g checkout -q main; mkdir -p "$R/new"; g mv old/name.md new/name.md; commit base2
merge_base_in; finish
ok "a file the base renamed keeps the branch's edit at its new path: passes" 0 '^REMERGE CHECK PASSED'
no "  … with no finding" '^(DROPPED|REVIVED)'

# 10. Not a merge: a usage error.
new notmerge
put f.md 'x\n'; commit base
ok "a commit that is not a merge: exit 2" 2 '^REMERGE CHECK ERROR: .* is not a merge of two parents'
ok "an unknown commit: exit 2" 2 '^REMERGE CHECK ERROR: not a commit: nope' nope

# 11. The resolution adds a line neither side had: a note, not a failure.
new added
put f.md 'title\nline A\nend\n'; commit base
g checkout -q -b card; put f.md 'title\nline A, branch\nend\n'; commit branch
g checkout -q main; put f.md 'title\nline A\nbase line\nend\n'; commit base2
merge_base_in; put f.md 'title\nline A, branch\nbase line\nglue line\nend\n'; finish
ok "a line added in the merge is a note: passes" 0 '^NOTE ADDED IN MERGE: f.md: glue line$'

# 12. A line neither side touched, lost in the resolution: fails.
new context
put f.md 'title\nkeep me\nline A\nend\n'; commit base
g checkout -q -b card; put f.md 'title\nkeep me\nline A, branch\nend\n'; commit branch
g checkout -q main; put f.md 'title\nkeep me\nline A, base\nend\n'; commit base2
merge_base_in; put f.md 'title\nline A, branch\nline A, base\nend\n'; finish
ok "an untouched line lost in the resolution: fails" 1 '^DROPPED: f.md: from the branch and base: keep me$'

# 13. --all: every merge of the base; a later commit that puts the line back fixes it.
new all
put f.md 'title\nline A\nend\n'; commit base
g checkout -q -b card; put f.md 'title\nline A, branch\nend\n'; commit branch
g checkout -q main; put f.md 'title\nline A, base\nend\n'; commit base2
merge_base_in; put f.md 'title\nline A, branch\nend\n'; finish
ok "--all: a merge that dropped a line, not fixed: fails" 1 '^REMERGE CHECK FAILED: 1 merge of main into [0-9a-f]+ checked; 1 dropped something' --all main HEAD
put f.md 'title\nline A, branch\nline A, base\nend\n'; commit "put the base's line back"
ok "--all: a later commit put the line back: passes" 0 '^REMERGE CHECK PASSED: 1 merge of main into' --all main HEAD
ok "  … and names the fix" 0 ' FIXED LATER DROPPED: f.md: from the base: line A, base$' --all main HEAD
g checkout -q -b remote-copy; put h.md 'pushed from elsewhere\n'; commit "work on the remote copy"
g checkout -q card; put g.md 'own\n'; commit "own work"
g merge -q --no-ff --no-edit remote-copy >/dev/null 2>&1
ok "--all: a merge of the branch's own copy is not a merge of the base" 0 '^REMERGE CHECK PASSED: 1 merge of main into' --all main HEAD
g checkout -q -b plain main
ok "--all: no merge of the base at all: passes, 0 checked" 0 '^REMERGE CHECK PASSED: 0 merges of main into' --all main HEAD

# 14. A binary file the base changed, kept at the branch's old copy: fails.
new binary
put img.png 'P\0\1\2'; put f.md 'x\n'; commit base
g checkout -q -b card; put f.md 'x\ny\n'; commit branch
g checkout -q main; put img.png 'P\0\3\4'; commit base2
merge_base_in; g checkout -q card -- img.png; finish
ok "a binary file the base changed, kept old: fails" 1 '^DROPPED: img.png: binary file differs from the base$'

# 15. A long line is printed cut short, and a Remerge-allow line copied from the print matches it.
new long
long=$(printf 'w%.0s' $(seq 1 300))
put f.md "title\n$long base\nend\n"; commit base
g checkout -q -b card; put f.md "title\n$long branch\nend\n"; commit branch
g checkout -q main; put f.md "title\n$long base2\nend\n"; commit base2
merge_base_in; put f.md "title\n$long branch\nend\n"; finish
printed=$("$check" -C "$R" HEAD | sed -n 's/^DROPPED: f.md: from the base: //p')
ok "a long line is printed cut short with …" 1 '^DROPPED: f.md: from the base: w{150,}…$'
g commit -q --amend -m "Merge main into card" -m "Remerge-allow: f.md: $printed"
ok "  … and the printed line in Remerge-allow allows it" 0 '^REMERGE CHECK PASSED: .*1 allowed by Remerge-allow'

# 16. Both sides add a test to one test-selection row; the merge joins them into one row.
new joined
put sel.txt 'lib/a/*    a1 a2\nlib/b/*    b1\n'; commit base
g checkout -q -b card; put sel.txt 'lib/a/*    a1 a2 card_x\nlib/b/*    b1\n'; commit branch
g checkout -q main; put sel.txt 'lib/a/*    a1 a2 card_y\nlib/b/*    b1\n'; commit base2
merge_base_in; put sel.txt 'lib/a/*    a1 a2 card_x card_y\nlib/b/*    b1\n'; finish
ok "both sides' words joined into one line: passes" 0 '^REMERGE CHECK PASSED: .*2 lines kept word for word'
ok "  … and notes each side's line" 0 '^NOTE KEPT IN MERGED LINES: sel.txt: from the base: lib/a/\* +a1 a2 card_y$'
put sel.txt 'lib/a/*    a1 card_x card_y\nlib/b/*    b1\n'; g add -A; g commit -q --amend --no-edit
ok "a joined line that lost a word (a2): fails" 1 '^DROPPED: sel.txt: from the base: lib/a/\* +a1 a2 card_y$'

# 17. --all skips a merge committed before the rule took effect, and names it.
new cutoff
put f.md 'title\nline A\nend\n'; commit base
g checkout -q -b card; put f.md 'title\nline A, branch\nend\n'; commit branch
g checkout -q main; put f.md 'title\nline A, base\nend\n'; commit base2
merge_base_in; put f.md 'title\nline A, branch\nend\n'
GIT_COMMITTER_DATE=2026-10-16T12:00:00Z finish
ok "--all: a bad merge from before the rule is skipped: passes" 0 '^REMERGE CHECK PASSED: 0 merges of main into [0-9a-f]+ checked \(1 older merge skipped\)' --all main HEAD
ok "  … and names it" 0 '^[0-9a-f]{12} skipped: committed 2026-10-16T12:00:00Z, before the remerge rule took effect' --all main HEAD
ok "  … but checked on its own it still fails" 1 '^REMERGE CHECK FAILED'

# 18. A drop made on purpose in a merge already pushed: an empty commit after it allows it under --all.
new laterallow
put f.md 'title\nline A\nend\n'; commit base
g checkout -q -b card; put f.md 'title\nline A, branch\nend\n'; commit branch
g checkout -q main; put f.md 'title\nline A, base\nend\n'; commit base2
merge_base_in; put f.md 'title\nline A, branch\nend\n'; finish
g commit -q --allow-empty -m "Allow the base's line A, replaced by the branch's" -m "Remerge-allow: f.md: line A, base"
ok "--all: Remerge-allow in a later commit allows the drop" 0 '^REMERGE CHECK PASSED: 1 merge of main into' --all main HEAD
ok "  … and names it allowed" 0 ' ALLOWED \(Remerge-allow\) DROPPED: f.md: from the base: line A, base$' --all main HEAD

# 19. Two merge bases: the branch merged another card's branch, which reached main by its own
# merge, and main then reworded that card's line (#270 merging main after #253 merged).
new crisscross
put f.md 'title\nend\n'; put g.md 'g\n'; commit base
g checkout -q -b other; put f.md 'title\nother line\nend\n'; commit "other card"
g checkout -q main; put g.md 'g\nmain one\n'; commit main1
g checkout -q other; g merge -q --no-ff --no-edit main
g checkout -q main; put h.md 'h\n'; commit main2
g checkout -q -b card; put c.md 'card line\n'; commit branch
g merge -q --no-ff --no-edit other
g checkout -q main; g merge -q --no-ff --no-edit other; put f.md 'title\nother line, reworded\nend\n'; commit reword
g branch save-card card
merge_base_in; finish
ok "two merge bases, main's rewording of the other card's line kept: passes" 0 '^REMERGE CHECK PASSED'
ok "  … and names both bases" 0 '^NOTE: 2 merge bases \([0-9a-f]{12}, [0-9a-f]{12}\); each line'"'"'s old count is combined from them \(A \+ B - their merge base\)$'
g checkout -q -B card save-card
merge_base_in; put f.md 'title\nother line\nend\n'; finish
ok "two merge bases, the old wording put back: fails" 1 '^DROPPED: f.md: from the base: other line, reworded$'
ok "  … and the old is REVIVED" 1 '^REVIVED: f.md: removed by the base: other line$'

# 20. Two merge bases holding different versions of a file (the #291 case): main's file equals
# one base (trimmed to one copy of X), the other base is the other card's branch (three copies),
# the branch adds a copy on top of main's version. The branch's own copy is not revived.
new crisscross-own
put f.md 'top\nX\nX\nX\nend\n'; put g.md 'g\n'; commit base
g checkout -q -b other; put g.md 'g\nother\n'; commit "other card"
g checkout -q main; put f.md 'top\nX\nend\n'; commit "main trims to one copy"
g checkout -q -b card; g merge -q --no-ff --no-edit other
put f.md 'top\nX\nX\nend\n'; commit "branch adds a copy"
g checkout -q main; g merge -q --no-ff --no-edit other; put h.md 'h\n'; commit main2
merge_base_in; finish
ok "two merge bases with different versions of a file, the branch's own lines: passes" 0 '^REMERGE CHECK PASSED'
ok "  … and names both bases" 0 '^NOTE: 2 merge bases '
no "  … and revives nothing" '^REVIVED'

# 21. Two merge bases (case 19's shape): the resolution keeps the old wording next to main's
# rewording. Main removed the old wording on purpose, so it is REVIVED even though one base lacks it.
new crisscross-revive
put f.md 'title\nend\n'; put g.md 'g\n'; commit base
g checkout -q -b other; put f.md 'title\nother line\nend\n'; commit "other card"
g checkout -q main; put g.md 'g\nmain one\n'; commit main1
g checkout -q other; g merge -q --no-ff --no-edit main
g checkout -q main; put h.md 'h\n'; commit main2
g checkout -q -b card; put c.md 'card line\n'; commit branch
g merge -q --no-ff --no-edit other
g checkout -q main; g merge -q --no-ff --no-edit other; put f.md 'title\nother line, reworded\nend\n'; commit reword
merge_base_in; put f.md 'title\nother line\nother line, reworded\nend\n'; finish
ok "two merge bases, the old wording kept next to main's rewording: fails" 1 '^REVIVED: f.md: removed by the base: other line$'

echo
if [ "$failures" -eq 0 ]; then echo "All cases passed"; exit 0; fi
echo "$failures case(s) failed"; exit 1
