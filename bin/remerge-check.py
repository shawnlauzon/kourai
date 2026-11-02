#!/usr/bin/env python3
"""Prove that a merge of the base into a card branch dropped nothing.

Run through remerge-check.sh (usage there). Reads only the local git repo.

For one merge M (parent 1 = the branch before, B; parent 2 = the base, T;
old base O = merge-base(B, T); with several merge bases, O is one combined old base
built as git's recursive merge does: per line, A + B - C, at least 0, where C
is the merge base of the bases A and B), every file either side or the merge changed
is compared line by line, as counts of each line in O, B, T and M:

- a line the branch or the base has (added, or kept from O) must still be in M
  as often as both sides' changes together leave it: at least
  max(B, T) - (removed by B + removed by T) times. Fewer: DROPPED.
- a line one side removed must not come back: at most
  min(B, T) + (added by B + added by T) times. More: REVIVED.
- a line neither side had that M adds is ADDED IN MERGE: a note, not a
  failure (the resolution note says why).
- a DROPPED line every word of which (split on white space) is in the lines
  M added in that file is KEPT IN MERGED LINES: a note, not a failure. Two
  sides' edits of one line joined into one (a test-selection row with both
  sides' tests), or a comment rewrapped around both sides' words, keep every
  word; a resolution that loses a word still fails.
- conflict markers left in M (lines starting <<<<<<< or >>>>>>>): CONFLICT
  MARKER.

So a resolution that takes one side's version of a conflicted hunk shows the
other side's lines as DROPPED; one that puts back old wording the other side
replaced shows the new wording DROPPED and the old REVIVED.

Lines are compared with trailing white space removed; blank lines are skipped.
A rules.md marker is "[rules.md: First to Last]" (section names only). An
old numeric marker ("[rules.md 25-49: The board]") is read as the same marker
without its numbers, so only the section names count: a branch that changed
only numbers has changed nothing there, and a base that changed the names must
keep its names. Renames (git's own detection, per side) are followed: a file
the base renamed is compared at its new path. A binary file must equal the
side that changed it (either side when both did).

A line dropped on purpose is allowed by a line in M's commit message:
    Remerge-allow: <path>: <the line, as the finding prints it>
(a printed line cut short ends in "…" and matches every line it starts).
With --all, the same line in the message of any later commit of the PR counts
too, so a merge already pushed without it is allowed by an empty commit after
it (git commit --allow-empty), never by rewriting the merge.

--all <base ref> <head> checks each merge of the base in <base>..<head> (its
parent 2 is in the base), oldest first. A finding that <head> no longer has
(a later commit put the line back, or took it out again) counts as fixed.
Merges committed before RULE_START, when the rule took effect, are skipped and
named: they were made before anyone ran this check, and some folded fixes
into the merge commit, so they would fail an open PR for nothing.
"""

import collections
import datetime
import re
import subprocess
import sys

RANGE = re.compile(r"\[rules\.md \d+-\d+: ")
MARKER = re.compile(r"^(<{7}|>{7})( |$)")
ALLOW = re.compile(r"^Remerge-allow:\s*(.+?):\s(.+)$")
RULE_START = "2026-10-17T15:00:00Z"  # merges committed earlier are skipped by --all
CUT = 160  # printed line length
PER_FILE = 10  # findings printed per file and kind


class Usage(Exception):
    pass


REPO = "."


def git(*args, check=True):
    r = subprocess.run(["git", "-C", REPO, *args], capture_output=True)
    if check and r.returncode != 0:
        raise Usage("git %s: %s" % (" ".join(args), r.stderr.decode(errors="replace").strip()))
    return r


def rev(name):
    r = git("rev-parse", "--verify", "--quiet", name + "^{commit}", check=False)
    if r.returncode != 0:
        raise Usage("not a commit: %s" % name)
    return r.stdout.decode().strip()


def parents(sha):
    out = git("rev-list", "--parents", "-n", "1", sha).stdout.decode().split()
    return out[1:]


def blob(commit, path):
    if path is None:
        return None
    r = git("cat-file", "-p", "%s:%s" % (commit, path), check=False)
    return r.stdout if r.returncode == 0 else None


def names(a, b):
    out = git("diff", "--no-renames", "--name-only", "-z", a, b).stdout.decode(errors="replace")
    return {p for p in out.split("\0") if p}


def renames(a, b):
    out = git("diff", "-M", "--name-status", "-z", "--diff-filter=R", a, b).stdout.decode(errors="replace")
    parts = [p for p in out.split("\0") if p]
    found = {}
    i = 0
    while i + 2 < len(parts):  # with --diff-filter=R every entry is: status, old path, new path
        found[parts[i + 1]] = parts[i + 2]
        i += 3
    return found


def norm(line):
    line = line.rstrip()
    if not line.strip():
        return None
    return RANGE.sub("[rules.md: ", line)


def counts(data):
    c = collections.Counter()
    if data:
        for raw in data.decode("utf-8", errors="replace").split("\n"):
            n = norm(raw)
            if n is not None:
                c[n] += 1
    return c


def cut(line):
    return line if len(line) <= CUT else line[: CUT - 1] + "…"


def allowed_by(msg):
    rules = []
    for raw in msg.split("\n"):
        m = ALLOW.match(raw.strip())
        if m:
            rules.append((m.group(1).strip(), norm(m.group(2)) or ""))
    return rules


def is_allowed(rules, paths, line):
    for path, text in rules:
        if path not in paths:
            continue
        if text == line or text == cut(line):
            return True
        if text.endswith("…") and line.startswith(text[:-1]):
            return True
    return False


def groups(o, b, t, m):
    """(old path, branch path, base path, merged path) for every file to compare."""
    ren_b, ren_t = renames(o, b), renames(o, t)
    paths = names(o, b) | names(o, t) | names(b, m) | names(t, m)
    targets = set(ren_b.values()) | set(ren_t.values())
    out = []
    for p in sorted(paths | set(ren_b) | set(ren_t)):
        if p in targets and p not in ren_b and p not in ren_t:
            continue  # compared with the file it was renamed from
        pb = ren_b.get(p, p)
        pt = ren_t.get(p, p)
        pm = ren_t.get(p) or ren_b.get(p) or p
        out.append((p, pb, pt, pm))
    return out


def side(cb, ct, cm):
    s = [n for n, c in (("branch", cb), ("base", ct)) if c > cm]
    return " and ".join(s) if s else "both"


def check_merge(m, head=None):
    """Findings for merge m. With head, each failure is re-tested at head, and
    Remerge-allow lines in the commits after m up to head count too."""
    ps = parents(m)
    if len(ps) != 2:
        raise Usage("%s is not a merge of two parents" % m[:12])
    b, t = ps
    bases = git("merge-base", "--all", b, t).stdout.decode().split()
    if not bases:
        raise Usage("%s: its parents share no history" % m[:12])
    o = bases[0]
    notes = []
    if len(bases) > 1:
        # A branch that merged another card's branch, which then reached the base by
        # its own merge, has several merge bases. Any one alone misjudges lines the
        # others added or removed. So they are combined into one virtual old base, the
        # way git's recursive merge does: per line, A + B - C (at least 0), where C is
        # the merge base of the bases being combined (folded in one at a time).
        notes.append("NOTE: %d merge bases (%s); each line's old count is combined from them (A + B - their merge base)" % (
            len(bases), ", ".join(x[:12] for x in bases)))
    rules = allowed_by(git("log", "-1", "--format=%B", m).stdout.decode(errors="replace"))
    if head:
        rules += allowed_by(git("log", "--format=%B", "%s..%s" % (m, head)).stdout.decode(errors="replace"))
    fails, allowed, added, fixed, kept = [], [], [], [], []
    files = groups(o, b, t, m)
    for p, pb, pt, pm in files:
        label = pm if p == pm else "%s → %s" % (p, pm)
        paths = {p, pb, pt, pm}
        data = [blob(o, p), blob(b, pb), blob(t, pt), blob(m, pm)]
        later = blob(head, pm) if head else None
        if any(d is not None and b"\0" in d for d in data):
            do, db, dt, dm = data
            want = [dt] if db == do else [db] if dt == do else [db, dt]
            if dm not in want:
                f = ("DROPPED", label, "binary file differs from the %s" % ("base" if db == do else "branch" if dt == do else "branch and the base"))
                if head and later in want:
                    fixed.append(f)
                elif is_allowed(rules, paths, f[2]):
                    allowed.append(f)
                else:
                    fails.append(f)
            continue
        co, cb, ct, cm = (counts(d) for d in data)
        acc = bases[0]
        for x in bases[1:]:
            anc = git("merge-base", acc, x, check=False).stdout.decode().split()
            ca = counts(blob(anc[0], p)) if anc else collections.Counter()
            cx = counts(blob(x, p))
            combined = collections.Counter()
            for line in set(co) | set(cx) | set(ca):
                n = co[line] + cx[line] - ca[line]
                if n > 0:
                    combined[line] = n
            co = combined
            acc = x
        cl = counts(later) if head else None
        words = set()
        for line, c in cm.items():  # the lines M added: ADDED IN MERGE below
            o_, b_, t_ = co[line], cb[line], ct[line]
            if b_ >= o_ and t_ >= o_ and c > min(b_, t_) + (b_ - o_) + (t_ - o_):
                words.update(line.split())
        mine = []
        for line in sorted(set(co) | set(cb) | set(ct) | set(cm)):
            o_, b_, t_, m_ = co[line], cb[line], ct[line], cm[line]
            add = max(b_ - o_, 0) + max(t_ - o_, 0)
            rem_b, rem_t = max(o_ - b_, 0), max(o_ - t_, 0)
            low = max(0, max(b_, t_) - (rem_b + rem_t))
            up = min(b_, t_) + add
            if m_ < low:
                f = ("DROPPED", label, "from the %s: %s" % (side(b_, t_, m_), cut(line)))
                ok_later = head is not None and cl[line] >= low
            elif m_ > up and (rem_b or rem_t):
                who = " and ".join(n for n, r in (("branch", rem_b), ("base", rem_t)) if r)
                f = ("REVIVED", label, "removed by the %s: %s" % (who, cut(line)))
                ok_later = head is not None and cl[line] <= up
            elif m_ > up:
                added.append(("ADDED IN MERGE", label, cut(line)))
                continue
            else:
                continue
            if ok_later:
                fixed.append(f)
            elif f[0] == "DROPPED" and set(line.split()) <= words:
                kept.append(("KEPT IN MERGED LINES", label, f[2]))
            elif is_allowed(rules, paths, line):
                allowed.append(f)
            else:
                mine.append(f)
        fails.extend(mine)
        if data[3]:
            for raw in data[3].decode("utf-8", errors="replace").split("\n"):
                if MARKER.match(raw):
                    f = ("CONFLICT MARKER", label, cut(raw.rstrip()))
                    if head and not any(MARKER.match(x) for x in (later or b"").decode("utf-8", errors="replace").split("\n")):
                        fixed.append(f)
                    else:
                        fails.append(f)
    return {"m": m, "b": b, "t": t, "o": o, "files": len(files), "notes": notes,
            "fails": fails, "allowed": allowed, "added": added, "fixed": fixed, "kept": kept}


def show(kind_prefix, items):
    per = collections.Counter()
    hidden = collections.Counter()
    for kind, label, text in items:
        key = (kind, label)
        per[key] += 1
        if per[key] <= PER_FILE:
            print("%s%s: %s: %s" % (kind_prefix, kind, label, text))
        else:
            hidden[key] += 1
    for (kind, label), n in sorted(hidden.items()):
        print("%s%s: %s: … and %d more" % (kind_prefix, kind, label, n))


def report(r, prefix=""):
    for n in r["notes"]:
        print(prefix + n)
    show(prefix, r["fails"])
    show(prefix + "ALLOWED (Remerge-allow) ", r["allowed"])
    show(prefix + "FIXED LATER ", r["fixed"])
    show(prefix + "NOTE ", r["kept"])
    show(prefix + "NOTE ", r["added"])


def summary(r):
    bits = ["%d files compared" % r["files"]]
    if r["allowed"]:
        bits.append("%d allowed by Remerge-allow" % len(r["allowed"]))
    if r["fixed"]:
        bits.append("%d fixed by a later commit" % len(r["fixed"]))
    if r["kept"]:
        bits.append("%d lines kept word for word in lines the merge joined or rewrapped" % len(r["kept"]))
    if r["added"]:
        bits.append("%d lines added in the merge (say why in the resolution note)" % len(r["added"]))
    return "%s (base %s into branch %s, old base %s): %s" % (
        r["m"][:12], r["t"][:12], r["b"][:12], r["o"][:12], ", ".join(bits))


def kinds(fails):
    c = collections.Counter(k for k, _, _ in fails)
    return ", ".join("%d %s" % (n, k.lower()) for k, n in sorted(c.items()))


def main(argv):
    global REPO
    args = list(argv)
    if len(args) >= 2 and args[0] == "-C":
        REPO = args[1]
        args = args[2:]
    if len(args) == 1 and not args[0].startswith("-"):
        r = check_merge(rev(args[0]))
        report(r)
        if r["fails"]:
            print("REMERGE CHECK FAILED: %s: %s" % (summary(r), kinds(r["fails"])))
            return 1
        print("REMERGE CHECK PASSED: %s: nothing dropped" % summary(r))
        return 0
    if len(args) == 3 and args[0] == "--all":
        base, head = rev(args[1]), rev(args[2])
        merges = git("rev-list", "--merges", "--reverse", "%s..%s" % (base, head)).stdout.decode().split()
        start = datetime.datetime.strptime(RULE_START, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()
        checked, bad, skipped = 0, 0, 0
        for m in merges:
            ps = parents(m)
            if len(ps) != 2 or git("merge-base", "--is-ancestor", ps[1], base, check=False).returncode != 0:
                continue  # not a merge of the base (e.g. the branch's own remote copy)
            when = int(git("log", "-1", "--format=%ct", m).stdout.decode().strip())
            if when < start:
                skipped += 1
                print("%s skipped: committed %s, before the remerge rule took effect (%s)" % (
                    m[:12], datetime.datetime.fromtimestamp(when, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), RULE_START))
                continue
            checked += 1
            r = check_merge(m, head)
            report(r, "%s " % m[:12])
            if r["fails"]:
                bad += 1
                print("%s FAILED: %s: %s" % (m[:12], summary(r), kinds(r["fails"])))
            else:
                print("%s passed: %s" % (m[:12], summary(r)))
        what = "%d merge%s of %s into %s checked" % (checked, "" if checked == 1 else "s", args[1], head[:12])
        if skipped:
            what += " (%d older merge%s skipped)" % (skipped, "" if skipped == 1 else "s")
        if bad:
            print("REMERGE CHECK FAILED: %s; %d dropped something" % (what, bad))
            return 1
        print("REMERGE CHECK PASSED: %s; nothing dropped" % what)
        return 0
    raise Usage("usage: remerge-check.sh [-C <repo>] <merge commit> | [-C <repo>] --all <base ref> <head>")


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Usage as e:
        print("REMERGE CHECK ERROR: %s" % e, file=sys.stderr)
        sys.exit(2)
