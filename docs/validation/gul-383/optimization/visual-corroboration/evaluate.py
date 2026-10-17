"""Pre-implementation arithmetic on frozen real vectors; no inference or fitted cutoff."""
import json, math, sqlite3, struct
from contextlib import closing
from pathlib import Path
here=Path(__file__).resolve().parent
old=here.parent/'media-isolation/visual-diagnosis'
with closing(sqlite3.connect('file:'+str(old/'fixed-capture/synthetic.sqlite')+'?immutable=1',uri=True)) as db:
 rows=db.execute('select segment_kind,vector from chunks').fetchall()
vectors={k:struct.unpack('<768f',v) for k,v in rows}
def unit(v):
 n=math.sqrt(sum(x*x for x in v));return [x/n for x in v]
a,b=map(unit,(vectors['image'],vectors['image-ocr']))
fused=unit([x+y for x,y in zip(a,b)])
def dot(a,b):return sum(x*y for x,y in zip(a,b))
fixed=json.loads((old/'fixed-capture/query-vector.json').read_text())
replay=json.loads((old/'offline-replay.json').read_text())
scale=here.parent/'ranking-scale'
original=json.loads((scale/'raw-quality-vectors.json').read_text())
media=json.loads((scale/'captured-media.json').read_text())
neg=[]
for source in [original,media]:
 for q in source['queries']:
  if q['expected']:continue
  v=q.get('vector') or source['query_vectors'][q['id']]
  raw=[dot(v,a),dot(v,b)]; joint=dot(v,fused)
  eligible=min(raw)>=.45
  neg.append(dict(id=q['id'],group=q['group'],expected=q['expected'],raw=raw,joint=joint,corroborated=eligible and joint>=.70))
result=dict(mode='Pre-implementation equal unit-vector sum; unchanged .45/.70 gates; no new labels',fixed=dict(raw=[dot(fixed,a),dot(fixed,b)],joint=dot(fixed,fused)),negatives=neg,color_pairs=replay['existing_image_color_pairs'],note='Color oracle has no OCR: same single-modality gates; original text/number/quote gates unchanged by design. Production replay required.')
(here/'preflight.json').write_text(json.dumps(result,indent=2)+'\n')
assert result['fixed']['joint']>=.70
assert len(neg)==50 and not any(n['corroborated'] for n in neg)
assert all(c['single_file_confident']==c['matches_frozen_target'] for c in result['color_pairs'])
print('Fixed',result['fixed'],'negatives',len(neg),'new false positives',sum(n['corroborated'] for n in neg),'colors',len(result['color_pairs']))
