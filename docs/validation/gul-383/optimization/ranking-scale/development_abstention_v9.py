#!/usr/bin/env python3
"""Select on two development conditions, preserving all original query denominators."""
import gzip, hashlib, importlib.util, itertools, json, math, re, time
from pathlib import Path
import numpy as np
h=Path(__file__).parent; started=time.monotonic()
spec=importlib.util.spec_from_file_location('features',h/'calibrate.py'); c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)
# Intent code is frozen from the v8 development experiment, not from any held-out capture.
front=(h/'development_abstention_v8.py').read_text(); intent_code=front[front.index("stop={'please'}"):front.index('for p in prepared:')];exec(intent_code)
d=json.loads((h/'development-v9-vectors.json').read_text()); docs=d['documents']; queries=d['queries']; groups=sorted({q['group'] for q in queries}); qi={g:np.array([i for i,q in enumerate(queries) if q['group']==g]) for g in groups}
qv=np.array([q['vector'] for q in queries]); dv=np.array([x['vector'] for x in docs]); cosine=qv@dv.T; nq,nd=cosine.shape
coverage=np.zeros((nq,nd)); phrase=np.zeros((nq,nd),dtype=bool); exact=np.zeros((nq,nd),dtype=bool); identifiers=np.zeros(nq,dtype=bool); valid=np.ones((nq,nd),dtype=bool)
kinds=[x['kind'] if x['kind'] in ['image','audio'] else 'text' for x in docs]; buckets=np.array(['cjk' if kind=='text' and len(re.findall('[\u3400-\u9fff]',x['text']))>=2 else kind for x,kind in zip(docs,kinds)]); expected=np.array([[x['id'] in q['expected'] for x in docs] for q in queries]); hint=[intent(q['query']) for q in queries]
matching=np.array([[z==kind for kind in kinds] for z in hint]); script=np.array([len(re.findall('[\u3400-\u9fff]',q['query']))>=2 for q in queries]); script_match=(script[:,None]==(buckets=='cjk')) & np.isin(buckets,['text','cjk'])[None,:] & np.array([z is None for z in hint])[:,None]
for i,q in enumerate(queries):
 for j,x in enumerate(docs):
  cov,ph,identified,ex=c.features(q['query'],x['text'] if kinds[j]=='text' else '');coverage[i,j]=cov;phrase[i,j]=ph;exact[i,j]=ex;identifiers[i]|=identified;valid[i,j]=not identified or ex
accepted=np.where(identifiers[:,None],exact,coverage>=.5)
policies=list(itertools.product([.7,.725,.75,.775,.8],[.45,.6,.65,.675,.7],[.01,.02,.03,.04]));conditions=[]
for name,n,baseline_file in [('original',102,'ranking-before-development-development-v2.json'),('expanded',nd,'ranking-before-development-v9-development-v9.json')]:
 ncos=cosine[:,:n];nvalid=valid[:,:n]; values=np.where(nvalid,ncos,-np.inf); peaks=np.sort(values,axis=1)[:,::-1];complete=np.any((coverage[:,:n]==1)&nvalid,axis=1);conf=np.array([complete | (peaks[:,0]>=strong) | ((peaks[:,0]>=floor)&((peaks[:,0]-peaks[:,1])>=gap)) for strong,floor,gap in policies]);cal=[]
 for pooled in [False,True]:
  adjust=np.zeros((nq,n))
  for i in range(nq):
   vals=ncos[i,nvalid[i]];mean=float(np.mean(vals)) if len(vals) else 0;variance=max(.0004,float(np.var(vals))) if len(vals) else .0004
   for j in range(n):
    bmask=(np.isin(buckets[:n],['text','cjk']) if pooled and buckets[j] in ['text','cjk'] else buckets[:n]==buckets[j])&nvalid[i];b= ncos[i,bmask];count=len(b)
    if count and count<len(vals):
     sm=(np.sum(b)+4*mean)/(count+4);sv=(count*np.var(b)+4*variance)/(count+4);v=np.clip(mean+(ncos[i,j]-sm)*math.sqrt(variance/max(.0004,sv)),0,1);adjust[i,j]=.55*(v-ncos[i,j])
  cal.append(adjust)
 rows=json.loads((h/baseline_file).read_text())['rows'];base={g:sum(1/r['rank'] if r['rank'] else 0 for r in rows if r['group']==g)/sum(r['group']==g for r in rows) for g in groups if any(r['group']==g for r in rows)}
 conditions.append(dict(name=name,n=n,conf=conf,cal=cal,base=base))
ids=np.array([x['id'] for x in docs]);order_ids=np.argsort(ids); trials=0;eligible=[];best=None
out=gzip.open(h/'development-abstention-trials-v9.jsonl.gz','wt')
for partial,script_bonus,strength,pooled,unify,hint_bonus in itertools.product([0,.025,.05,.075,.1],[.025,.04,.06],[0,.1,.25],[False,True],[False,True],[.1,.15]):
 # Pooling is irrelevant at zero calibration; do not duplicate it.
 if strength==0 and pooled:continue
 all_metrics=[]; overall_ok=np.ones(len(policies),dtype=bool); objectives=[]
 for condition in conditions:
  n=condition['n']; score=.55*np.clip(cosine[:,:n],0,1)+.12*phrase[:,:n]+.1*(coverage[:,:n]==1)+partial*np.where(coverage[:,:n]<1,coverage[:,:n],0)+script_bonus*script_match[:,:n]+strength*condition['cal'][int(pooled)]+hint_bonus*matching[:,:n]
  score=np.where(exact[:,:n],3+.01*np.clip(cosine[:,:n],0,1),score);score=np.where((coverage[:,:n]==1)&phrase[:,:n]&~exact[:,:n],1+.01*np.clip(cosine[:,:n],0,1),score)
  ranks=[];has=[]
  for mode in [False,True]:
   allowed=valid[:,:n] & (accepted[:,:n] | ((cosine[:,:n]>=.45)&mode));s=np.where(allowed,score,-np.inf); id_order=order_ids[order_ids<n]; order=id_order[np.argsort(-s[:,id_order],axis=1,kind='stable')];r=np.zeros(nq);hit=np.any(allowed,axis=1)
   for i in range(nq):
    sequence=[j for j in order[i] if allowed[i,j]]
    if not identifiers[i] and hint[i] is None:
     head=[];counts={}
     for j in sequence:
      bucket='text' if unify and buckets[j]=='cjk' else str(buckets[j])
      if len(head)<5 and counts.get(bucket,0)<2:head.append(j);counts[bucket]=counts.get(bucket,0)+1
     selected=set(head);sequence=head+[j for j in sequence if j not in selected]
    r[i]=next((1/(k+1) for k,j in enumerate(sequence[:5]) if expected[i,j]),0)
   ranks.append(r);has.append(hit)
  rr=np.where(condition['conf'],ranks[1],ranks[0]);hits=np.where(condition['conf'],has[1],has[0]);ms={}
  for g,ix in qi.items():
   positive=bool(queries[int(ix[0])]['expected']);rec=np.mean(rr[:,ix]>0,axis=1);mrr=np.mean(rr[:,ix],axis=1);fp=np.mean(hits[:,ix],axis=1) if not positive else np.zeros(len(policies)); ms[g]=(rec,mrr,fp,len(ix))
   if positive:overall_ok &= (rec>=.85)&(mrr+1e-9>=condition['base'].get(g,0))
   else:overall_ok &= fp<=.05
  all_metrics.append(ms)
 for k,policy in enumerate(policies):
  gs=[{g:dict(n=values[3],recall=float(values[0][k]),mrr=float(values[1][k]),false_positive=float(values[2][k])) for g,values in ms.items()} for ms in all_metrics]
  record=dict(partial=partial,scriptBonus=script_bonus,strength=strength,pooled=pooled,unified_text_diversity=unify,hintBonus=hint_bonus,strong=policy[0],floor=policy[1],margin=policy[2],conditions=gs,eligible=bool(overall_ok[k]));out.write(json.dumps(record,separators=(',',':'))+'\n');trials+=1
  if not overall_ok[k]:continue
  # Same documented objective as v8, applied to both fixed development conditions.
  pos=[v for gg in gs for g,v in gg.items() if queries[int(qi[g][0])]['expected']];neg=[v for gg in gs for g,v in gg.items() if not queries[int(qi[g][0])]['expected']]
  objective=(-sum(v['false_positive']*v['n'] for v in neg),round(min(v['recall'] for v in pos),12),round(sum(v['mrr'] for v in pos),12),policy[0],-abs(policy[2]-.04),-abs(policy[1]-.45),-partial,-script_bonus,-strength,-pooled,-unify,-hint_bonus);eligible.append(record)
  if best is None or objective>best[0]:best=(objective,record)
out.close();report=dict(scope='Development only, original102 and expanded127 sources; same546 query labels in both conditions, including240 added negatives. Added25 generic office circulars captured with the pinned one-thread CPU helper; original corpus GPU vectors retained. Approximate feature replay, explicit-audio development stratum still reuses generic query vectors. No held-out labels or captures read.',input_sha256={f:hashlib.sha256((h/f).read_bytes()).hexdigest() for f in ['development-v9-vectors.json','ranking-before-development-development-v2.json','ranking-before-development-v9-development-v9.json','development_abstention_v8.py']},candidate_count=trials,eligible_candidates=len(eligible),selected=best[1] if best else None,objective=best[0] if best else None,wall_seconds=time.monotonic()-started)
(h/'development-abstention-selection-v9.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
