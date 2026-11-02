"""Per agent type, the cost of the context read above a cap, and the requests over it.

Usage: python3 -I excess.py <projects dir> <since-date> <cap in thousands of tokens> [--exclude-self]

<projects dir> is the Claude Code projects folder of the repo; <since-date> is an ISO date
(agents that started before it are skipped); --exclude-self leaves out the most recently started token-auditor transcript (the caller's own).
Cost is model and token type weighted (cost.py). The cost above the cap is an estimate: the tokens
above the cap priced at the request model's cache-read price (the context is re-read from cache).
Ranked by that cost; tokens beside it. Names and numbers only; writes nothing.
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
(P,SINCE,CAPK),EX=_args(1)
SELF=self_file(P) if EX else None
CAP=int(CAPK)*1000
ex=collections.Counter(); tot=collections.Counter(); n=collections.Counter(); over=collections.Counter(); usd=collections.Counter(); exusd=collections.Counter()
def scan(f,ty):
    seen=set(); first=None
    for line in open(f):
        try:o=json.loads(line)
        except Exception: continue
        if first is None: first=o.get('timestamp','')
        if o.get('type')!='assistant': continue
        m=o.get('message',{}); mid=m.get('id')
        if mid in seen or not isinstance(m,dict): continue
        seen.add(mid); u=m.get('usage',{})
        c=cost.context(u)
        if first>=SINCE:
            tot[ty]+=c
            d,pr=cost.request_cost(m.get('model'),u); unpriced.note(cost.request_key(m.get('model'),u),pr); usd[ty]+=d
            if c>CAP: ex[ty]+=c-CAP; over[ty]+=1; exusd[ty]+=(c-CAP)*cost.cache_read_rate(m.get('model'),u)
            n[ty]+=1
for f in glob.glob(P+'/*/subagents/agent-*.jsonl'):
    if f==SELF: continue
    try: ty=json.load(open(f[:-6]+'.meta.json')).get('agentType','?')
    except Exception: continue
    scan(f,ty)
for f in glob.glob(P+'/*.jsonl'):
    scan(f,'main')
print('cap',CAP//1000,'k')
for t,v in exusd.most_common(10): print('%-18s above cap $%7.2f of $%7.0f total (%2.0f%%)  tokens above %6.0fM of %6.0fM  requests above %5d of %5d'%(t,v,usd[t],100*v/max(usd[t],1e-9),ex[t]/1e6,tot[t]/1e6,over[t],n[t]))
print('all above cap $%.2f of $%.0f; tokens %.0fM of %.0fM'%(sum(exusd.values()),sum(usd.values()),sum(ex.values())/1e6,sum(tot.values())/1e6))
print(cost.FOOTER); print(unpriced.line())
