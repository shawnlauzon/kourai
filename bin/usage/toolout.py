"""Tool output size x remaining requests, by tool/command, for agents started since a date: tokens, and an estimated cost.

Usage: python3 -I toolout.py <projects dir> <since-date> [--exclude-self]

<projects dir> is the Claude Code projects folder of the repo; <since-date> is an ISO date
(agents that started before it are skipped); --exclude-self leaves out the most recently started token-auditor transcript (the caller's own).
Cost is an ESTIMATE, ranked by: each output is priced at the cache-read price of the model
that made each later request (cost.py), 5-minute cache assumed warm; cache writes of the output
and output tokens are not counted. A later request with no model name is counted at 0 and
reported on the "unmodelled" count of its row, so that row's cost is a lower bound.
Names and numbers only; writes nothing.
"""
import glob,json,collections,re,sys
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
files=[f for f in glob.glob(P+'/*/subagents/agent-*.jsonl') if not f==SELF]
def key(name,inp):
    if name=='Bash':
        c=inp.get('command','').strip()
        m=re.search(r'([\w\-]+\.sh)',c)
        if m: return 'sh:'+m.group(1)
        w=re.split(r'\s+',c)[0] if c else ''
        if w in('gh','git','curl','cat','grep','sed','tail','head','jq','python3','rails','flutter','bundle','sleep','aws'): return 'bash:'+w
        return 'bash:other'
    if name.startswith('mcp__trello'): return name.replace('mcp__trello__','trello:')+':'+str(inp.get('action',''))
    return name
agg=collections.defaultdict(lambda:[0,0.0,0.0,0.0,0])  # calls, sum tokens, sum token*remaining requests, est $, unmodelled later requests
bytype=collections.defaultdict(float)
for f in files:
    try: meta=json.load(open(f[:-6]+'.meta.json'))
    except Exception: continue
    ty=meta.get('agentType','?')
    seen=set(); pend={}; res=[]; n=0; start=None; rates=[]  # rates[i]: cache-read $/token of request i+1, or None
    for line in open(f):
        try:o=json.loads(line)
        except Exception: continue
        if start is None: start=o.get('timestamp','')
        m=o.get('message',{}) if isinstance(o.get('message'),dict) else {}
        if o.get('type')=='assistant':
            mid=m.get('id')
            if mid not in seen:
                seen.add(mid); n+=1
                mdl=m.get('model'); u=m.get('usage') or {}
                if mdl:
                    rates.append(cost.cache_read_rate(mdl,u)); unpriced.note(cost.request_key(mdl,u),cost.rates_for(cost.request_key(mdl,u))[1])
                else: rates.append(None)
            for b in m.get('content',[]) if isinstance(m.get('content'),list) else []:
                if isinstance(b,dict) and b.get('type')=='tool_use': pend[b['id']]=key(b['name'],b.get('input',{}))
        elif o.get('type')=='user' and isinstance(m.get('content'),list):
            for b in m['content']:
                if isinstance(b,dict) and b.get('type')=='tool_result' and b.get('tool_use_id') in pend:
                    c=b.get('content'); 
                    L=sum(len(x.get('text','')) for x in c if isinstance(x,dict)) if isinstance(c,list) else len(c or '')
                    res.append((pend[b['tool_use_id']],L/3.5,n))
    if not start or start<SINCE: continue
    for k,tok,i in res:
        a=agg[k];a[0]+=1;a[1]+=tok;a[2]+=tok*(n-i); bytype[ty]+=tok*(n-i)
        later=rates[i:]; a[3]+=tok*sum(r for r in later if r is not None); a[4]+=sum(1 for r in later if r is None)
tot=sum(a[2] for a in agg.values()) or 1
totusd=sum(a[3] for a in agg.values())
print('tool output re-read from cache: estimated $%.2f (cache-read price only), %.0fM tool-output tokens x requests'%(totusd,tot/1e6))
for k,a in sorted(agg.items(),key=lambda x:-x[1][3])[:22]:
    print('%-45s calls %5d  avg %6.0f tok  est $%7.2f (%4.1f%%)  carried %7.1fM tokens (%4.1f%%)  unmodelled %d'%(k,a[0],a[1]/a[0],a[3],100*a[3]/max(totusd,1e-9),a[2]/1e6,100*a[2]/tot,a[4]))
print(cost.FOOTER); print(unpriced.line())
