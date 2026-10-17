"""Compile only the diagnostic entry point; reuse the accepted product objects and helpers."""
import argparse, hashlib, json, shlex, subprocess, time
from pathlib import Path
parser=argparse.ArgumentParser();parser.add_argument('--cache-checkout', type=Path, required=True);parser.add_argument('--offline', action='store_true');args=parser.parse_args()
root=Path.cwd();cache=args.cache_checkout.resolve();out=Path(__file__).resolve().parent
scratch=root/'.build/visual-diagnosis';scratch.mkdir(parents=True,exist_ok=True)
build=cache/'.build/video-frames/arm64-apple-macosx/debug'
sha=lambda p:hashlib.file_digest(p.open('rb'),'sha256').hexdigest()
paths=['Sources/Typeflux/Ask/QuickResults/Semantic/'+s+'.swift' for s in ['SemanticEmbeddingWorker','SemanticVectorReader','SemanticSearchRanking','SemanticScoreCalibration','SemanticFileStore','SemanticFileStore+MediaJobs','SemanticFileStore+ImageText']]+['Sources/TypefluxSemanticHelper/main.swift']
for p in paths: assert sha(root/p)==sha(cache/p),p
(out/'reused-source-hashes.json').write_text(json.dumps({p:sha(root/p) for p in paths},indent=2)+'\n')
info=json.loads((build/'description.json').read_text())['swiftCommands']['C.TypefluxFocusedTests-arm64-apple-macosx-debug.module']
clean=[];i=0;other=info['otherArguments']
while i<len(other):
    flag=other[i]
    if flag in ['-index-store-path','-module-cache-path']:i+=2
    elif flag in ['-incremental','-enable-batch-mode','-serialize-diagnostics','-parseable-output'] or flag.startswith('-j'):i+=1
    else:clean.append(flag);i+=1
stem='replay' if args.offline else 'capture'
obj=scratch/(stem+'.o');binary=scratch/('OfflineReplay' if args.offline else 'MediaProbe');source=out/('offline_replay.swift' if args.offline else 'media_probe.swift')
compile_command=[info['executable'],'-c',str(source),'-I',str(build/'Modules'),'-module-name','GUL405VisualDiagnosis','-o',str(obj),*clean]
lines=(cache/'.build/video-frames/debug.yaml').read_text().splitlines()
link=next(json.loads(lines[i+1].split('args: ',1)[1]) for i,line in enumerate(lines) if 'description: "Linking' in line and 'TypefluxPackageTests' in line)
original=next(p[1:] for p in link if p.startswith('@') and p.endswith('Objects.LinkFileList'))
selected=[p for p in Path(original).read_text().splitlines() if '/TypefluxPackageTests.build/' not in p and '/TypefluxPackageDiscoveredTests.build/' not in p]
filelist=scratch/'Probe.LinkFileList';filelist.write_text('\n'.join([*selected,str(obj)])+'\n')
linked=[];i=0
while i<len(link):
    if link[i:i+2]==['-Xlinker','-bundle']:i+=2;continue
    if link[i]=='-o':linked.extend(['-o',str(binary)]);i+=2;continue
    linked.append('@'+str(filelist) if link[i].startswith('@') and link[i].endswith('Objects.LinkFileList') else link[i]);i+=1
records=[]
for label,command in [('compile',compile_command),('link',linked)]:
    started=time.monotonic();p=subprocess.run(command,capture_output=True,text=True)
    records.append({'phase':label,'command':command,'wall_seconds':time.monotonic()-started,'exit_code':p.returncode})
    (out/(stem+'-'+label+'.log')).write_text(p.stdout+p.stderr)
    (out/(stem+'-build.json')).write_text(json.dumps(records,indent=2)+'\n')
    if p.returncode:print((p.stdout+p.stderr)[-5000:]);raise SystemExit(p.returncode)
(out/('offline-binary.json' if args.offline else 'probe-binary.json')).write_text(json.dumps({'sha256':sha(binary),'source_sha256':sha(source),'reused_object_count':len(selected),'configuration':'Current product Debug objects; diagnostic capture entry point, no injected library'},indent=2)+'\n')
print('Compiled diagnostic entry point and linked unchanged product objects:',sum(r['wall_seconds'] for r in records))
