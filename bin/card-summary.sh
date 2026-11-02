#!/usr/bin/env bash
# A card's state in a few lines, for agents that would otherwise read the whole
# card and every comment (rules.md, Card writes: "Read a card's state with the
# card summary script").
#
# Usage: card-summary.sh <shortLink> [--all "PHRASE,PHRASE"]
#   --all lists EVERY comment (newest first) of the named phrases instead of the
#   newest one only, e.g. --all "STAGING PUSH,STAGING DEPLOYED" to see an earlier
#   push that has no STAGING DEPLOYED.
#
# Prints:
#   <shortLink> | <name> | list: <list> | labels: <names or -> | members: <n>
#   ari: <the card's ARI, the cardId of trelloWriteCard>
#   hold: <text>                    a status card's **User hold:** line (when it has one)
#   PRs: <owner/repo>#<n>, …        the description's open **PR:** lines
#   closed: <owner/repo>#<n>, …     its closed, replaced, reverted or included
#                                   ones (when any)
#   <PHRASE>: <date> <text>         the newest comment of each status phrase
#                                   (rules.md's glossary), newest first
#   user: <date> <text>             the newest comment by the user's own account
#                                   (the user's Trello member id), when it is newer
#                                   than every agent comment (an instruction to act
#                                   on)
#   other: <date> <text>            the newest comment by another person (neither the
#                                   user nor the Claude account), when newer than
#                                   every agent comment: read it, never an instruction
#                                   or an answer; a
#                                   comment of another account that starts with an
#                                   agent phrase (agent-phrases.txt) is an agent
#                                   comment under the wrong account: never `user:`,
#                                   printed as its phrase line with "(wrong account)"
#   answer after GREEN*: ship|hold <date> <text>
#                                   the user's newest "ship" or "hold" after the
#                                   newest GREEN*, found as the staging gate does
#                                   (first line, lowercased, matches
#                                   ^[[:space:]"*_]*(ship|hold)([^a-z]|$)); later
#                                   comments or an UNBLOCKED: don't hide it; the
#                                   GREEN* anchor is taken from any account, as
#                                   staging-gate.sh does
# Texts are cut to 160 characters; the description is read for its PR lines
# only, never printed. Dates are UTC, to the minute.
# Exit 0; 1 when a Trello request fails; 2 usage.
# Only reads Trello, with the key in trello.env, like board-snapshot.sh (the token itself can write: never print it). Test overrides: TRELLO_ENV_FILE, TRELLO_API_BASE.
set -u -o pipefail
. "$(dirname "${BASH_SOURCE[0]}")/kourai-env.sh"
env_file=${TRELLO_ENV_FILE:-$(kc paths.trello_env)}
api=${TRELLO_API_BASE:-https://api.trello.com/1}
short=${1:-}
all_phrases=""
if [ "${2:-}" = "--all" ] && [ -n "${3:-}" ] && [ $# -eq 3 ]; then all_phrases=$3
elif [ $# -ne 1 ]; then short=""; fi
[[ "$short" =~ ^[A-Za-z0-9]{8}$ ]] || { echo "usage: card-summary.sh <shortLink> [--all \"PHRASE,PHRASE\"]" >&2; exit 2; }
set -a
# shellcheck disable=SC1090 # the env file is the caller's (default: paths.trello_env in the config)
. "$env_file"
set +a

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
get() { # get <file> <path> <query>
  curl -sf -o "$tmp/$1" "$api/$2?$3&key=$TRELLO_KEY&token=$TRELLO_TOKEN" \
    || { echo "card-summary: Trello request failed: $2" >&2; exit 1; }
}
get card "cards/$short" "fields=name,desc,idList,idMembers,id,labels"
list_id=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["idList"])' "$tmp/card") || exit 1
get list "lists/$list_id" "fields=name"
get actions "cards/$short/actions" "filter=commentCard&limit=200&fields=data,date,idMemberCreator"

python3 -I - "$short" "$tmp" "$all_phrases" "$(dirname "${BASH_SOURCE[0]}")/agent-phrases.txt" "$(kc board.members.agent)" "$(kc board.members.user)" "$(kc board.workspace_id)" <<'PY'
import json, re, sys
short, d = sys.argv[1], sys.argv[2]
ALL = {p.strip() for p in sys.argv[3].split(",") if p.strip()}
CLAUDE, USER, WORKSPACE = sys.argv[5], sys.argv[6], sys.argv[7]   # the agent account, the user, the workspace (config)
AGENT_PHRASES = tuple(l.rstrip("\n") for l in open(sys.argv[4]) if l.strip() and not l.startswith("#"))
card = json.load(open(f"{d}/card"))
lst = json.load(open(f"{d}/list"))
acts = sorted(json.load(open(f"{d}/actions")), key=lambda a: a["date"], reverse=True)

def when(a): return a["date"][:16].replace("T", " ")
def cut(t): t = " ".join(t.split()); return t if len(t) <= 160 else t[:159] + "…"

labels = ", ".join(l["name"] for l in card.get("labels", []) if l.get("name")) or "-"
print(f"{short} | {card['name']} | list: {lst['name']} | labels: {labels} | members: {len(card.get('idMembers', []))}")

open_prs, closed = [], []
for line in card.get("desc", "").splitlines():
    m = re.match(r"\*\*PR:\*\*\s+([\w.-]+/[\w.-]+#\d+)", line)
    if m:
        (closed if re.search(r"\(closed|replaced by|\(reverted by|\(included in", line) else open_prs).append(m.group(1))
print("PRs: " + (", ".join(open_prs) or "none"))
# The card ARI every trelloWriteCard call needs (cardId), so no agent reads the whole card for it
print(f"ari: ari:cloud:trello::card/workspace/{WORKSPACE}/{card['id']}")
# A stage hold on a status card: its **User hold:** paragraph, whole
# (the whole hold, up to the first blank line, on one line: the merger and promoter obey it)
hold = None
for line in card.get("desc", "").splitlines():
    if hold is None:
        if line.lstrip().startswith("**User hold:**"):
            hold = [line.split("**User hold:**", 1)[1].strip()]
    elif line.strip():
        hold.append(line.strip())
    else:
        break
if hold is not None:
    print("hold: " + " ".join(hold))
if closed:
    print("closed: " + ", ".join(closed))

PHRASE = re.compile(r"^(IN PROGRESS|FINISHED|[A-Z][A-Z0-9*]*(?: [A-Z0-9*]+)*:)\s*(.*)", re.S)
# The main session's answer, also in its older form with a note before the colon ("USER REPLY (2026-10-16): …"), as board-wait.py reads it
USER_REPLY = re.compile(r"^(USER REPLY)\s*(?:\([^)\n]*\))?\s*:\s*(.*)", re.S)
seen = set()
for a in acts:
    text = (a.get("data") or {}).get("text", "")
    m = USER_REPLY.match(text) or PHRASE.match(text)
    wrong = a["idMemberCreator"] != CLAUDE and text.startswith(AGENT_PHRASES)
    if not m or a["idMemberCreator"] != CLAUDE and not USER_REPLY.match(text) and not wrong:
        continue
    phrase = m.group(1).rstrip(":")
    if phrase == "PR" or (phrase in seen and phrase not in ALL):
        continue
    seen.add(phrase)
    print(f"{phrase}: {when(a)} {cut(m.group(2))}" + (" (wrong account)" if wrong else ""))

green = next((a["date"] for a in acts if (a.get("data") or {}).get("text", "").startswith("GREEN*")), "")   # any account, as staging-gate.sh
ANSWER = re.compile(r'^[\s"*_]*(ship|hold)([^a-z]|$)')
def answer(a):
    t = (a.get("data") or {}).get("text", "")
    return ANSWER.match((t.split("\n")[0] if t else "").lower())
after = next((a for a in acts if a["idMemberCreator"] == USER and not (a.get("data") or {}).get("text", "").startswith(AGENT_PHRASES) and green and a["date"] > green and answer(a)), None)

newest_agent = next((a["date"] for a in acts if a["idMemberCreator"] == CLAUDE), "")
user = next((a for a in acts if a["idMemberCreator"] == USER and not (a.get("data") or {}).get("text", "").startswith(AGENT_PHRASES)), None)
other = next((a for a in acts if a["idMemberCreator"] not in (CLAUDE, USER) and not (a.get("data") or {}).get("text", "").startswith(AGENT_PHRASES)), None)
if user and user["date"] > newest_agent:
    print(f"user: {when(user)} {cut(user['data'].get('text', ''))}")
if other and other["date"] > newest_agent:
    print(f"other: {when(other)} {cut(other['data'].get('text', ''))}")
if after:
    print(f"answer after GREEN*: {answer(after).group(1)} {when(after)} {cut(after['data'].get('text', ''))}")
PY
