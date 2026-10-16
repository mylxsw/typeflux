#!/usr/bin/env python3
"""Capture labelled synthetic speech and colour fixtures with the pinned multimodal model."""
import argparse,hashlib,importlib.util,json,subprocess,wave
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--helper',type=Path,required=True);p.add_argument('--model',type=Path,required=True);p.add_argument('--projector',type=Path,required=True);p.add_argument('--assets',type=Path,required=True)
a=p.parse_args();here=Path(__file__).parent;root=here.resolve().parents[4]
spec=importlib.util.spec_from_file_location('bench',here/'measure_batch.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
spec=importlib.util.spec_from_file_location('holdout',here/'create_holdout.py');h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
raw=json.loads((here/'raw-quality-vectors.json').read_text())
a.assets.mkdir(parents=True,exist_ok=True)
w=m.Worker([a.helper.resolve(),a.model.resolve(),a.projector.resolve()])
documents=[];queries=[];rows=[]
try:
 for i,(en,zh,fact,zhfact) in enumerate(h.topics.TOPICS):
  audio=a.assets/f'clip-{i:02}.wav';aiff=audio.with_suffix('.aiff')
  subprocess.run(['say','-v','Samantha','-o',str(aiff),fact],check=True,stdout=subprocess.DEVNULL)
  subprocess.run(['afconvert','-f','WAVE','-d','LEI16@16000','-c','1',str(aiff),str(audio)],check=True,stdout=subprocess.DEVNULL)
  with wave.open(str(audio)) as f:duration=f.getnframes()/f.getframerate()
  reply,_=w.request(dict(media=dict(kind='audio',path=str(audio.resolve()))));assert not reply.get('error'),reply
  documents.append(dict(id=f'clip-{i:02}',kind='audio',text=fact,vector=reply['embeddings'][0],duration=duration,sha256=hashlib.sha256(audio.read_bytes()).hexdigest()))
  for g,q in [('topic',en),('paraphrase',h.EN[i]),('cross_language',h.ZH[i])]:
   reply,_=w.request(dict(texts=['task: search result | query: '+q]));assert not reply.get('error'),reply
   queries.append(dict(id=f'audio_{g}-{i:02}',group=f'audio_{g}',query=q,expected=[f'clip-{i:02}'],vector=reply['embeddings'][0]))
  print('captured clip',i,flush=True)
 for i,q in enumerate(h.NO_ANSWER):
  reply,_=w.request(dict(texts=['task: search result | query: '+q]));assert not reply.get('error'),reply
  queries.append(dict(id=f'media_no_answer-{i:02}',group='media_no_answer',query=q,expected=[],vector=reply['embeddings'][0]))
 # Reuse real generated pixel fixtures, not a text substitute for visual embeddings.
 for name in ['red','blue']:
  image=a.assets/f'{name}.png'
  reply,_=w.request(dict(media=dict(kind='image',path=str(image.resolve()))));assert not reply.get('error'),reply
  documents.append(dict(id=name,kind='image',text=name+' square',vector=reply['embeddings'][0],duration=0,sha256=hashlib.sha256(image.read_bytes()).hexdigest()))
  for i,q in enumerate([f'a {name} square',f'{name} image',f'a photo of a {name} square']):
   reply,_=w.request(dict(texts=['task: search result | query: '+q]));assert not reply.get('error'),reply
   queries.append(dict(id=f'image_{name}-{i}',group='image',query=q,expected=[name],vector=reply['embeddings'][0]))
 result=dict(documents=documents,queries=queries,model_sha256=hashlib.sha256(a.model.read_bytes()).hexdigest(),projector_sha256=hashlib.sha256(a.projector.read_bytes()).hexdigest(),scope='25 generated single-segment English speech WAVs, two coloured-square PNGs; labelled topic/paraphrase/Chinese queries and 25 fantasy no-answer questions. Synthetic quality sample; vectors captured from real pinned media/text inference. Actual extraction/UI/ASR latency is not measured here.')
 (here/'captured-media.json').write_text(json.dumps(result,ensure_ascii=False)+'\n')
finally:w.close()
