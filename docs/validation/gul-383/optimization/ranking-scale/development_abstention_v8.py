#!/usr/bin/env python3
"""DEV-only alternatives: format intent, text-language pooling and soft modality diversification."""
import hashlib, importlib.util, itertools, json, math, re, time
from pathlib import Path
h=Path(__file__).parent;start=time.monotonic()
# Reuse exactly the same 546 development inputs and lexical feature extraction as v7.
front=(h/'development_abstention_v7.py').read_text().split("policies=[",1)[0]
exec(compile(front,str(h/'development_abstention_v7.py'),'exec'))
stop={'please'}
find={'find','show','search','open','locate','play','display','view'}
formats=[('image',['image','images','photo','photos','screenshot','screenshots'],['图片','照片','截图']),('audio',['audio','recording','recordings'],['音频','录音']),('video',['video','videos','movie','movies'],['视频','影片']),('text',['pdf','document','documents'],['文档'])]
def intent(text):
 words=re.findall('[a-z]+',text.lower()); words=[w for w in words if w not in stop]
 for kind,en,zh in formats:
  has=bool(set(words).intersection(en))
  explicit=has and (words[0] in en or words[-1] in en or bool(set(words).intersection(find)) or (len(words)>1 and words[0] in ['which','what'] and words[1] in en) or any(text.lower().startswith(p+' '+word) for p in ['in the','from the'] for word in en))
  explicit |= any(word in text and (text.startswith(word) or text.rstrip('？?。 ').endswith(word) or any(v in text for v in ['找','搜索','查看','显示','打开','寻找']) or text.rstrip('？?。 ').endswith(('在哪','在哪里'))) for word in zh)
  if explicit:return kind
 return None
for p in prepared:
 p['explicit_hint']=intent(p['query']['query'])
 for pooled in [False,True]:
  values=[r['cosine'] for r in p['rows']];mean=sum(values)/len(values) if values else 0;variance=max(.0004,sum((v-mean)**2 for v in values)/len(values)) if values else .0004
  for row in p['rows']:
   same=lambda r: (r['bucket'] in ['text','cjk']) if pooled and row['bucket'] in ['text','cjk'] else r['bucket']==row['bucket']
   bucket=[r['cosine'] for r in p['rows'] if same(r)];n=len(bucket);bm=sum(bucket)/n;bv=sum((v-bm)**2 for v in bucket)/n;sm=(sum(bucket)+4*mean)/(n+4);sv=(n*bv+4*variance)/(n+4)
   calibrated=max(0,min(1,mean+(row['cosine']-sm)*math.sqrt(variance/max(.0004,sv)))) if n<len(values) else row['cosine']
   row['pooled' if pooled else 'separate']=.55*(calibrated-row['cosine'])
policies=[(s,.45,.04) for s in [.675,.7,.725,.75,.775,.8,.825]]
groups=sorted({p['query']['group'] for p in prepared});trials=[]
for prior,scriptBonus,strength,pooled,unify,explicit in itertools.product([0,.025,.05,.075,.1,.1375,.2,.25],[0,.025,.033,.04,.05,.06],[0,.1,.25],[False,True],[False,True],[False,True]):
 if prior+scriptBonus>.325:continue
 predictions=[]
 for p in prepared:
  hint=p['explicit_hint'] if explicit else p['hint'];modes=[]
  for confident in [False,True]:
   scored=[]
   for r in p['rows']:
    if not r['accepted'] and (r['cosine']<.45 or not confident):continue
    literal=r['coverage']==1 and r['phrase'];cosine=max(0,min(1,r['cosine']))
    if r['exact']:score=3+.01*cosine
    elif literal:score=1+.01*cosine
    else:score=.55*cosine+.12*r['phrase']+.1*(r['coverage']==1)+strength*r['pooled' if pooled else 'separate']+.1*(hint==r['kind'])+(prior+scriptBonus*((r['bucket']=='cjk')==p['script']))*(hint is None and r['kind']=='text')
    scored.append((score,r['id'],'text' if unify and r['bucket']=='cjk' else r['bucket']))
   scored.sort(key=lambda r:(-r[0],r[1]))
   if not p['identifier'] and hint is None:
    counts={};head=[]
    for row in scored:
     if len(head)<5 and counts.get(row[2],0)<2:head.append(row);counts[row[2]]=counts.get(row[2],0)+1
    ids={r[1] for r in head};scored=head+[r for r in scored if r[1] not in ids]
   hits=[r[1] for r in scored[:5]];rank=next((i+1 for i,k in enumerate(hits) if k in p['query']['expected']),None);modes.append((rank,bool(hits)))
  predictions.append(modes)
 for absolute,floor,margin in policies:
  gs={g:dict(n=0,correct=0,rr=0,fp=0) for g in groups}
  for p,modes in zip(prepared,predictions):
   confident=p['complete'] or p['peak']>=absolute or (p['margin'] is not None and p['peak']>=floor and p['margin']>=margin)
   rank,hits=modes[int(confident)];g=gs[p['query']['group']];g['n']+=1;g['correct']+=rank is not None;g['rr']+=1/rank if rank else 0;g['fp']+=hits and not p['query']['expected']
  eligible=all(g['rr']/g['n']+1e-9>=base.get(k,0) for k,g in gs.items() if 'no_answer' not in k) and all(g['correct']/g['n']>=.85 for k,g in gs.items() if 'no_answer' not in k) and all(g['fp']/g['n']<=.05 for k,g in gs.items() if 'no_answer' in k)
  trials.append(dict(prior=prior,scriptBonus=scriptBonus,strength=strength,pooled=pooled,unified_text_diversity=unify,explicit_intent=explicit,strong=absolute,groups=gs,eligible=eligible))
valid=[r for r in trials if r['eligible']]
def objective(r):
 gs=[g for k,g in r['groups'].items() if 'no_answer' not in k];return (-sum(g['fp'] for k,g in r['groups'].items() if 'no_answer' in k),round(min(g['correct']/g['n'] for g in gs),12),round(sum(g['rr']/g['n'] for g in gs),12),r['strong'],-r['prior'],-r['scriptBonus'],-r['strength'],-r['pooled'],-r['unified_text_diversity'],-r['explicit_intent'])
selected=max(valid,key=objective) if valid else None
report=dict(scope='Same546 development queries and102 sources, no held-out labels/captures opened. Explore explicit format intent vs incidental mentions, pooled text-language distribution statistics, soft modality-level diversity and legacy-scaled context preferences. Approximate Python feature replay, explicit-audio stratum still reuses vectors. No production change unless a selected policy passes actual Swift development replay before freezing a new held-out set.',inputs={n:hashlib.sha256((h/n).read_bytes()).hexdigest() for n in ['raw-quality-vectors.json','captured-media.json','development-negatives-v2.json','development-negatives-v3.json','ranking-before-development-development-v2.json']},selected=selected,eligible_candidates=len(valid),candidate_count=len(trials),wall_seconds=time.monotonic()-start,trials=trials)
(h/'development-abstention-trials-v8.json').write_text(json.dumps(report,separators=(',',':'))+'\n');print(json.dumps(selected,indent=2));print('eligible',len(valid),'wall',report['wall_seconds'])
