from pathlib import Path
import subprocess,re,json,gzip
root=Path.cwd()
base='ba115260da3118d10e6ecb9b4ac57c4df930c565'

def read_lcov(path):
 data={};name=None
 for row in gzip.decompress(Path(path).read_bytes()).decode().splitlines():
  if row.startswith('SF:'):
   name=row[3:].split('/typeflux/')[-1];data.setdefault(name,{})
  elif row.startswith('DA:') and name:
   line,count=map(int,row[3:].split(',')[:2]);data[name][line]=max(data[name].get(line,0),count)
 return data
first=read_lcov('docs/validation/gul-453/swift-first-coverage-changed.lcov.gz')
final=read_lcov('docs/validation/gul-453/swift-final.lcov.gz')
# The engine/wrappers/compaction sources are unchanged between both passes.
# The renamed/formatted new builder uses only the final build's own line map.
for name,lines in first.items():
 if name.endswith('/AskPromptBuilder.swift'):continue
 for line,count in lines.items():final.setdefault(name,{})[line]=max(final.get(name,{}).get(line,0),count)
new='Sources/Typeflux/Ask/Local/AskPromptBuilder.swift'
files=subprocess.check_output(['git','-C',str(root),'diff',base,'--name-only'],text=True).splitlines()
files=list(dict.fromkeys(files+[new]));report=[]
for file in files:
 if not file.startswith('Sources/') or not file.endswith('.swift'):continue
 if file==new:added=set(range(1,len((root/file).read_text().splitlines())+1))
 else:
  diff=subprocess.check_output(['git','-C',str(root),'diff',base,'--unified=0','--',file],text=True);added=set()
  for start,count in re.findall(r'^@@ .*?\+(\d+)(?:,(\d+))? @@',diff,re.M):added.update(range(int(start),int(start)+int(count or 1)))
 executable={n:h for n,h in final.get(file,{}).items() if n in added}
 row={'file':file,'covered':sum(h>0 for h in executable.values()),'executable':len(executable),'uncovered':[n for n,h in executable.items() if h==0]};report.append(row)
covered=sum(r['covered'] for r in report);total=sum(r['executable'] for r in report)
print(json.dumps({'files':report,'covered':covered,'executable':total,'percent':100*covered/total},indent=2))
