#!/usr/bin/env python3
"""Optional bounded numeric read of the owned resource experiment's private database."""
import argparse, json, sqlite3, subprocess, time
from pathlib import Path
from urllib.parse import quote

p=argparse.ArgumentParser();p.add_argument('--folder',type=Path,required=True);a=p.parse_args()
start=time.monotonic();report=json.loads((a.folder/'resources.json').read_text())
pid=next(x['pid'] for x in report['samples'][-1]['owned'] if x['name']=='swiftpm-testing-helper')
listing=subprocess.check_output(['lsof','-a','-p',str(pid),'-Fn'],text=True,stderr=subprocess.DEVNULL,timeout=8)
names=[x[1:] for x in listing.splitlines() if x.startswith('n') and x.endswith('/index-on-state/semantic-files.sqlite')]
if not names: print('Owned index-on database is not open');raise SystemExit(0)
connection=sqlite3.connect('file:'+quote(names[0])+'?mode=ro',uri=True,timeout=.05)
try:
    connection.execute('BEGIN')
    chunks=connection.execute('SELECT count(*),coalesce(sum(length(vector)=3072),0) FROM chunks').fetchone()
    jobs=connection.execute("SELECT CASE WHEN path LIKE '%.txt' THEN 'document' WHEN path LIKE '%.png' THEN 'image' WHEN path LIKE '%.wav' THEN 'audio' WHEN path LIKE '%.mov' THEN 'video' ELSE 'other' END,state,count(*) FROM jobs GROUP BY 1,2").fetchall()
    rows=connection.execute('SELECT id,stage,encodingRequests,vectorsInferred,vectorsPublished,ftsChunks,budgetYields,budgetWaitMilliseconds,budgetInterruptions,tailBatches FROM index_runs ORDER BY started').fetchall()
    observation=dict(unix=time.time(),chunks=chunks[0],encoded_vectors=chunks[1],
        jobs=[dict(kind=k,state=s,count=n) for k,s,n in jobs],
        largest_document_bytes=connection.execute("SELECT coalesce(max(bytes),0) FROM files WHERE path LIKE '%.txt'").fetchone()[0],
        queue=connection.execute('SELECT priority,count(*) FROM work_queue GROUP BY priority').fetchall(),
        staged_media_segments=connection.execute('SELECT count(*) FROM media_segments').fetchone()[0],runs=rows)
finally: connection.close()
observation['observer_wall_seconds']=time.monotonic()-start
target=a.folder/'database-observations.json';history=json.loads(target.read_text()) if target.exists() else []
history.append(observation);target.write_text(json.dumps(history,indent=2)+'\n')
print(json.dumps({k:v for k,v in observation.items() if k not in ['runs','queue']}))
