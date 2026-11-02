#!/bin/bash
# Proof that the core/project split dropped no line of any role's read (plan K3).
#   tests/split-proof.sh <old-rules.md> <old-agents-dir> <new-core.md> <new-project.md> <new-agents-dir>
# For every agent file it computes the lines the old [rules.md: A to B] markers selected and the lines the
# new [core: ...] / [project: ...] markers select, and fails when a line read before is not read now.
# Headings that were renamed on purpose (Settings -> Project settings) are matched by their text after the "## ".
# Prints the rules size read per role (characters, old and new) as a table.
set -u
python3 -I - "$@" <<'PY'
import glob, os, re, sys
old_rules, old_agents, core, project, new_agents = sys.argv[1:6]

def secs(path):
    L = open(path, encoding="utf-8").read().split("\n")
    if L and L[-1] == "": L.pop()
    st = [(i, l[3:].strip()) for i, l in enumerate(L) if l.startswith("## ")]
    out = {}
    for k, (i, n) in enumerate(st):
        out[n] = (i, st[k+1][0] if k+1 < len(st) else len(L))
    return L, out

oL, oS = secs(old_rules)
cL, cS = secs(core)
pL, pS = secs(project)
orders = [n for n, _ in sorted(oS.items(), key=lambda kv: kv[1][0])]

def old_lines(text):
    got = []
    for m in re.finditer(r"\[rules\.md: (.+?)(?: to (.+?))?\]", text):
        a, b = m.group(1), m.group(2) or m.group(1)
        if a in oS and b in oS:
            got += oL[oS[a][0]:oS[b][1]]
    return got

def new_lines(text):
    got = []
    for m in re.finditer(r"\[(core|project): (.+?)(?: to (.+?))?\]", text):
        k, a, b = m.group(1), m.group(2), m.group(3) or m.group(2)
        L, S = (cL, cS) if k == "core" else (pL, pS)
        if a in S and b in S:
            got += L[S[a][0]:S[b][1]]
    return got

rename = {"## Settings": "## Project settings"}
bad = 0
print("role | old chars | new chars")
for p in sorted(glob.glob(os.path.join(old_agents, "*.md"))):
    who = os.path.basename(p)
    q = os.path.join(new_agents, who)
    if not os.path.exists(q): continue
    ot, nt = open(p, encoding="utf-8").read(), open(q, encoding="utf-8").read()
    ol, nl = old_lines(ot), new_lines(nt)
    if not ol: continue
    have = set(nl) | {rename.get(l, l) for l in nl}
    miss = [l for l in ol if l not in have and rename.get(l, l) not in have]
    # the old Settings pointer sentence is replaced on purpose
    miss = [l for l in miss if l != "The rest of this file refers to these by name."]
    print(f"{who} | {sum(map(len, ol))} | {sum(map(len, nl))}")
    for l in miss[:5]:
        print(f"MISSING in {who}: {l[:100]}")
    bad += len(miss)
print("SPLIT PROOF OK" if not bad else f"SPLIT PROOF FAILED: {bad} lines")
sys.exit(1 if bad else 0)
PY
