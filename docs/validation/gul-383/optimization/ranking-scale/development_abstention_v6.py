#!/usr/bin/env python3
"""Select abstention/context preferences only from the original and added development inputs."""
import hashlib,importlib.util,itertools,json,math,re,time
from pathlib import Path
h=Path(__file__).parent;start=time.monotonic();spec=importlib.util.spec_from_file_location('features',h/'calibrate.py');c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)
t=json.loads((h/'raw-quality-vectors.json').read_text());m=json.loads((h/'captured-media.json').read_text());extra=json.loads((h/'development-negatives-v2.json').read_text());corpus=list(zip(t['documents'],t['vectors']))+[(d,d['vector']) for d in m['documents']]
queries=t['queries']+m['queries']
queries += [dict(q,id='document-intent-'+q['id'],group='document_paraphrase',expected=['en-'+q['id'].rsplit('-',1)[1]]) for q in m['queries'] if q['group']=='audio_paraphrase']
queries += [dict(q,id='explicit-'+q['id'],group='explicit_audio',query='audio recording: '+q['query']) for q in m['queries'] if q['group']=='audio_paraphrase']
short=json.loads((h/'development-negatives-v3.json').read_text());queries+=extra['queries']+short['queries'];prepared=[]
for q in queries:
 if q['group'] in ['scanned','media_timestamp']:continue
 qv=q.get('vector') or t['query_vectors'][q['id']];rows=[];hint=None;words=set(re.findall('[a-z]+',q['query'].lower()))
 for kind,en,zh in [('image',['image','photo','screenshot'],['图片','照片','截图']),('audio',['audio','recording'],['音频','录音']),('video',['video','movie'],['视频','影片']),('text',['pdf','document'],['文档'])]:
  if words.intersection(en) or any(w in q['query'] for w in zh):hint=kind;break
 script=sum('\u3400'<=ch<='\u9fff' for ch in q['query'])>=2;identifier=False
 for d,v in corpus:
  kind=d['kind'] if d['kind'] in ['audio','image'] else 'text';cov,phrase,identified,exact=c.features(q['query'],d['text'] if kind=='text' else '');identifier|=identified
  if identified and not exact:continue
  cosine=sum(x*y for x,y in zip(qv,v));bucket='cjk' if kind=='text' and sum('\u3400'<=ch<='\u9fff' for ch in d['text'])>=2 else kind
  rows.append(dict(id=d['id'],kind=kind,bucket=bucket,cosine=cosine,coverage=cov,phrase=phrase,exact=exact,accepted=exact if identified else cov>=.5))
 values=[r['cosine'] for r in rows];mean=sum(values)/len(values) if values else 0;variance=max(.0004,sum((v-mean)**2 for v in values)/len(values)) if values else .0004
 for row in rows:
  bucket=[r['cosine'] for r in rows if r['bucket']==row['bucket']];n=len(bucket);bm=sum(bucket)/n;bv=sum((v-bm)**2 for v in bucket)/n;sm=(sum(bucket)+4*mean)/(n+4);sv=(n*bv+4*variance)/(n+4)
  calibrated=max(0,min(1,mean+(row['cosine']-sm)*math.sqrt(variance/max(.0004,sv)))) if n<len(values) else row['cosine'];row['adjustment']=.55*.25*(calibrated-row['cosine'])
 peaks=sorted(values,reverse=True);prepared.append(dict(query=q,rows=rows,hint=hint,script=script,identifier=identifier,complete=any(r['coverage']==1 for r in rows),literal=any(r['coverage']==1 and r['phrase'] for r in rows),peak=peaks[0] if peaks else 0,margin=peaks[0]-peaks[1] if len(peaks)>1 else None))
baseline=json.loads((h/'ranking-before-development-development-v2.json').read_text());base={k:sum(1/x['rank'] if x['rank'] else 0 for x in baseline['rows'] if x['group']==k)/sum(x['group']==k for x in baseline['rows']) for k in {x['group'] for x in baseline['rows']}}
policies=[(s,.45,.04) for s in [.675,.7,.725,.75,.775]];groups=sorted({p['query']['group'] for p in prepared});trials=[]
for prior,scriptBonus,audio in itertools.product([0,.025,.05,.075,.1],[0,.025,.05],[0,.025]):
 predictions=[]
 for p in prepared:
  modes=[]
  for confident in [False,True]:
   scored=[]
   for r in p['rows']:
    if not r['accepted'] and (r['cosine']<.45 or not confident):continue
    literal=r['coverage']==1 and r['phrase'];cosine=max(0,min(1,r['cosine']))
    if r['exact']:score=3+.01*cosine
    elif literal:score=1+.01*cosine
    else:score=.55*cosine+.12*r['phrase']+.1*(r['coverage']==1)+r['adjustment']+.1*(p['hint']==r['kind'])+audio*(r['kind']=='audio')+(prior+scriptBonus*((r['bucket']=='cjk')==p['script']))*(p['hint'] is None and r['kind']=='text')
    scored.append((score,r['id'],r['bucket']))
   scored.sort(key=lambda r:(-r[0],r[1]))
   if not p['identifier'] and p['hint'] is None:
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
  trials.append(dict(prior=prior,scriptBonus=scriptBonus,audio=audio,strong=absolute,floor=floor,margin=margin,groups=gs,eligible=eligible))
valid=[r for r in trials if r['eligible']]
def objective(r):
 gs=[g for k,g in r['groups'].items() if 'no_answer' not in k];return (-sum(g['fp'] for k,g in r['groups'].items() if 'no_answer' in k),round(min(g['correct']/g['n'] for g in gs),12),round(sum(g['rr']/g['n'] for g in gs),12),r['strong'],r['margin'],r['floor'],-r['prior'],-r['scriptBonus'],-r['audio'])
selected=max(valid,key=objective) if valid else None
report=dict(scope='546 development queries/102 sources, including240 added development negatives. Eligibility also requires each positive group MRR >= actual original-source Swift baseline; original missing-format groups stay in the separate175-positive oracle. No frozen labels/captures opened. Approximate Python production-feature replay; explicit-audio sensitivity stratum retains reused query vectors and is not a new real-model validation.',fixed=dict(semantic_weight=.55,calibration_strength=.25,full_bonus=.1,partial_penalty=0,hint_bonus=.1,cap=2,semantic_floor=.45,contract='Lexical overlap never subtracts score at equal cosine. Keep soft language/modality diversification; explicit identifiers/intent retain their existing bypass. Minimize development false positives, then maximize worst recall and equally weighted group MRR, subject to no group MRR regression against the actual original-source baseline. Keep the existing .45 weak floor/.04 distinct-file margin contract fixed. At equal development metrics prefer the stricter absolute gate. Modality-specific gates were evaluated separately and rejected because they added parameters without improving development metrics.'),inputs={n:hashlib.sha256((h/n).read_bytes()).hexdigest() for n in ['raw-quality-vectors.json','captured-media.json','development-negatives-v2.json','development-negatives-v3.json','ranking-before-development-development-v2.json']},selected=selected,objective=list(objective(selected)) if selected else None,eligible_candidates=len(valid),candidate_count=len(trials),wall_seconds=time.monotonic()-start,trials=trials)
(h/'development-abstention-trials-v6.json').write_text(json.dumps(report,separators=(',',':'))+'\n');print(json.dumps(selected,indent=2));print('eligible',len(valid),'wall',report['wall_seconds'])
