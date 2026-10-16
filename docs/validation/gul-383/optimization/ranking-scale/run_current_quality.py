#!/usr/bin/env python3
"""Foreground final-source quality comparisons; preserve outputs and every command timing."""
import hashlib,json,os,shutil,subprocess,time
from pathlib import Path
r=Path.cwd();h=r/'docs/validation/gul-383/optimization/ranking-scale';base=r/'.build/baseline-code';bh=base/'docs/validation/gul-383/optimization/ranking-scale';fixtures=['final-holdout','unseen-query','rework-frozen','rework-final2','rework-final3'];target=h/'final-current-quality-commands.json'
assert not target.exists()
for fixture in fixtures:shutil.copy2(h/(fixture+'-vectors.json'),bh/(fixture+'-vectors.json'))
start=time.monotonic();reports=[]
for mode in ['ranking','original']:
 for label,checkout in [('before',base),('after',r)]:
  env=dict(os.environ,TYPEFLUX_RANKING_FIXTURES=','.join(fixtures),TYPEFLUX_ORIGINAL_CPU='1' if label=='after' else '0')
  command=['python3',str(h/'rework_release_runner.py'),'--checkout',str(checkout),'--mode',mode,'--label',label,'--tag','final-current'];wall=time.monotonic();result=subprocess.run(command,env=env)
  report=dict(mode=mode,label=label,command=command,exit_code=result.returncode,wall_seconds=time.monotonic()-wall);reports.append(report);target.write_text(json.dumps(dict(commands=reports,wall_seconds=time.monotonic()-start),indent=2)+'\n')
  if result.returncode:raise SystemExit(result.returncode)
  patterns=[f'ranking-{label}-final-current-{f}.json' for f in fixtures] if mode=='ranking' else [f'rework-original-{label}-final-current.json']
  if label=='before':
   for name in patterns+[f'rework-run-{mode}-{label}-100000-final-current.json',f'rework-run-{mode}-{label}-100000-final-current.log']:shutil.copy2(bh/name,h/name)
print(json.dumps(dict(wall_seconds=time.monotonic()-start,commands=len(reports))))
