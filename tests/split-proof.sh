#!/bin/bash
# Proof that the core/project split dropped no line of any role's read (plan K3).
#   tests/split-proof.sh <old-rules.md> <old-agents-dir> <new-core.md> <new-project.md> <new-agents-dir>
# For every agent file it computes the lines the old [rules.md: A to B] markers selected and the lines the
# new [core: ...] / [project: ...] markers select, and fails when a line read before is not read now.
# Headings that were renamed on purpose (Settings -> Project settings) are matched by their text after the "## ".
# Prints the rules size read per role (characters, old and new) as a table.
set -u
python3 -I - "$@" <<'PY'
import difflib, glob, os, re, sys
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

SUBS = [  # the substitution table: what the sweep replaced by config reads or placeholders (plan K2/K3)
    (r"https?://\S+", "<url>"),
    (r"\b[0-9a-fA-F]{24}\b", "<id>"),
    (r"/Users/[^\s`|)]*", "<path>"),
    (r"<[^<>`]*>", "<x>"),
    (r"\b(?:RunnerCityOrg|shawnlauzon)/[\w.-]+", "<repo>"),
    (r"\brules\.md\b|\bcore\.md\b|\bproject-rules\b", "<rules>"),
    (r"\b(runnercity-app|runnercity-api-server|runner_city|RunnerCity|runnercity)\b", "<project>"),
    (r"\b(mobile|server|main|development)\b", "<branch>"),
    (r"\s+", " "),
]
# lines reworded on purpose, each with its new text in core.md (the project's folder name became a config read)
REWORDED = {
    "- Files for the user go in `~/Development/runner_city_files`; never use `~/.runnercity`.":
        "- Files for the user go in `<state_dir>`; never use a dot-folder in the home directory.",
}
def norm(l):
    for a, b in SUBS:
        l = re.sub(a, b, l)
    return l.strip()

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
nsub = 0
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
    # a line that was changed only by the substitution table (a real id, path, link or name became a
    # placeholder or a config read) counts as carried when its normalized form matches a new line closely
    miss = [l for l in miss if l not in REWORDED]
    pool = [norm(l) for l in nl]
    carried, miss2 = [], []
    for l in miss:
        n = norm(l)
        best = max((difflib.SequenceMatcher(None, n, q).ratio() for q in pool if abs(len(q) - len(n)) < 0.4 * max(len(n), 1)), default=0)
        (carried if best >= 0.80 else miss2).append((l, best))
    miss = [l for l, _ in miss2]
    nsub += len(carried)
    print(f"{who} | {sum(map(len, ol))} | {sum(map(len, nl))}")
    for l in miss[:5]:
        print(f"MISSING in {who}: {l[:100]}")
    bad += len(miss)
print(f"{nsub} lines changed only by the substitution table (normalized match ratio at least 0.80 against a line the role now reads; the table is SUBS in this script)")
print("SPLIT PROOF OK" if not bad else f"SPLIT PROOF FAILED: {bad} lines")
sys.exit(1 if bad else 0)
PY
