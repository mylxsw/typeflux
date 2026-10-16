#!/usr/bin/env python3
"""Development-only fusion study. Held-out files are deliberately never opened."""
import hashlib, importlib.util, itertools, json, math, time
from pathlib import Path
HERE = Path(__file__).parent
started = time.monotonic()
spec = importlib.util.spec_from_file_location('features', HERE / 'calibrate.py')
c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
t = json.loads((HERE / 'raw-quality-vectors.json').read_text())
m = json.loads((HERE / 'captured-media.json').read_text())
corpus = list(zip(t['documents'], t['vectors'])) + [(d, d['vector']) for d in m['documents']]
prepared = []
queries = t['queries'] + m['queries']
# Explicit source intent and ordinary document questions are separate development strata.
# Keep the original unqualified audio targets too; identical wording can name multiple relevant sources.
queries += [dict(q, id='document-intent-'+q['id'], group='document_paraphrase', expected=['en-'+q['id'].rsplit('-',1)[1]])
            for q in m['queries'] if q['group']=='audio_paraphrase']
queries += [dict(q, id='explicit-'+q['id'], group='explicit_audio', query='audio recording: '+q['query'])
            for q in m['queries'] if q['group']=='audio_paraphrase']
for q in queries:
    if q['group'] in ['scanned', 'media_timestamp']: continue
    qv = q.get('vector') or t['query_vectors'][q['id']]
    rows = []
    for d, v in corpus:
        kind = d['kind'] if d['kind'] in ['audio', 'image'] else 'text'
        cov, phrase, identifier, exact = c.features(q['query'], d['text'] if kind == 'text' else '')
        accepted = exact if identifier else cov >= .5
        if identifier and not exact: continue
        # Retain weak overlap for semantic fusion; it never passes the lexical-only answer gate.
        bucket = 'cjk' if kind == 'text' and sum('\u3400' <= x <= '\u9fff' for x in d['text']) >= 2 else kind
        cosine = sum(a*b for a,b in zip(qv,v))
        rows.append(dict(id=d['id'],kind=kind,bucket=bucket,cosine=cosine,coverage=cov,phrase=phrase,exact=exact,accepted=accepted))
    allv=[r['cosine'] for r in rows]; gm=sum(allv)/len(allv) if allv else 0
    gv=max(.0004,sum((v-gm)**2 for v in allv)/len(allv)) if allv else .0004
    buckets={b:[r['cosine'] for r in rows if r['bucket']==b] for b in {r['bucket'] for r in rows}}
    peaks=sorted(allv,reverse=True)
    confident=any(r['coverage']==1 for r in rows) or (peaks and peaks[0]>=.675) or (len(peaks)>1 and peaks[0]>=.45 and peaks[0]-peaks[1]>=.04)
    for r in rows:
        vals=buckets[r['bucket']];n=len(vals);mean=sum(vals)/n;var=sum((v-mean)**2 for v in vals)/n
        sm=(sum(vals)+4*gm)/(n+4);sv=(n*var+4*gv)/(n+4)
        calibrated=max(0,min(1,gm+(r['cosine']-sm)*math.sqrt(gv/max(.0004,sv)))) if n<len(allv) else r['cosine']
        r['delta']=calibrated-r['cosine']
    hint = 'audio' if any(w in q['query'].lower().split() for w in ['audio','recording:']) else ('image' if any(w in q['query'].lower().split() for w in ['image','photo']) else None)
    script = sum('\u3400' <= x <= '\u9fff' for x in q['query']) >= 2
    for r in rows:
        r['hint'] = hint
        r['scriptMatch'] = (r['bucket']=='cjk') == script
    prepared.append((q,[r for r in rows if r['accepted'] or (r['cosine']>=.45 and confident)]))
trials=[]
for strength,prior,scriptBonus,cap,audio,overlap,full in itertools.product([0,.25,.5,1],[0,.025,.05],[0,.025],[0,2,3],[0,.025],[0,.10,.18,.25],[0,.1,.35]):
    weight,coverage,penalty,hintBonus = .55,0,0,.1
    groups={}
    for q, rows in prepared:
        scored=[]
        for r in rows:
            cov=r['coverage']
            hint=hintBonus if r['hint']==r['kind'] else 0
            default = (prior + scriptBonus*r['scriptMatch']) if r['hint'] is None and r['kind']=='text' else 0
            score=3+.01*r['cosine'] if r['exact'] else weight*(max(0,r['cosine'])+strength*r['delta'])+coverage*cov**2+.12*r['phrase']+full*(cov==1)-penalty*(0<cov<1)+audio*(r['kind']=='audio')+hint+default+overlap*(cov>0)
            scored.append((score,r['id'],r['bucket']))
        scored.sort(reverse=True)
        if cap and not any(r['hint'] is not None or r['exact'] for r in rows):
            counts={};diverse=[];rest=[]
            for row in scored:
                bucket=row[2]
                if counts.get(bucket,0)<cap:
                    diverse.append(row);counts[bucket]=counts.get(bucket,0)+1
                else:rest.append(row)
            scored=diverse+rest
        hits=[r[1] for r in scored[:5]]
        rank=next((i+1 for i,k in enumerate(hits) if k in q['expected']),None)
        g=groups.setdefault(q['group'],dict(n=0,correct=0,rr=0,fp=0));g['n']+=1;g['correct']+=rank is not None;g['rr']+=1/rank if rank else 0;g['fp']+=bool(hits) and not q['expected']
    eligible=all(g['correct']/g['n']>=.85 for k,g in groups.items() if 'no_answer' not in k) and all(g['fp']/g['n']<=.05 for k,g in groups.items() if 'no_answer' in k)
    trials.append(dict(strength=strength,weight=weight,full=full,penalty=penalty,coverage=coverage,audio=audio,prior=prior,scriptBonus=scriptBonus,hintBonus=hintBonus,cap=cap,overlap=overlap,groups=groups,eligible=eligible))
valid=[r for r in trials if r['eligible']]
def objective(r):
    gs=[g for k,g in r['groups'].items() if 'no_answer' not in k]
    return (r['groups']['document_paraphrase']['rr']/r['groups']['document_paraphrase']['n'],min(g['correct']/g['n'] for g in gs), min(g['rr']/g['n'] for g in gs), sum(g['rr'] for g in gs),-r['prior'],-r['scriptBonus'],-r['hintBonus'],-r['strength'])
selected=max(valid,key=objective) if valid else None
result=dict(scope='306 supported development queries, 102 sources; approximate Python ranking. No holdout opened. Keep original missing-format denominator in separate production oracle.',inputs={n:hashlib.sha256((HERE/n).read_bytes()).hexdigest() for n in ['raw-quality-vectors.json','captured-media.json']},objective='Recall/rejection gates, then ordinary document paraphrase MRR, minimum recall, minimum group MRR and aggregate reciprocal rank; smaller context preferences/calibration break ties. Original ambiguous audio queries remain in all gates; new explicit-audio intent stratum reuses its query vectors as an approximate sensitivity check only.',trials=trials,selected=selected,wall_seconds=time.monotonic()-started)
(HERE/'rework-development-trials.json').write_text(json.dumps(result,separators=(',',':'))+'\n')
print(json.dumps(selected,indent=2));print('wall_seconds',result['wall_seconds'])
