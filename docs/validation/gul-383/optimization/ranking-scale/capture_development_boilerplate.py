#!/usr/bin/env python3
"""Add generated office-footer distractors to DEV; never open held-out fixtures."""
import hashlib,importlib.util,json,os,time
from pathlib import Path
h=Path(__file__).parent;root=Path.cwd();start=time.monotonic();out=h/'development-boilerplate-v9.json'
assert not out.exists(), 'Preserve the previous actual capture'
labels=[dict(id=f'dev-circular-{i:02d}',kind='text',text=f'Office circular DR-{6200+i}. Local teams use the normal register for requests and routine updates. Entry categories cover departmental routing, shared supplies, file locations and appointment notes. Status: available. Responsibility: duty coordinator.') for i in range(25)]
(h/'development-boilerplate-v9-labels.json').write_text(json.dumps(dict(scope='New DEV-only generic office boilerplate; fictional distractors with no new expected-answer labels. Original546 development queries and their labels stay unchanged.',documents=labels),indent=2)+'\n')
spec=importlib.util.spec_from_file_location('worker',h/'measure_batch.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
os.environ['VECLIB_MAXIMUM_THREADS']='1';os.environ['OMP_NUM_THREADS']='1'
helper=root/'.build/semantic/TypefluxSemanticHelper';model=root/'.build/semantic/embeddinggemma-2-Q8_0.gguf';worker=m.Worker([helper,model,'--background']);docs=[]
try:
 for doc in labels:
  response,_=worker.request(dict(texts=['title: '+doc['id']+'.txt | text: '+doc['text']]))
  assert not response.get('error'), 'Model rejected a development input'
  vector=response['embeddings'][0];assert len(vector)==768
  docs.append(dict(doc,vector=vector,duration=0))
finally:worker.close()
result=dict(documents=docs,source_backend='cpu-one-thread',helper_sha256=hashlib.sha256(helper.read_bytes()).hexdigest(),model_sha256=hashlib.sha256(model.read_bytes()).hexdigest(),wall_seconds=time.monotonic()-start,scope='Actual pinned CPU embeddings of new development distractors. No query labels/denominators or held-out files changed.')
out.write_text(json.dumps(result,separators=(',',':'))+'\n')
old=json.loads((h/'development-v2-vectors.json').read_text());short=json.loads((h/'development-negatives-v3.json').read_text());queries=old['queries']+short['queries'];assert len(queries)==546
capture=dict(documents=old['documents']+docs,queries=queries,scope='Same546 DEV queries plus25 new boilerplate distractor sources. Original development-v2 capture stays unchanged; this is a second corpus condition. Source encoders mix the retained GPU reference and new CPU distractors, so model/backend scope is explicit.')
(h/'development-v9-vectors.json').write_text(json.dumps(capture,separators=(',',':'))+'\n')
print(json.dumps(dict(documents=len(capture['documents']),queries=len(queries),wall_seconds=result['wall_seconds'])))
