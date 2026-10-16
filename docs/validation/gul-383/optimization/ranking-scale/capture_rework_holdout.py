#!/usr/bin/env python3
"""Capture the new frozen sources and queries once; this script never tunes ranking parameters."""
import argparse,hashlib,importlib.util,json,subprocess,wave
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
for arg in ['helper','model','projector','assets']:p.add_argument('--'+arg,type=Path,required=True)
a=p.parse_args();here=Path(__file__).parent;labels=json.loads((here/'rework-frozen-labels.json').read_text())
assert not (here/"rework-frozen-vectors.json").exists(), "Never overwrite a frozen capture"
a.assets.mkdir(parents=True,exist_ok=True)
subprocess.run(['/usr/bin/swift',str(here/'draw_holdout.swift'),str(here/'rework-frozen-labels.json'),str(a.assets)],check=True)
spec=importlib.util.spec_from_file_location('worker',here/'measure_batch.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
worker=m.Worker([a.helper.resolve(),a.model.resolve(),a.projector.resolve()]);documents=[];queries=[]
try:
 for d in labels['documents']:
  d=dict(d)
  if d['kind']=='text':reply,_=worker.request(dict(texts=['title: '+d['id']+'.txt | text: '+d['text']]));d['duration']=0
  else:
   asset=a.assets/(d['id']+('.wav' if d['kind']=='audio' else '.png'))
   if d['kind']=='audio':
    aiff=asset.with_suffix('.aiff')
    subprocess.run(['say','-v','Samantha','-o',str(aiff),d['text']],check=True,stdout=subprocess.DEVNULL)
    subprocess.run(['afconvert','-f','WAVE','-d','LEI16@16000','-c','1',str(aiff),str(asset)],check=True,stdout=subprocess.DEVNULL)
    with wave.open(str(asset)) as f:d['duration']=f.getnframes()/f.getframerate()
   else:d['duration']=0
   d['sha256']=hashlib.sha256(asset.read_bytes()).hexdigest()
   reply,_=worker.request(dict(media=dict(kind=d['kind'],path=str(asset.resolve()))))
  assert not reply.get('error'),reply
  d['vector']=reply['embeddings'][0];assert len(d['vector'])==768
  documents.append(d)
  print('source',len(documents),flush=True)
 for q in labels['queries']:
  q=dict(q);reply,_=worker.request(dict(texts=['task: search result | query: '+q['query']]))
  assert not reply.get('error'),reply
  q['vector']=reply['embeddings'][0];queries.append(q)
 result=dict(documents=documents,queries=queries,labels_sha256=hashlib.sha256((here/'rework-frozen-labels.json').read_bytes()).hexdigest(),model_sha256=hashlib.sha256(a.model.read_bytes()).hexdigest(),projector_sha256=hashlib.sha256(a.projector.read_bytes()).hexdigest(),helper_sha256=hashlib.sha256(a.helper.read_bytes()).hexdigest(),scope='Frozen independent fictional documents, generated speech and images, all real pinned embeddings. No query-vector cache. No extraction/permissions/UI latency claim.')
 (here/'rework-frozen-vectors.json').write_text(json.dumps(result,ensure_ascii=False)+'\n')
 print('Captured',len(documents),len(queries),flush=True)
finally:worker.close()
