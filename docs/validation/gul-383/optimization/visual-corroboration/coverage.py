"""Changed executable LCOV lines, matching the issue's existing coverage convention."""
import gzip,hashlib,json,re,subprocess,time
from pathlib import Path
root=Path.cwd();out=Path(__file__).resolve().parent;scratch=root/'.build/visual-corroboration'
start=time.monotonic();binary=scratch/'TypefluxPackageTests.xctest/Contents/MacOS/TypefluxPackageTests'
profiles=sorted(scratch.glob('final-*.profraw'));assert profiles
merged=scratch/'focused.profdata'
subprocess.run(['xcrun','llvm-profdata','merge','-sparse',*map(str,profiles),'-o',str(merged)],check=True)
source='Sources/Typeflux/Ask/QuickResults/Semantic/SemanticVectorReader.swift'
raw=subprocess.check_output(['xcrun','llvm-cov','export',str(binary),'-instr-profile='+str(merged),'-format=lcov',str(root/source)],text=True)
counts={int(l[3:].split(',')[0]):int(l[3:].split(',')[1]) for l in raw.splitlines() if l.startswith('DA:')}
diff=subprocess.check_output(['git','diff','--unified=0','6123227a25a9d0843bfdde02ba175fe835017630','--',source],text=True)
changed=set()
for line in diff.splitlines():
 m=re.match(r'@@ .*\+(\d+)(?:,(\d+))? @@',line)
 if m:changed.update(range(int(m[1]),int(m[1])+int(m[2] or 1)))
lines={i:c for i,c in counts.items() if i in changed};assert lines
covered=sum(c>0 for c in lines.values())
report=dict(baseline='6123227a25a9d0843bfdde02ba175fe835017630',application=dict(covered=covered,executable=len(lines),percent=100*covered/len(lines),lines=lines,uncovered=[i for i,c in lines.items() if not c]),native_helper=dict(covered=0,executable=0,percent=None),file_helper=dict(covered=0,executable=0,percent=None),media_runtime=dict(covered=0,executable=0,percent=None),convention='Changed lines intersected with LLVM LCOV DA records; line coverage, not branch or whole-app coverage',profiles=[dict(file=p.name,sha256=hashlib.sha256(p.read_bytes()).hexdigest(),bytes=p.stat().st_size) for p in profiles],binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),wall_seconds=time.monotonic()-start)
(out/'changed-coverage.json').write_text(json.dumps(report,indent=2)+'\n')
for p in [merged,*profiles]:
 with gzip.open(out/(p.name+'.gz'),'wb') as f:f.write(p.read_bytes())
with gzip.open(out/'focused.lcov.gz','wt') as f:f.write(raw.replace(str(root),'<repo>'))
print(json.dumps({k:v for k,v in report.items() if k!='profiles'},indent=2));assert covered/len(lines)>=.70
