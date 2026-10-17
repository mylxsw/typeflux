"""Compile only the diagnostic entry point; reuse the accepted product objects and helpers."""
import argparse, hashlib, json, shlex, subprocess, time
from pathlib import Path
parser=argparse.ArgumentParser();parser.add_argument('--cache-checkout', type=Path, required=True);parser.add_argument('--offline', action='store_true');parser.add_argument('--reuse', action='store_true');parser.add_argument('--video', action='store_true');parser.add_argument('--reader-checkout', type=Path, required=True);args=parser.parse_args()
root=Path.cwd();cache=args.cache_checkout.resolve();out=Path(__file__).resolve().parent
scratch=root/'.build/audio-live';scratch.mkdir(parents=True,exist_ok=True)
build=cache/'.build/video-frames/arm64-apple-macosx/debug'
sha=lambda p:hashlib.file_digest(p.open('rb'),'sha256').hexdigest()
paths=['Sources/Typeflux/Ask/QuickResults/Semantic/'+s+'.swift' for s in ['SemanticEmbeddingWorker','SemanticVectorReader','SemanticSearchRanking','SemanticScoreCalibration','SemanticFileStore','SemanticFileStore+MediaJobs','SemanticFileStore+ImageText']]+['Sources/TypefluxSemanticHelper/main.swift']
reader=args.reader_checkout.resolve()
for p in paths:
    origin = reader if p.endswith('/SemanticVectorReader.swift') else cache
    assert sha(root/p)==sha(origin/p),p
reader_object=reader/'.build/visual-corroboration/SemanticVectorReader.swift.o'
assert sha(root/'Sources/Typeflux/Ask/QuickResults/Semantic/SemanticVectorReader.swift') == json.loads((reader/'docs/validation/gul-383/optimization/visual-corroboration/binary.json').read_text())['reader_sha256']
paths += [str(p.relative_to(root)) for p in (root/'Sources/Typeflux/Ask/QuickResults/Semantic').glob('*.swift') if str(p.relative_to(root)) not in paths]
for p in paths:
    if p.endswith('/SemanticVectorReader.swift'): continue
    assert sha(root/p)==sha(cache/p),p
(out/'reader-object.json').write_text(json.dumps(dict(sha256=sha(reader_object),source_sha256=sha(root/'Sources/Typeflux/Ask/QuickResults/Semantic/SemanticVectorReader.swift')),indent=2)+'\n')
(out/'reused-source-hashes.json').write_text(json.dumps({p:sha(root/p) for p in paths},indent=2)+'\n')
info=json.loads((build/'description.json').read_text())['swiftCommands']['C.TypefluxFocusedTests-arm64-apple-macosx-debug.module']
clean=[];i=0;other=info['otherArguments']
while i<len(other):
    flag=other[i]
    if flag in ['-index-store-path','-module-cache-path']:i+=2
    elif flag in ['-incremental','-enable-batch-mode','-serialize-diagnostics','-parseable-output'] or flag.startswith('-j'):i+=1
    else:clean.append(flag);i+=1
stem='video' if args.video else ('service' if args.reuse else ('replay' if args.offline else 'capture'))
obj=scratch/(stem+'.o');binary=scratch/('VideoProbe' if args.video else ('ServiceProbe' if args.reuse else ('OfflineReplay' if args.offline else 'AudioProbe')));source=out/('video_probe.swift' if args.video else ('service_probe.swift' if args.reuse else ('offline_replay.swift' if args.offline else 'executed_audio_probe.swift')))
compile_command=[info['executable'],'-c',str(source),'-I',str(build/'Modules'),'-module-name','GUL405VisualDiagnosis','-o',str(obj),*clean]
lines=(cache/'.build/video-frames/debug.yaml').read_text().splitlines()
link=next(json.loads(lines[i+1].split('args: ',1)[1]) for i,line in enumerate(lines) if 'description: "Linking' in line and 'TypefluxPackageTests' in line)
original=next(p[1:] for p in link if p.startswith('@') and p.endswith('Objects.LinkFileList'))
selected=[p for p in Path(original).read_text().splitlines() if '/TypefluxPackageTests.build/' not in p and '/TypefluxPackageDiscoveredTests.build/' not in p and not p.endswith('/SemanticVectorReader.swift.o')]
selected.append(str(reader_object))
filelist=scratch/'Probe.LinkFileList';filelist.write_text('\n'.join([*selected,str(obj)])+'\n')
linked=[];i=0
while i<len(link):
    if link[i:i+2]==['-Xlinker','-bundle']:i+=2;continue
    if link[i]=='-o':linked.extend(['-o',str(binary)]);i+=2;continue
    linked.append('@'+str(filelist) if link[i].startswith('@') and link[i].endswith('Objects.LinkFileList') else link[i]);i+=1
records=json.loads((out/(stem+'-build.json')).read_text()) if (out/(stem+'-build.json')).exists() else []
for label,command in [('compile',compile_command),('link',linked)]:
    started=time.monotonic();p=subprocess.run(command,capture_output=True,text=True)
    records.append({'phase':label,'command':command,'wall_seconds':time.monotonic()-started,'exit_code':p.returncode})
    (out/(stem+'-'+label+'-'+str(len(records))+'.log')).write_text(p.stdout+p.stderr)
    (out/(stem+'-build.json')).write_text(json.dumps(records,indent=2)+'\n')
    if p.returncode:print((p.stdout+p.stderr)[-5000:]);raise SystemExit(p.returncode)
(out/('video-binary.json' if args.video else ('service-binary.json' if args.reuse else ('offline-binary.json' if args.offline else 'probe-binary.json')))).write_text(json.dumps({'sha256':sha(binary),'source_sha256':sha(source),'reused_object_count':len(selected),'configuration':'Current product Debug objects; diagnostic capture entry point, no injected library'},indent=2)+'\n')
print('Compiled diagnostic entry point and linked unchanged product objects:',sum(r['wall_seconds'] for r in records))
