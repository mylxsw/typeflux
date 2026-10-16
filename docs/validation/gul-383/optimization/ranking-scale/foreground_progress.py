#!/usr/bin/env python3
"""Numeric-only progress for the foreground experiment owner; never print file contents/paths."""
import json,re,shutil,subprocess,sys,time,sqlite3
from pathlib import Path
r=Path.cwd();h=r/'docs/validation/gul-383/optimization/ranking-scale';phase=sys.argv[1];out=dict(phase=phase,free_disk_gib=round(shutil.disk_usage(r).free/2**30,1))
if phase=='remaining-matrix':
 run=json.loads((h/'matrix-run-final-ui.json').read_text());out.update(completed_cells=len(run['cells']),elapsed_minutes=round((time.time()-run['started_unix'])/60,1))
 lines=Path('.build/gul404-final-ui-matrix.log').read_text().splitlines();line=next(x for x in reversed(lines) if x.startswith('Cell '));match=re.fullmatch(r'Cell (\d+) (.*)',line);case=json.loads(match[2]);out.update(case=int(match[1]),scale=case['size'],build=case['label'],mode=case['mode'])
 folder=h if case['label']=='after' else r/'.build/baseline-code'/h.relative_to(r)
 name=f"native-{case['label']}-{case['size']}-{case['tag']}.partial.json" if case['mode']=='native' else f"contention-{case['label']}-{case['tag']}-{case['size']}.partial.json"
 if (folder/name).exists():
  data=json.loads((folder/name).read_text());out.update(stage=data.get('stage'),rows=len(data.get('rows',[])))
else:
 pid_path=r/('.build/gul404-complete-original.pid' if phase=='complete-original' else '.build/gul404-final-resources.pid')
 if phase=='complete-original':
  p=h/'complete-original-commands.json'
  if p.exists():out['completed_commands']=len(json.loads(p.read_text())['commands'])
 else:
  p=h/'resource-after-final-current/native-resource.json'
  if p.exists():out['completed_conditions']=len(json.loads(p.read_text()))
  p=h/'resource-after-final-current/resources.json'
  if p.exists():
   data=json.loads(p.read_text());out.update(samples=len(data['samples']),elapsed_minutes=round(data['samples'][-1]['seconds']/60,1))
 if pid_path.exists():
  parent=int(pid_path.read_text());rows=[x.split(maxsplit=2) for x in subprocess.check_output(['ps','-axo','pid=,ppid=,comm='],text=True).splitlines()];rows=[x for x in rows if len(x)==3];owned={parent}
  while True:
   grown=owned|{int(x[0]) for x in rows if int(x[1]) in owned}
   if grown==owned:break
   owned=grown
  helpers=[int(x[0]) for x in rows if int(x[0]) in owned and Path(x[2]).name=='swiftpm-testing-helper']
  for pid in helpers:
   result=subprocess.run(['lsof','-p',str(pid),'-Fn'],capture_output=True,text=True)
   paths={x[1:] for x in result.stdout.splitlines() if x.startswith('n') and x.endswith(('/index.sqlite','/semantic-files.sqlite'))}
   for path in paths:
    try:
     db=sqlite3.connect('file:'+path+'?mode=ro',uri=True,timeout=.01);out.update(published_files=db.execute('SELECT COUNT(*) FROM files').fetchone()[0],published_chunks=db.execute('SELECT COUNT(*) FROM chunks').fetchone()[0]);db.close()
    except sqlite3.Error:pass
print(json.dumps(out,separators=(',',':')))
