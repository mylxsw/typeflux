#!/usr/bin/env python3
"""Select small fusion parameters on development fixtures; never read the final holdout."""
import importlib.util,json,math
from pathlib import Path
here=Path(__file__).parent
spec=importlib.util.spec_from_file_location('cal',here/'calibrate.py');c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)
t=json.loads((here/'raw-quality-vectors.json').read_text());m=json.loads((here/'captured-media.json').read_text())
prepared=[]
for corpus,queries in [([(d,v) for d,v in zip(t['documents'],t['vectors'])],t['queries']), ([(d,v) for d,v in zip(t['documents'],t['vectors'])]+[(d,d['vector']) for d in m['documents']],m['queries'])]:
 for q in queries:
  if q['group'] in ['scanned','media_timestamp']:continue
  qv=q.get('vector') or t['query_vectors'][q['id']]
  rows=[]
  for d,v in corpus:
   kind=d['kind'] if d['kind'] in ['audio','image'] else 'text'
   cov,phrase,identifier,exact=c.features(q['query'],d['text'] if kind=='text' else '')
   accepted=exact if identifier else cov>=.5
   if identifier and not exact:continue
   if not accepted:cov=0;phrase=False
   cosine=sum(a*b for a,b in zip(qv,v))
   lexical=.3*cov**2+.12*phrase+.35*(cov==1)-.18*(0<cov<1)
   hint=.04 if kind=='image' and any(x in q['query'].split() for x in ['photo','image']) else 0
   rows.append(dict(id=d['id'],cosine=cosine,lexical=lexical,accepted=accepted,complete=cov==1,exact=exact,kind=kind,hint=hint))
  prepared.append((q,rows))
results=[]
for absolute in [.65,.675,.7]:
 for margin in [.04,.06,.08]:
  for offset in [0,.025,.05,.075]:
   groups={}
   for q,rows in prepared:
    peaks=sorted([r['cosine'] for r in rows],reverse=True)
    confident=any(r['complete'] for r in rows) or (peaks and peaks[0]>=absolute) or (len(peaks)>1 and peaks[0]-peaks[1]>=margin)
    candidates=[r for r in rows if r['accepted'] or (r['cosine']>=.45 and confident)]
    scored=sorted(candidates,key=lambda r:-(1+.01*r['cosine'] if r['exact'] else .55*max(0,r['cosine'])+r['lexical']+r['hint']+(offset if r['kind']=='audio' else 0)))
    rank=next((i+1 for i,r in enumerate(scored[:5]) if r['id'] in q['expected']),None)
    g=groups.setdefault(q['group'],dict(n=0,correct=0,rr=0,false=0));g['n']+=1;g['correct']+=rank is not None;g['rr']+=1/rank if rank else 0;g['false']+=bool(scored) if not q['expected'] else 0
   metrics={g:dict(n=r['n'],recall=r['correct']/r['n'],mrr=r['rr']/r['n'],false_positive_rate=r['false']/r['n']) for g,r in groups.items()}
   positive=[r for g,r in metrics.items() if 'no_answer' not in g]
   results.append(dict(absolute=absolute,margin=margin,audio_offset=offset,groups=metrics,min_recall=min(r['recall'] for r in positive),mean_mrr=sum(r['mrr'] for r in positive)/len(positive),max_false_positive=max(r['false_positive_rate'] for g,r in metrics.items() if 'no_answer' in g)))
eligible=[r for r in results if r['max_false_positive']<=.05]
selected=max(eligible,key=lambda r:(r['min_recall'],r['mean_mrr'],-r['audio_offset'],-r['absolute'],-r['margin']))
(here/'modality-calibration.json').write_text(json.dumps(dict(training='Original 200 plus 106 media development queries, excluding explicitly unsupported scan/media_timestamp groups from selection. The already observed first wording holdout is diagnostic; final-holdout-labels.json is never read here.',candidates=results,selected=selected),indent=2)+'\n')
print(json.dumps(selected,indent=2))
