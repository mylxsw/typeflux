import gzip,hashlib,json,re,subprocess
from pathlib import Path
r=Path.cwd();h=r/'docs/validation/gul-383/optimization/ranking-scale';out=h/'integration-main-b463'
build=r/'.build/gul404-rework-coverage/arm64-apple-macosx/debug'
binary=build/'TypefluxPackageTests.xctest/Contents/MacOS/TypefluxPackageTests';profile=build/'codecov/default.profdata'
raw=subprocess.check_output(['xcrun','llvm-cov','export','-format=lcov',str(binary),'--instr-profile='+str(profile)],text=True)
def parse(text):
 result={};name=None
 for line in text.splitlines():
  if line.startswith('SF:'):
   name=line[3:];p=Path(name)
   if p.is_absolute() and p.is_relative_to(r):name=str(p.relative_to(r))
  elif line.startswith('DA:') and name:
   n,c,*_=line[3:].split(',');result.setdefault(name,{})[int(n)]=int(c)
 return result
fresh=parse(raw)
def write_lcov(path,records):
 with gzip.open(path,'wt') as f:
  for name,values in sorted(records.items()):
   if not name.startswith('Sources/'):continue
   f.write('SF:'+name+'\n');f.writelines(f'DA:{n},{c}\n' for n,c in sorted(values.items()));f.write('end_of_record\n')
write_lcov(out/'fresh-app.lcov.gz',fresh)
merged={k:dict(v) for k,v in fresh.items()};retained={}
old=parse(gzip.open(h/'final-app-coverage.lcov.gz','rt').read())
for name,values in old.items():
 p=r/name
 if not p.is_file():continue
 before=subprocess.run(['git','show','6a9c18d79561b49d8c5339754193c6a06ee79374:'+name],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
 if before.returncode or hashlib.sha256(before.stdout).hexdigest()!=hashlib.sha256(p.read_bytes()).hexdigest():continue
 retained[name]=hashlib.sha256(p.read_bytes()).hexdigest()
 for n,c in values.items():merged.setdefault(name,{})[n]=max(merged.get(name,{}).get(n,0),c)
def changes(folder):
 text=subprocess.check_output(['git','diff','--unified=0','b463b30929462b7e60b7ff8e35384dd36f5a60de','--',folder],text=True);result={};name=None
 for line in text.splitlines():
  if line.startswith('+++ b/'):name=line[6:]
  elif line.startswith('@@'):
   m=re.search(r'\+(\d+)(?:,(\d+))?',line);n=int(m[1]);count=int(m[2] or 1);result.setdefault(name,set()).update(range(n,n+count))
 return result
def report(records,changed):
 files={};missing=[]
 for name,lines in changed.items():
  if not lines:continue
  values=records.get(name,{})
  if not values:missing.append(name)
  executable=sorted(lines & values.keys());uncovered=[n for n in executable if not values[n]]
  if executable:files[name]=dict(executable=len(executable),covered=len(executable)-len(uncovered),uncovered=uncovered)
 total=sum(x['executable'] for x in files.values());covered=sum(x['covered'] for x in files.values())
 return dict(base='b463b30929462b7e60b7ff8e35384dd36f5a60de',covered=covered,executable=total,percent=100*covered/total if total else None,files=files,missing_line_tables=missing)
changed=changes('Sources/Typeflux');a=report(fresh,changed);combined=report(merged,changed)
helpertext=gzip.open(h/'final-helper-coverage.lcov.gz','rt').read();helperold=json.loads((h/'final-helper-coverage.json').read_text());helperSource=r/'Sources/TypefluxSemanticHelper/main.swift';assert hashlib.sha256(helperSource.read_bytes()).hexdigest()==helperold['source_sha256']
helper=report(parse(helpertext),changes('Sources/TypefluxSemanticHelper'));helper.update(reused=True,source_sha256=helperold['source_sha256'],binary_sha256=helperold['binary_sha256'],provenance='Original helper LCOV and raw profiles retained in evidence-history.tar.gz; unchanged helper source. No helper inference rerun this integration.')
write_lcov(out/'combined-app.lcov.gz',merged)
result=dict(fresh_application=a,application_with_identical_source_reuse=combined,helper=helper,reused_source_sha256=retained,binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),profile_sha256=hashlib.sha256(profile.read_bytes()).hexdigest(),rule='Fresh native profile for the integrated executable. Prior observations reused only for complete source files byte-identical to 6a9c18d7; no raw profiles merged across executables. Source changed during integration never inherits old observations.')
(out/'coverage-summary.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({k:{n:v[n] for n in ['covered','executable','percent','missing_line_tables']} for k,v in [('fresh_app',a),('combined_app',combined),('helper',helper)]}))
