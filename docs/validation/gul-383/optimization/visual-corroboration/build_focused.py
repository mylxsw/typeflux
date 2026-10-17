"""Compile the single changed production file and new tests against the accepted Debug closure."""
import argparse,hashlib,json,shutil,subprocess,time
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--cache-checkout',type=Path,required=True);a=p.parse_args()
root=Path.cwd();cache=a.cache_checkout.resolve();out=Path(__file__).resolve().parent
scratch=root/'.build/visual-corroboration';scratch.mkdir(parents=True,exist_ok=True)
build=cache/'.build/video-frames/arm64-apple-macosx/debug'
commands=json.loads((build/'description.json').read_text())['swiftCommands']
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
primary=root/'Sources/Typeflux/Ask/QuickResults/Semantic/SemanticVectorReader.swift'
info=commands['C.Typeflux-arm64-apple-macosx-debug.module']
def flags(info,frontend=False):
 clean=[];i=0;args=info['otherArguments']
 while i<len(args):
  f=args[i]
  if f in ['-index-store-path','-module-cache-path','-emit-objc-header-path']:i+=2
  elif f in ['-incremental','-enable-batch-mode','-serialize-diagnostics','-parseable-output','-emit-objc-header'] or f.startswith('-j'):i+=1
  elif f=='-Xfrontend' and frontend:clean.append(args[i+1]);i+=2
  else:clean.append(f);i+=1
 return clean
records=json.loads((out/'build.json').read_text()) if (out/'build.json').exists() else []
def run(label,args):
 started=time.monotonic();r=subprocess.run(args,capture_output=True,text=True)
 (out/(label+'-'+str(len(records))+'.log')).write_text(r.stdout+r.stderr)
 records.append(dict(phase=label,command=args,wall_seconds=time.monotonic()-started,exit_code=r.returncode))
 (out/'build.json').write_text(json.dumps(records,indent=2)+'\n')
 if r.returncode:print((r.stdout+r.stderr)[-6500:]);raise SystemExit(r.returncode)
# Reuse the accepted declaration closure. Only the changed primary emits code; no model/helper build.
others=[s for s in info['sources'] if not s.endswith('/SemanticVectorReader.swift')]
reader_command=[info['executable'],'-frontend','-c','-primary-file',str(primary),*others,'-module-name','Typeflux','-I',str(build/'Modules'),*flags(info,True),'-plugin-path',str(Path(info['executable']).parents[1]/'lib/swift/host/plugins'),'-o',str(scratch/'SemanticVectorReader.swift.o')]
if not (scratch/'reader-source.sha256').exists() or (scratch/'reader-source.sha256').read_text()!=sha(primary):
 run('reader-compile',reader_command)
 (scratch/'reader-source.sha256').write_text(sha(primary))
test=root/'Tests/TypefluxTests/SemanticImageCorroborationTests.swift'
source=scratch/test.name
source.write_text('@testable import TypefluxFocusedTests\n'+test.read_text().replace('#filePath',json.dumps(str(test))))
ti=commands['C.TypefluxFocusedTests-arm64-apple-macosx-debug.module']
run('tests-compile',[ti['executable'],'-c',str(source),'-I',str(build/'Modules'),'-module-name','GUL405CorroborationTests','-o',str(scratch/'Tests.o'),*flags(ti)])
lines=(cache/'.build/video-frames/debug.yaml').read_text().splitlines()
link=next(json.loads(lines[i+1].split('args: ',1)[1]) for i,l in enumerate(lines) if 'description: "Linking' in l and 'TypefluxPackageTests' in l)
original=Path(next(p[1:] for p in link if p.startswith('@') and p.endswith('Objects.LinkFileList')))
selected=[s for s in original.read_text().splitlines() if not s.endswith('/SemanticVectorReader.swift.o')]
filelist=scratch/'Focused.LinkFileList';filelist.write_text('\n'.join([*selected,str(scratch/'SemanticVectorReader.swift.o'),str(scratch/'Tests.o')])+'\n')
bundle=scratch/'TypefluxPackageTests.xctest';binary=bundle/'Contents/MacOS/TypefluxPackageTests';binary.parent.mkdir(parents=True,exist_ok=True)
old=build/'TypefluxPackageTests.xctest/Contents/Info.plist'
if old.exists():shutil.copy2(old,bundle/'Contents/Info.plist')
linked=[];i=0
while i<len(link):
 if link[i]=='-o':linked+=['-o',str(binary)];i+=2
 else:linked.append('@'+str(filelist) if link[i].startswith('@') and link[i].endswith('Objects.LinkFileList') else link[i]);i+=1
run('link',linked)
(out/'binary.json').write_text(json.dumps(dict(sha256=sha(binary),reader_sha256=sha(primary),tests_sha256=sha(test),reused_objects=len(selected),configuration='Focused Debug production primary plus new tests; accepted remaining objects; no native helper rebuilt'),indent=2)+'\n')
print('Build complete',sum(r['wall_seconds'] for r in records))
