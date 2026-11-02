#!/usr/bin/env bash
# The mechanical checks of a workflow ([AGENTS]) PR, so a builder finds them before
# the verifier does and the verifier does not redo them by hand.
#
# Usage: workflow-checks.sh -C <repo> <base rev> <head rev>
#   builder mode:   workflow-checks.sh -C <its worktree> origin/main HEAD
#   verifier mode:  workflow-checks.sh -C <the main checkout> origin/main <40-character head>
#                   (the verifier runs the main checkout's own copy, after checking that its
#                   HEAD equals origin/main, so a PR cannot weaken the checks it is judged by)
#
# Reads git objects only (git show, git diff, git ls-tree): no worktree, no checkout of
# the head. The base is the merge base of <base rev> and <head rev>.
#
# One line per check: `CHECK <name>: ok`, `CHECK <name>: FAIL: <detail>` or
# `CHECK <name>: DRIFT: <detail>`; the last line is `WORKFLOW CHECKS PASSED: ...` or
# `WORKFLOW CHECKS FAILED: <n>`. Only FAIL counts (a defect the PR can fix). DRIFT is live
# state outside the PR (a live hook that differs from HEAD, or a runfolders/content/boardscripts failure that
# fails on the merge base too): report it, never a must-fix. For a runfolders, content or boardscripts DRIFT the
# verifier names the open WORKFLOW card that fixes main in its verdict, or files the one 🚨 [AGENTS]
# regression card (see workflow-verifier.md); the builder only reports it.
#   ranges    rules-ranges.sh check on the head's rules.md and agent files
#   phrases   .claude/board/phrases.txt: the manifest comes from the base plus the lines the
#             head adds; a base line the head drops or weakens is a FAIL (the builder names a
#             deliberate retirement under "Phrase manifest:" in the PR body, and the verifier
#             excuses only that FAIL: the script has revisions as input, so it still prints it);
#             a listed file at the head lacking its phrase is a FAIL; so is a manifest phrase one
#             changed file lost that still stands in another .claude/ file (a half-done rename;
#             WORKFLOW.md, user-setup-changes.md and phrases.txt are history, never counted)
#   allow     every .claude/bin/*.sh or .claude/hooks/*.sh the diff adds to an agent file is named
#             in an allow entry (~/.claude/settings.json, the main checkout's settings.local.json),
#             in a line the PR adds to user-setup-changes.md, or in a section that file lists as
#             "Not applied yet"
#   sections  each `settings section <n>` the diff mentions exists at the head and its ```json
#             blocks parse
#   filing    FAIL: a line the PR adds to an agent file, rules.md, a command or a skill says to file or
#             create a card at the top of a list (rules.md, Card titles and labels: new cards go to
#             the bottom; a line with 🚨, a status card, a move or a returning card is skipped)
#   hooks-live  DRIFT: a tracked hook of <repo> differs from its HEAD; FAIL: bash -n fails on a
#             hook the diff changes
#   runfolders  test-run-folders.sh on the head's agent files and rules.md: every run an agent file
#             starts writes to a log folder of its own. Compared with the merge base (see below)
#   content   test-board-content.sh on the head's agents, commands, skills, hooks, bin and rules.md:
#             the content cases (no comment posted with curl, glossary coverage, server-skill read forms,
#             promoter wording, compaction windows, raw-tokens wording). Compared with the merge base.
#             Both compare only `FAIL ` lines, after the extraction root becomes <root> and `:<n>:`
#             becomes `:N:`; a failure also on the merge base is DRIFT, a head-new line is a FAIL; a
#             crash (exit 1 with no FAIL line) or exit 2 of the test script is an environment error
#             (exit 2 of this script). With no rules.md or no agents at the head: ok, nothing to check
#   boardscripts  test-board-scripts.sh on the head's .claude/ tree and the base's (see below); runs only
#             when the allow entry for it is applied (settings section) and the PR touches the board scripts,
#             agents, rules.md or the manifest. The base's passing cases are cached in WFC_CACHE_DIR
#   files-changed  prints the changed files for the plan match; no verdict
# Exit 0 all checks passed, 1 a FAIL, 2 a script or environment error (bad revision, missing
# repo): the verifier then does the full pass, the builder writes `Workflow checks: error <line>`.
# Test overrides: WFC_HOME (default $HOME), WFC_LOCAL_SETTINGS (default the main checkout's
# .claude/settings.local.json), WFC_CACHE_DIR (default paths.workflow_checks_cache),
# WFC_BOARDSCRIPTS_TIMEOUT (seconds, default 600). Reads git objects, runs the board script test in a
# temporary folder with fake network tools; writes only that temporary folder and the cache file.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
. "$here/kourai-env.sh"
export WFC_LOCAL_SETTINGS_DEFAULT="$(kc repos.0.path)/.claude/settings.local.json" WFC_CACHE_DEFAULT="$(kc paths.workflow_checks_cache)"
exec python3 -I - "$here" "$@" <<'PY'
import collections, glob, json, os, re, subprocess, sys, tempfile

here = sys.argv[1]
args = sys.argv[2:]
if len(args) != 4 or args[0] != "-C":
    print("usage: workflow-checks.sh -C <repo> <base rev> <head rev>", file=sys.stderr)
    sys.exit(2)
repo, base_rev, head_rev = args[1:]


def git(*a, check=True):
    r = subprocess.run(["git", "-C", repo, *a], capture_output=True, text=True)
    if check and r.returncode != 0:
        print("workflow-checks.sh: git %s failed: %s" % (" ".join(a), r.stderr.strip()), file=sys.stderr)
        sys.exit(2)
    return r


def show(rev, path):
    r = git("show", "%s:%s" % (rev, path), check=False)
    return r.stdout if r.returncode == 0 else None


if not os.path.isdir(repo):
    print("workflow-checks.sh: no such repo %s" % repo, file=sys.stderr)
    sys.exit(2)
head = git("rev-parse", "--verify", head_rev + "^{commit}").stdout.strip()
base_tip = git("rev-parse", "--verify", base_rev + "^{commit}").stdout.strip()
base = git("merge-base", base_tip, head).stdout.strip()
if not base:
    print("workflow-checks.sh: no merge base of %s and %s" % (base_rev, head_rev), file=sys.stderr)
    sys.exit(2)

changed = [l for l in git("diff", "--name-only", base, head).stdout.split("\n") if l]
head_files = [l for l in git("ls-tree", "-r", "--name-only", head).stdout.split("\n") if l]
added_lines = {}  # path -> added lines


def added(path):
    if path not in added_lines:
        d = git("diff", "-U0", base, head, "--", path).stdout
        added_lines[path] = [l[1:] for l in d.split("\n") if l.startswith("+") and not l.startswith("+++")]
    return added_lines[path]


results = []  # (name, kind, detail) kind in ok FAIL DRIFT


def rec(name, kind, detail=""):
    results.append((name, kind, detail))


tmp = tempfile.mkdtemp(prefix="wfc-")


def extract(rev, paths, root):
    for p in paths:
        txt = show(rev, p)
        if txt is None:
            continue
        dest = os.path.join(root, p)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "w", encoding="utf-8") as f:
            f.write(txt)


# --- ranges ---------------------------------------------------------------
rules_path = ".claude/board/rules.md"
agent_paths = [p for p in head_files if p.startswith(".claude/agents/") and p.endswith(".md")]
if show(head, rules_path) is None:
    rec("ranges", "ok", "no rules.md at the head, nothing to check")
else:
    root = os.path.join(tmp, "ranges")
    extract(head, [rules_path] + agent_paths, root)
    env = dict(os.environ, RULES_FILE=os.path.join(root, rules_path),
               AGENTS_DIR=os.path.join(root, ".claude/agents"))
    r = subprocess.run(["bash", os.path.join(here, "rules-ranges.sh"), "check"],
                       capture_output=True, text=True, env=env)
    if r.returncode == 0:
        rec("ranges", "ok")
    elif r.returncode == 1:
        rec("ranges", "FAIL", " ".join((r.stdout + r.stderr).split())[:400])
    else:
        print("workflow-checks.sh: rules-ranges.sh error: %s" % " ".join((r.stdout + r.stderr).split())[:300],
              file=sys.stderr)
        sys.exit(2)


# --- phrases --------------------------------------------------------------
MAN = ".claude/board/phrases.txt"
HISTORY = {".claude/board/WORKFLOW.md", ".claude/board/user-setup-changes.md", MAN}


def parse_manifest(txt):
    out = {}
    for l in (txt or "").split("\n"):
        l = l.strip()
        if not l or l.startswith("#") or "|" not in l:
            continue
        ph, files = l.split("|", 1)
        out.setdefault(ph.strip(), set()).update(f.strip() for f in files.split(",") if f.strip())
    return out


base_man = parse_manifest(show(base, MAN))
head_man = parse_manifest(show(head, MAN))
problems = []
for ph, files in base_man.items():
    if ph not in head_man:
        problems.append("base manifest line dropped: %s" % ph)
    elif not files <= head_man[ph]:
        problems.append("base manifest line weakened: %s lost %s" % (ph, ", ".join(sorted(files - head_man[ph]))))
manifest = {}
for src in (base_man, head_man):
    for ph, files in src.items():
        manifest.setdefault(ph, set()).update(files)
head_cache = {}


def head_text(path):
    if path not in head_cache:
        head_cache[path] = show(head, path)
    return head_cache[path]


for ph, files in sorted(manifest.items()):
    for f in sorted(files):
        t = head_text(f)
        if t is None:
            problems.append("%s: listed file %s is missing at the head" % (ph, f))
        elif ph not in t:
            problems.append("%s: listed file %s lost it" % (ph, f))
claude_files = [p for p in head_files if p.startswith(".claude/") and p not in HISTORY
                and not p.endswith((".png", ".jpg", ".bak")) and ".bak-" not in p]
for ph in sorted(manifest):
    lost = []
    for f in changed:
        if f in HISTORY or not f.startswith(".claude/"):
            continue
        b = show(base, f)
        if b is not None and ph in b and (head_text(f) is None or ph not in head_text(f)):
            lost.append(f)
    if lost:
        still = []
        for f in claude_files:
            if f in lost:
                continue
            t = head_text(f)
            if t is not None and ph in t:
                still.append(f)
        if still:
            problems.append("%s: lost in %s but still in %s (a half-done rename or removal)"
                            % (ph, ", ".join(lost), ", ".join(still[:4]) + (" ..." if len(still) > 4 else "")))
if problems:
    rec("phrases", "FAIL", "; ".join(problems)[:1500])
else:
    rec("phrases", "ok", "%d manifest phrases" % len(manifest))


# --- allow ----------------------------------------------------------------
home = os.environ.get("WFC_HOME", os.path.expanduser("~"))
local_settings = os.environ.get("WFC_LOCAL_SETTINGS",
                                os.environ["WFC_LOCAL_SETTINGS_DEFAULT"])
allow_text = ""
for p in (os.path.join(home, ".claude/settings.json"), local_settings):
    try:
        d = json.load(open(p, encoding="utf-8"))
    except (OSError, ValueError):
        continue  # a settings file that is missing or unreadable allows nothing; the names then show as not allowed
    allow_text += "\n".join(d.get("autoMode", {}).get("allow", []) if isinstance(d.get("autoMode"), dict) else [])
    allow_text += "\n" + "\n".join(d.get("permissions", {}).get("allow", []) if isinstance(d.get("permissions"), dict) else [])
usc = ".claude/board/user-setup-changes.md"
usc_added = "\n".join(added(usc)) if usc in changed else ""
usc_head = head_text(usc) or ""
unapplied = ""
m = re.search(r"\*\*Not applied yet:\*\*(.*?)(?:\n\n|\n##|\Z)", usc_head, re.S)
if m:
    for n in re.findall(r"^- sections? (\d+)", m.group(1), re.M):
        sm = re.search(r"^## %s\. .*?(?=^## |\Z)" % n, usc_head, re.S | re.M)
        if sm:
            unapplied += sm.group(0)
# A script an agent file already named at the base is not new (a reworded line that keeps naming it must
# not fail); the check is for a script no agent file named before.
base_agent_text = ""
for f in git("ls-tree", "-r", "--name-only", base).stdout.split("\n"):
    if f.startswith(".claude/agents/") and f.endswith(".md"):
        base_agent_text += (show(base, f) or "")
base_names = set(re.findall(r"\.claude/(?:bin|hooks)/([A-Za-z0-9_.-]+\.sh)", base_agent_text))
names = set()
for f in changed:
    if f.startswith(".claude/agents/") and f.endswith(".md"):
        for l in added(f):
            names.update(re.findall(r"\.claude/(?:bin|hooks)/([A-Za-z0-9_.-]+\.sh)", l))
names -= base_names
missing = sorted(n for n in names if n not in allow_text and n not in usc_added and n not in unapplied)
if missing:
    rec("allow", "FAIL", "added to an agent file but named in no allow entry, no unapplied section and no line the PR adds to "
        "user-setup-changes.md: " + ", ".join(missing))
else:
    rec("allow", "ok", "%d script names" % len(names))


# --- sections -------------------------------------------------------------
refs = set()
for f in changed:
    if f == usc or not f.startswith(".claude/"):
        continue
    for l in added(f):
        refs.update(re.findall(r"[sS]ettings section (\d+)", l))
bad = []
for n in sorted(refs, key=int):
    sm = re.search(r"^## %s\. .*?(?=^## |\Z)" % n, usc_head, re.S | re.M)
    if not sm:
        bad.append("section %s is not in user-setup-changes.md at the head" % n)
        continue
    for blk in re.findall(r"^```json\n(.*?)^```", sm.group(0), re.S | re.M):
        try:
            json.loads(blk)
        except ValueError as e:
            bad.append("section %s: a json block does not parse (%s)" % (n, e))
if bad:
    rec("sections", "FAIL", "; ".join(bad))
else:
    rec("sections", "ok", "%d sections mentioned" % len(refs))


# --- filing ---------------------------------------------------------------
# Cards an agent creates go to the bottom of their list (rules.md, Card titles and labels). A sentence
# the PR adds that files a card on top is a FAIL: a filing verb (file, create), then card(s), then
# "top of", "at the top", "on top" or pos: "top". Only a 🚨 card, a status card or a move goes on top.
FILE_VERB = re.compile(r"\b(file|files|filed|filing|create|creates|created)\b", re.I)
CARD_WORD = re.compile(r"\bcards?\b", re.I)
ON_TOP = re.compile(r"(\btop of\b|\bat the top\b|\bon top\b|pos: ?\"top\")", re.I)
bad = []
for f in changed:
    if not (re.match(r"\.claude/(agents|commands)/[^/]+\.md$", f) or f == ".claude/board/rules.md" or re.match(r"\.claude/skills/.+\.md$", f)):
        continue
    for line in added(f):
        if "🚨" in line or re.search(r"status card|\bmove|\breturning", line, re.I):
            continue
        for sent in re.split(r"[.;:]", line):
            m = FILE_VERB.search(sent)
            if not m:
                continue
            c = CARD_WORD.search(sent, m.end())
            if c and ON_TOP.search(sent, c.end()):
                bad.append("%s: %s" % (f, sent.strip()[:120]))
if bad:
    rec("filing", "FAIL", "a card filed on top (only 🚨 cards, status cards and moves go on top; a new card goes to the bottom): " + "; ".join(bad[:5]))
else:
    rec("filing", "ok")


# --- runfolders, content -------------------------------------------------
# The board-script tests that read the live agent files and rules.md (test-run-folders.sh: every run an
# agent file starts writes to a log folder of its own; test-board-content.sh: the other content cases)
# run on the head's files, with the copies of the tests in this script's own folder (the main
# checkout's in verifier mode), so a PR cannot weaken the tests it is judged by. A failure that is
# already on the merge base is DRIFT (main is broken; a PR must not bounce for it); only a failing
# line the head adds is a FAIL. Only lines that start with `FAIL ` are compared, one per offending
# item, after the extraction root becomes `<root>` and `:<digits>:` becomes `:N:` (so a failure that
# only moved to another line, or was extracted under another root, is the same line). Summary lines,
# PASS lines and stderr are never compared.

def tree_paths(rev, prefixes):
    return [p for p in git("ls-tree", "-r", "--name-only", rev).stdout.split("\n")
            if any(p.startswith(x) for x in prefixes)]


def fail_lines(rev, label, name):
    """Run the check `name` on the files of `rev`: (status, lines). status ok|FAIL|empty."""
    root = os.path.join(tmp, "%s-%s" % (name, label))
    prefixes = [".claude/agents/"] if name == "runfolders" else [
        ".claude/agents/", ".claude/commands/", ".claude/skills/", ".claude/hooks/", ".claude/bin/"]
    if show(rev, rules_path) is None or not tree_paths(rev, [".claude/agents/"]):
        return "empty", []
    # test-board-content.sh also reads board/user-setup-changes.md (the content check only)
    extra = tree_paths(rev, [".claude/board/user-setup-changes.md"]) if name == "content" else []
    extract(rev, [rules_path] + tree_paths(rev, prefixes) + extra, root)
    if name == "runfolders":
        env = dict(os.environ, RULES_FILE=os.path.join(root, rules_path),
                   AGENTS_DIR=os.path.join(root, ".claude/agents"))
        cmd = ["bash", os.path.join(here, "test-run-folders.sh")]
    else:
        env = dict(os.environ)
        cmd = ["bash", os.path.join(here, "test-board-content.sh"), root]
    r = subprocess.run(cmd, capture_output=True, text=True, env=env)
    out = r.stdout
    lines = []
    for l in out.split("\n"):
        if l.startswith("FAIL "):
            l = l.replace(root, "<root>")
            l = re.sub(r":\d+(?=:|$)", ":N", l)
            lines.append(l)
    if r.returncode == 0:
        return "ok", []
    if r.returncode == 1 and lines:
        return "FAIL", lines
    # exit 2, or exit 1 with no FAIL line (a crash): an environment error, never a verdict
    print("workflow-checks.sh: %s error at %s (exit %d): %s" % (
        name, label, r.returncode, " ".join((out + r.stderr).split())[:300]), file=sys.stderr)
    sys.exit(2)


for check_name, script in (("runfolders", "test-run-folders.sh"), ("content", "test-board-content.sh")):
    st, hl = fail_lines(head, "head", check_name)
    if st == "empty":
        rec(check_name, "ok", "no rules.md or agents at the head, nothing to check")
    elif st == "ok":
        rec(check_name, "ok")
    else:
        bst, bl = fail_lines(base, "base", check_name)
        remaining = collections.Counter(bl)
        new = []
        for l in hl:
            if remaining[l] > 0:
                remaining[l] -= 1
            else:
                new.append(l)
        if new:
            rec(check_name, "FAIL", "%s: %s" % (script, " | ".join(new[:6])[:1500]))
        else:
            rec(check_name, "DRIFT", "fails on the base too, so not the PR's: " + " | ".join(hl[:3])[:600])


# --- boardscripts ---------------------------------------------------------
# test-board-scripts.sh (the board scripts' own test, about two minutes) runs on the head's whole .claude/
# tree and on the merge base's, extracted to temporary folders, with fake aws, tailscale, ssh and gh that
# fail at once (nothing real is reached). It runs only when the PR touches .claude/bin, .claude/agents,
# rules.md or the phrase manifest. Compared by case: a head `FAIL ` line the base lacks is a FAIL; a base
# `PASS <name>` line the head lacks (a deleted or renamed case) is a FAIL too, unless the PR body lists it
# under `Script test cases removed:` with a reason (the verifier excuses only that); a case failing on both
# is DRIFT. The base's passing cases are cached in WFC_CACHE_DIR/<base sha>.pass (only after a clean base
# run; the head run is never cached). It runs only once the allow entry says it may (settings section for
# the board script test); until then the line says so and the verifier's pass notes it.
BS_ENTRY = "board script test in a temporary folder"
BS_TRIGGERS = (".claude/bin/", ".claude/agents/", rules_path, MAN)
BS_TIMEOUT = int(os.environ.get("WFC_BOARDSCRIPTS_TIMEOUT", "600"))


def boardscripts_run(rev, label):
    """Run the board script test of `rev`'s .claude/ tree: (returncode, PASS names, FAIL lines)."""
    root = os.path.join(tmp, "boardscripts-" + label)
    extract(rev, [p for p in git("ls-tree", "-r", "--name-only", rev, "--", ".claude").stdout.split("\n")
                  if p and not p.endswith((".png", ".jpg"))], root)
    script = os.path.join(root, ".claude/bin/test-board-scripts.sh")
    if not os.path.isfile(script):
        return None, set(), []
    for dp, _, fns in os.walk(os.path.join(root, ".claude")):
        for fn in fns:
            if fn.endswith((".sh", ".py")):
                os.chmod(os.path.join(dp, fn), 0o755)
    fakes = os.path.join(tmp, "bs-fakes-" + label)
    os.makedirs(fakes, exist_ok=True)
    for c in ("aws", "tailscale", "ssh", "gh"):
        fp = os.path.join(fakes, c)
        with open(fp, "w") as f:
            f.write('#!/bin/bash\necho "test: %s is not allowed in tests" >&2\nexit 99\n' % c)
        os.chmod(fp, 0o755)
    env = dict(os.environ, PATH=fakes + os.pathsep + os.environ.get("PATH", ""))
    try:
        r = subprocess.run(["bash", script], capture_output=True, text=True, env=env, timeout=BS_TIMEOUT)
    except subprocess.TimeoutExpired:
        print("workflow-checks.sh: boardscripts error at %s: timed out after %d s" % (label, BS_TIMEOUT), file=sys.stderr)
        sys.exit(2)
    names, fails = set(), []
    for l in r.stdout.split("\n"):
        if l.startswith("PASS "):
            names.add(l[5:].strip())
        elif l.startswith("FAIL "):
            fails.append(l.split(": ", 1)[0].strip())  # the case name; the detail may hold paths
    return r.returncode, names, fails


if not any(f.startswith(BS_TRIGGERS) or f == rules_path for f in changed):
    rec("boardscripts", "ok", "no board script, agent, rules.md or manifest change, nothing to run")
elif BS_ENTRY not in (open(os.path.join(home, ".claude/settings.json"), encoding="utf-8").read()
                      if os.path.isfile(os.path.join(home, ".claude/settings.json")) else ""):
    rec("boardscripts", "ok", "not run: the allow entry is not updated yet")
elif show(head, ".claude/bin/test-board-scripts.sh") is None:
    rec("boardscripts", "ok", "no test-board-scripts.sh at the head, nothing to run")
else:
    hrc, hpass, hfail = boardscripts_run(head, "head")
    cache_dir = os.environ.get("WFC_CACHE_DIR", os.environ["WFC_CACHE_DEFAULT"])
    cache = os.path.join(cache_dir, base + ".pass")
    bfail = []
    try:
        bpass = set(l for l in open(cache, encoding="utf-8").read().split("\n") if l)
    except OSError:
        brc, bpass, bfail = boardscripts_run(base, "base")
        if brc == 0 and bpass:
            try:
                os.makedirs(cache_dir, exist_ok=True)
                with open(cache + ".tmp", "w", encoding="utf-8") as f:
                    f.write("\n".join(sorted(bpass)) + "\n")
                os.replace(cache + ".tmp", cache)
            except OSError:
                pass  # a cache that cannot be written only costs the next run a base run
    if hrc not in (0, 1) or (hrc == 1 and not hfail):
        print("workflow-checks.sh: boardscripts error at head (exit %s): the test script crashed" % hrc, file=sys.stderr)
        sys.exit(2)
    remaining = collections.Counter(bfail)
    new_fail = []
    for n_ in hfail:
        if remaining[n_] > 0:
            remaining[n_] -= 1
        else:
            new_fail.append(n_)
    gone = sorted(n_ for n_ in bpass if n_ not in hpass and n_ not in hfail)
    if new_fail or gone:
        bits = []
        if new_fail:
            bits.append("test-board-scripts.sh: new failing case(s): " + " | ".join(new_fail[:6]))
        if gone:
            bits.append("cases the base passed that the head no longer runs (list them under 'Script test cases removed:' with a reason if on purpose): "
                        + " | ".join(gone[:6]) + (" ..." if len(gone) > 6 else ""))
        rec("boardscripts", "FAIL", "; ".join(bits)[:1500])
    elif hfail:
        rec("boardscripts", "DRIFT", "fails on the base too, so not the PR's: " + " | ".join(hfail[:3])[:600])
    else:
        rec("boardscripts", "ok", "%d cases" % len(hpass))


# --- hooks-live -----------------------------------------------------------
drift = [l for l in git("diff", "--name-only", "HEAD", "--", ".claude/hooks", check=False).stdout.split("\n")
         if l.endswith(".sh")]
for h in drift:
    rec("hooks-live", "DRIFT", "%s in %s differs from its HEAD" % (h, repo))
bad = []
for f in changed:
    if f.startswith(".claude/hooks/") and f.endswith(".sh"):
        txt = show(head, f)
        if txt is None:
            continue
        p = os.path.join(tmp, "hook-" + os.path.basename(f))
        with open(p, "w", encoding="utf-8") as fh:
            fh.write(txt)
        r = subprocess.run(["bash", "-n", p], capture_output=True, text=True)
        if r.returncode != 0:
            bad.append("%s: %s" % (f, r.stderr.strip()[:200]))
if bad:
    rec("hooks-live", "FAIL", "bash -n fails: " + "; ".join(bad))
elif not drift:
    rec("hooks-live", "ok")

rec("files-changed", "ok", "%d files: %s" % (len(changed), ", ".join(changed)))

# --- report ---------------------------------------------------------------
fails = 0
drifts = 0
for name, kind, detail in results:
    if kind == "ok":
        print("CHECK %s: ok%s" % (name, (" (" + detail + ")") if detail and name != "files-changed" else (": " + detail if detail else "")))
    else:
        print("CHECK %s: %s: %s" % (name, kind, detail))
        if kind == "FAIL":
            fails += 1
        else:
            drifts += 1
print("head %s, base %s" % (head, base))
if fails:
    print("WORKFLOW CHECKS FAILED: %d" % fails)
    sys.exit(1)
print("WORKFLOW CHECKS PASSED: %d drift" % drifts)
PY
