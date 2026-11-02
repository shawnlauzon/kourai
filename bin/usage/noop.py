"""For the board watcher's turns since a date: how many turns, and how much cost (and how many tokens), went to turns
that took no action (no card write, agent start, PR or push).

Usage: python3 -I noop.py <projects dir> <since-date> [--exclude-self]

<projects dir> is the Claude Code projects folder of the repo; <since-date> is an ISO date
(agents that started before it are skipped); --exclude-self leaves out the most recently started token-auditor transcript (the caller's own).
Cost is model and token type weighted (cost.py); tokens beside it. Names and numbers only; writes nothing.
"""
import glob,json,re,collections,sys
import importlib.util,os
_s=importlib.util.spec_from_file_location("cost",os.path.join(os.path.dirname(os.path.abspath(__file__)),"cost.py"))
cost=importlib.util.module_from_spec(_s); _s.loader.exec_module(cost)
unpriced=cost.Unpriced()
def _args(extra=0):
    a=sys.argv[1:]; ex=False
    if '--exclude-self' in a:
        ex=True; a.remove('--exclude-self')
    if len(a)!=2+extra: sys.exit(__doc__)
    return a,ex
def self_file(P):
    """The most recently started token-auditor transcript (the caller's own), or None."""
    best=None
    for f in glob.glob(P+'/*/subagents/agent-*.jsonl'):
        try:
            if json.load(open(f[:-6]+'.meta.json')).get('agentType')!='token-auditor': continue
            ts=json.loads(open(f).readline()).get('timestamp','')
        except Exception: continue
        if best is None or ts>best[0]: best=(ts,f)
    return best[1] if best else None
(P,SINCE),EX=_args()
SELF=self_file(P) if EX else None
ACT=re.compile(r'trelloWriteCard|^Agent$|SendMessage|TaskStop|gh pr|as-claude|card-test-server|test-server\.sh|git push|dev-merge|gh-app')
tot=collections.Counter(); cnt=collections.Counter(); usd=collections.Counter()
for f in glob.glob(P+'/*/subagents/agent-*.jsonl'):
    if f==SELF: continue
    try: meta=json.load(open(f[:-6]+'.meta.json'))
    except Exception: continue
    if meta.get('agentType')!='board-watcher': continue
    seen=set(); seg=[0,0,False,0.0]; segs=[]; first=None
    for line in open(f):
        try:o=json.loads(line)
        except Exception: continue
        if first is None: first=o.get('timestamp','')
        m=o.get('message',{}) if isinstance(o.get('message'),dict) else {}
        if o.get('type')=='user':
            c=m.get('content'); istool=isinstance(c,list) and any(isinstance(b,dict) and b.get('type')=='tool_result' for b in c)
            if not istool:
                segs.append(seg); seg=[0,0,False,0.0]
        elif o.get('type')=='assistant':
            mid=m.get('id')
            if mid in seen: 
                pass
            else:
                seen.add(mid); u=m.get('usage',{})
                seg[0]+=1; seg[1]+=cost.context(u); d,pr=cost.request_cost(m.get('model'),u); unpriced.note(cost.request_key(m.get('model'),u),pr); seg[3]+=d
            for b in m.get('content',[]) if isinstance(m.get('content'),list) else []:
                if isinstance(b,dict) and b.get('type')=='tool_use':
                    s=b['name']+' '+json.dumps(b.get('input',{}))
                    if ACT.search(b['name']) or ACT.search(s): seg[2]=True
    segs.append(seg)
    if (first or '')<SINCE: continue
    for r,t,a,d in segs:
        k='action' if a else 'no-action'; tot[k]+=t; cnt[k]+=1; usd[k]+=d
print({k:{'turns':cnt[k],'cost_usd':round(usd[k],2),'tokens_M':round(tot[k]/1e6)} for k in tot})
print(cost.FOOTER); print(unpriced.line())
