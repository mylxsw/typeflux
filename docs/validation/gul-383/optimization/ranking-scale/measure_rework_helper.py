#!/usr/bin/env python3
"""Same-host pinned GPU query versus one-thread CPU background helper, outside application tests."""
import argparse,hashlib,importlib.util,json,os,resource,subprocess,time
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
for key in ['helper','model','projector','assets']:p.add_argument('--'+key,type=Path,required=True)
a=p.parse_args();here=Path(__file__).parent
spec=importlib.util.spec_from_file_location('ipc',here/'measure_batch.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
text=('title: reference.txt | text: Employees collect receipts before submitting an expense report. '*12)[:1200]
requests=[dict(texts=[text]) for _ in range(30)]+[dict(media=dict(kind='image',path=str((a.assets/'fresh-image-00.png').resolve()))) for _ in range(3)]+[dict(media=dict(kind='audio',path=str((a.assets/'fresh-audio-00.wav').resolve()))) for _ in range(3)]
reports={};vectors={};start=time.monotonic()
for label,extra in [('query-gpu',[]),('background-cpu',['--background'])]:
 if label=='background-cpu':os.environ.update(VECLIB_MAXIMUM_THREADS='1',OMP_NUM_THREADS='1')
 before=resource.getrusage(resource.RUSAGE_CHILDREN)
 worker=m.Worker([a.helper.resolve(),a.model.resolve(),a.projector.resolve(),*extra]);rows=[];values=[]
 try:
  for n,request in enumerate(requests):
   reply,ms=worker.request(request)
   if reply.get('error'):raise RuntimeError(reply)
   rows.append(dict(sample=n,kind='text' if n<30 else ('image' if n<33 else 'audio'),ipc_ms=ms,helper_timing=reply.get('semanticTiming')))
   values.append(reply['embeddings'][0])
  rss=int(subprocess.check_output(['ps','-p',str(worker.process.pid),'-o','rss='],text=True).strip())*1024
 finally:worker.close()
 after=resource.getrusage(resource.RUSAGE_CHILDREN)
 vectors[label]=values
 reports[label]=dict(rows=rows,rss_bytes=rss,children_cpu_seconds=(after.ru_utime+after.ru_stime)-(before.ru_utime+before.ru_stime))
errors=[max(abs(x-y) for x,y in zip(v,w)) for v,w in zip(vectors['query-gpu'],vectors['background-cpu'])]
report=dict(reports=reports,max_component_errors=errors,helper_sha256=hashlib.sha256(a.helper.read_bytes()).hexdigest(),wall_seconds=time.monotonic()-start,scope='Actual pinned text/image/audio inputs; helper CPU mode has GPU offload disabled, one inference thread and one Accelerate thread. No parent timeslicing here: these are compute-unit baselines used with the separate live-budget 15-minute native response experiment. Children CPU includes the final ps sampler. Model loading sample zero is retained, never included silently in a warm percentile.')
(here/'rework-helper-reference.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({k:{'rss_bytes':v['rss_bytes'],'children_cpu_seconds':v['children_cpu_seconds']} for k,v in reports.items()}));print('wall_seconds',report['wall_seconds'])
