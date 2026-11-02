"""Find every auto-mode refusal in the Claude Code transcripts, once each.

Usage: python3 -I refusal_scan.py <projects dir> <out.json>

Matches each denial to the tool call it refused (by tool_use_id) and skips quoted
copies of the denial text (a plain grep counted 201 refusals where there were 157).
Writes one record per refusal (time, agent type, the refused call, the reason tag,
the transcript path) to <out.json>, and prints the count and the reason tags by count.
Group the records by kind of action yourself, and date each group against the
allow entry that covers it.
"""
import json, os, sys, re, collections

ROOT = sys.argv[1]
OUT = sys.argv[2]

MARKERS = ("auto mode classifier", "Permission for this action was denied", "denied by the auto mode")


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for c in content:
            if isinstance(c, dict) and c.get("type") == "text":
                parts.append(c.get("text", ""))
        return "\n".join(parts)
    return ""


def agent_type_for(path, first_prompt, meta):
    if meta:
        return meta
    return None


results = []
starts = collections.Counter()
for dp, dn, fns in os.walk(ROOT):
    for fn in fns:
        if not fn.endswith(".jsonl"):
            continue
        p = os.path.join(dp, fn)
        uses = {}
        first_prompt = None
        recs = []
        try:
            with open(p, errors="replace") as f:
                for line in f:
                    try:
                        r = json.loads(line)
                    except Exception:
                        # A partially written last line of a live transcript (or a
                        # truncated one): it holds no complete record to scan, so it is
                        # skipped on purpose; every complete line is still read.
                        continue
                    recs.append(r)
        except Exception as e:
            print("ERR", p, e, file=sys.stderr)
            continue
        # agent type: meta file next to subagent transcript
        atype = None
        metap = p[:-6] + ".meta.json"
        if os.path.exists(metap):
            try:
                m = json.load(open(metap))
                atype = m.get("agentType") or m.get("subagent_type") or m.get("name")
            except Exception:
                pass
        for r in recs:
            msg = r.get("message") or {}
            c = msg.get("content")
            if first_prompt is None and r.get("type") == "user":
                t = text_of(c)
                if t.strip():
                    first_prompt = t.strip()[:300]
            if isinstance(c, list):
                for b in c:
                    if isinstance(b, dict) and b.get("type") == "tool_use":
                        uses[b.get("id")] = (b.get("name"), b.get("input"))
        for r in recs:
            msg = r.get("message") or {}
            c = msg.get("content")
            if not isinstance(c, list):
                continue
            for b in c:
                if not (isinstance(b, dict) and b.get("type") == "tool_result"):
                    continue
                t = text_of(b.get("content")).strip()
                if not t:
                    continue
                head = t[:400]
                if not any(m in head for m in MARKERS):
                    continue
                # genuine refusal: the result itself is the refusal message (not a quoted search output)
                if "<persisted-output>" in head:
                    continue
                # The two real prefixes of a refusal message. A looser test (the marker anywhere in the first
                # 200 characters) counted an earlier scan's own output and the auto-mode help text.
                if not t.startswith(("Permission for this action was denied", "The server-side auto mode classifier")):
                    continue
                starts[t[:60]] += 1
                name, inp = uses.get(b.get("tool_use_id"), (None, None))
                m = re.search(r"Reason: (\[[^\]]+\])", t)
                tag = m.group(1) if m else None
                m2 = re.search(r"Reason: (.*?)(?: If you have other tasks|$)", t, re.S)
                reason = (m2.group(1).strip() if m2 else t[:300])[:400]
                if isinstance(inp, dict):
                    if name == "Bash":
                        call = inp.get("command", "")
                    elif name in ("Edit", "Write", "Read", "NotebookEdit"):
                        call = inp.get("file_path", "") + (" | " + (inp.get("old_string") or inp.get("content") or "")[:80].replace("\n", " ") if name != "Read" else "")
                    else:
                        call = json.dumps(inp)
                else:
                    call = str(inp)
                results.append({
                    "path": os.path.relpath(p, ROOT),
                    "ts": r.get("timestamp"),
                    "agent": atype,
                    "first_prompt": (first_prompt or "")[:200],
                    "tool": name,
                    "call": call.replace("\n", " ")[:300],
                    "tag": tag,
                    "reason": reason.replace("\n", " "),
                    "tool_use_id": b.get("tool_use_id"),
                })

json.dump(results, open(OUT, "w"), indent=1)
print(len(results))
for k, v in starts.most_common(20):
    print(v, repr(k))
