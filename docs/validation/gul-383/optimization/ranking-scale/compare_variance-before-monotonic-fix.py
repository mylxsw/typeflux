#!/usr/bin/env python3
"""Development-only score-distribution trials. Never opens held-out labels/vectors."""
import runpy, math, json
from pathlib import Path
ns=runpy.run_path(str(Path(__file__).parent / 'compare_mixed_calibration.py'));prepared=ns['prepared']
results=[]
for mode in ['variance','class-rrf','mean']:
 for offset in [0,.025,.05]:
  groups={}
  for q,rs in prepared:
   v=[r['cosine'] for r in rs]; gm=sum(v)/len(v) if v else 0; gv=max(.0004,sum((x-gm)**2 for x in v)/len(v)) if v else .0004
   buckets={b:[r['cosine'] for r in rs if r['bucket']==b] for b in {r['bucket'] for r in rs}}
   ranks={}
   for b in buckets:
    for i,r in enumerate(sorted((r for r in rs if r['bucket']==b),key=lambda r:-r['cosine'])):ranks[r['id']]=i+1
   peak=sorted(v,reverse=True);conf=any(r['complete'] for r in rs) or (peak and peak[0]>=.675) or(len(peak)>1 and peak[0]>=.45 and peak[0]-peak[1]>=.04)
   out=[]
   for r in rs:
    if not (r['accepted'] or(r['cosine']>=.45 and conf)):continue
    vals=buckets[r['bucket']];n=len(vals);mean=sum(vals)/n;var=sum((x-mean)**2 for x in vals)/n
    sm=(sum(vals)+4*gm)/(n+4);sv=(n*var+4*gv)/(n+4)
    cosine=gm+(r['cosine']-sm)*math.sqrt(gv/max(.0004,sv)) if mode=='variance' else r['cosine']+n/(n+4)*(gm-mean)
    if mode=='class-rrf':cosine=1/(1+ranks[r['id']])
    score=1+.01*r['cosine'] if r['exact'] else .55*max(0,cosine)+r['lexical']+r['hint']+(offset if r['kind']=='audio' else 0)
    out.append((score,r['id']))
   out.sort(reverse=True);hits=[x[1] for x in out[:5]];rank=next((i+1 for i,x in enumerate(hits) if x in q['expected']),None)
   g=groups.setdefault(q['group'],dict(n=0,correct=0,rr=0,fp=0));g['n']+=1;g['correct']+=rank is not None;g['rr']+=1/rank if rank else 0;g['fp']+=bool(hits) and not q['expected']
  result=dict(mode=mode,offset=offset,groups=groups);results.append(result)
  print(mode,offset,{k:(v['correct'],round(v['rr']/v['n'],2),v['fp']) for k,v in groups.items()})
eligible=[r for r in results if all(g['correct']/g['n']>=.85 for k,g in r['groups'].items() if 'no_answer' not in k) and all(g['fp']/g['n']<=.05 for k,g in r['groups'].items() if 'no_answer' in k)]
selected=max(eligible,key=lambda r:(min(g['correct']/g['n'] for k,g in r['groups'].items() if 'no_answer' not in k),sum(g['rr'] for g in r['groups'].values())))
ns['HERE'].joinpath('variance-development-trials.json').write_text(json.dumps(dict(candidates=results,selected=selected,scope='All 256 supported development queries over the combined 102-source text/media corpus. Unsupported groups stay in original 200-query production reporting. Held-out files are never read; selection is not a held-out result.'),indent=2)+'\n')
