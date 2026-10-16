import hashlib,json
from pathlib import Path
h=Path('docs/validation/gul-383/optimization/ranking-scale');paths=sorted(h.glob('rework-development-trials*.json'));trials=[]
for p in paths:
 for r in json.loads(p.read_text())['trials']:
  if r.get('eligible') and 'document_paraphrase' in r['groups']:trials.append(dict(r,source=p.name))
def key(r):
 gs=[g for k,g in r['groups'].items() if 'no_answer' not in k]
 return (round(r['groups']['document_paraphrase']['rr']/r['groups']['document_paraphrase']['n'],12),round(min(g['correct']/g['n'] for g in gs),12),round(min(g['rr']/g['n'] for g in gs),12),round(sum(g['rr'] for g in gs),12),-r.get('prior',0),-r.get('scriptBonus',0),-r.get('hintBonus',.04),-r['strength'])
s=max(trials,key=key)
result=dict(selected=s,objective=list(key(s)),selection='Union of all eligible development candidates with the added ordinary-document stratum. Round metric ties to 12 decimals before comparing recall, minimum group MRR, aggregate RR and smaller preferences. This prevents floating summation noise from overriding the declared objective. No frozen holdout input is read.',inputs={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in paths})
(h/'rework-selection.json').write_text(json.dumps(result,indent=2)+'\n');print({k:v for k,v in s.items() if k!='groups'});print({k:(g['correct'],g['n'],round(g['rr']/g['n'],3)) for k,g in s['groups'].items()})
