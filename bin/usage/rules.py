"""Per agent type, how many agents (started since a date) read board/rules.md and how many
requests they made, and the cost of those requests, after reading it.

Usage: python3 -I rules.py <projects dir> <since-date> [--exclude-self]

<projects dir> is the Claude Code projects folder of the repo; <since-date> is an ISO date
(agents that started before it are skipped); --exclude-self leaves out the most recently started token-auditor transcript (the caller's own).
Cost is model and token type weighted (cost.py); ranked by it. Names and numbers only; writes nothing.
"""
import glob,json,collections,sys
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
agg=collections.defaultdict(lambda:[0,0,0,0.0])  # agents, readers, reqs_after, usd_after
for f in glob.glob(P+'/*/subagents/agent-*.jsonl'):
    if f==SELF: continue
    try: meta=json.load(open(f[:-6]+'.meta.json'))
    except Exception: continue
    t=meta.get('agentType','?')
    seen=set(); idx=None; reqs=[]; start=None
    for line in open(f):
        try: o=json.loads(line)
        except Exception: continue
        if start is None: start=o.get('timestamp','')
        if o.get('type')!='assistant': continue
        m=o.get('message',{}); mid=m.get('id')
        u=m.get('usage',{})
        if mid in seen: 
            continue
        seen.add(mid)
        tot,pr=cost.request_cost(m.get('model'),u); unpriced.note(cost.request_key(m.get('model'),u),pr)
        hit=False
        for b in m.get('content',[]):
            if isinstance(b,dict) and b.get('type')=='tool_use' and 'board/rules.md' in json.dumps(b.get('input',{})):
                hit=True
        reqs.append((hit,tot))
    if not start or start<SINCE: continue
    a=agg[t]; a[0]+=1
    ix=[i for i,(h,_) in enumerate(reqs) if h]
    if ix:
        a[1]+=1; after=reqs[ix[0]+1:]; a[2]+=len(after); a[3]+=sum(x for _,x in after)
for t,a in sorted(agg.items(),key=lambda x:-x[1][3]):
    print(t,'agents',a[0],'read rules',a[1],'requests after read',a[2],'cost after read $%.2f'%a[3])
print(cost.FOOTER); print(unpriced.line())
