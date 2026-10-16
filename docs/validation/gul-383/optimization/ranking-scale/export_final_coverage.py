#!/usr/bin/env python3
"""Export each captured executable separately, then union identical-source line observations."""
import gzip, hashlib, json, re, subprocess
from pathlib import Path

r = Path.cwd(); h = Path(__file__).parent
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def records(text):
    out = {}; name = None
    for line in text.splitlines():
        if line.startswith('SF:'): name = line[3:]
        elif name and line.startswith('DA:'):
            n, count, *_ = line[3:].split(','); out.setdefault(name, {})[int(n)] = int(count)
    return out
def relative(name):
    p = Path(name)
    return str(p.relative_to(r)) if p.is_absolute() and p.is_relative_to(r) else name

merged, provenance = {}, {}
def include(lines, hashes):
    retained = []
    for absolute, values in lines.items():
        name = relative(absolute); path = r/name
        if name not in hashes or not path.is_file() or sha(path) != hashes[name]: continue
        retained.append(name)
        for line, count in values.items(): merged.setdefault(name, {})[line] = max(merged.get(name, {}).get(line, 0), count)
    return retained

old = json.loads((h/'rework-coverage-provenance.json').read_text())
hashes = {name:value['source_sha256'] for batch in old.values()
          for name,value in batch['retained_final_object_sources'].items()}
v1_file = h/'rework-app-coverage.lcov'
v1_text = v1_file.read_text() if v1_file.exists() else gzip.open(str(v1_file)+'.gz','rt').read()
provenance['v1'] = dict(retained=include(records(v1_text), hashes),
                        evidence='rework-coverage-provenance.json',
                        rule='Only byte-identical final source files retain historical line observations. '
                             'Changed source versions are excluded; raw profiles from different executables are never merged.')
for label in ['final2-initial', 'final2-retry', 'main-final', 'lint-final', 'metadata-initial', 'metadata-final', 'metadata-priority', 'ranking-v9', 'home-ui']:
    p = r/f'.build/rework-coverage-{label}-audit'; binary = p/'TypefluxPackageTests'
    raw = sorted((p/'codecov').glob('*.profraw')); profile = p/'source.profdata'
    with (p/'export-errors.log').open('w') as log:
        subprocess.run(['xcrun','llvm-profdata','merge','-sparse',*map(str,raw),'-o',str(profile)],check=True,stderr=log)
        text = subprocess.check_output(['xcrun','llvm-cov','export','-format=lcov',str(binary),
                                        '--instr-profile='+str(profile)],text=True,stderr=log)
    hashes = json.loads((p/'sources.json').read_text())
    if label == 'final2-initial': hashes.pop('Sources/Typeflux/Ask/QuickResults/Semantic/SemanticWorkBudget.swift',None)
    provenance[label] = dict(binary_sha256=sha(binary), profiles=[x.name for x in raw],
                              retained=include(records(text),hashes), source_sha256=hashes,
                              export_diagnostics=(p/'export-errors.log').read_text(),
                              rule='Separate executable/profile export; union only byte-identical final source files.')

def changed(base, folder):
    text = subprocess.check_output(['git','diff','--unified=0',base,'--',folder],text=True)
    result = {}; name = None
    for line in text.splitlines():
        if line.startswith('+++ b/'): name=line[6:]
        elif line.startswith('@@'):
            m = re.search(r'\+(\d+)(?:,(\d+))?',line); start=int(m[1]); count=int(m[2] or 1)
            result.setdefault(name,set()).update(range(start,start+count))
    return result
base='ceeaaef5'
def report(lines, changes):
    files={}
    for name, added in changes.items():
        coverage=lines.get(name,{})
        executable=sorted(added & coverage.keys()); missing=[n for n in executable if not coverage[n]]
        if executable: files[name]=dict(executable=len(executable),covered=len(executable)-len(missing),uncovered=missing)
    total=sum(x['executable'] for x in files.values()); covered=sum(x['covered'] for x in files.values())
    return dict(base=base,covered=covered,executable=total,percent=100*covered/total if total else None,files=files)

changes=changed(base,'Sources/Typeflux'); app=report(merged,changes)
with gzip.open(h/'final-app-coverage.lcov.gz','wt') as f:
    for name in sorted(changes):
        if name not in merged: continue
        f.write('SF:'+name+'\n');f.writelines(f'DA:{n},{c}\n' for n,c in sorted(merged[name].items()));f.write('end_of_record\n')
(h/'final-app-coverage.json').write_text(json.dumps(app,indent=2)+'\n')
(h/'final-coverage-provenance.json').write_text(json.dumps(provenance,indent=2)+'\n')
binary=r/'.build/semantic/TypefluxSemanticHelper-final2-coverage'
raw=sorted((r/'.build/final2-helper-coverage-profiles').glob('*.profraw'));profile=r/'.build/final2-helper.profdata'
subprocess.run(['xcrun','llvm-profdata','merge','-sparse',*map(str,raw),'-o',str(profile)],check=True)
text=subprocess.check_output(['xcrun','llvm-cov','export','-format=lcov',str(binary),'--instr-profile='+str(profile)],text=True)
helper=report({relative(k):v for k,v in records(text).items()},changed(base,'Sources/TypefluxSemanticHelper'))
helper.update(binary_sha256=sha(binary),source_sha256=sha(r/'Sources/TypefluxSemanticHelper/main.swift'),profiles=[x.name for x in raw])
with gzip.open(h/'final-helper-coverage.lcov.gz','wt') as f:
    for name,values in records(text).items():
        f.write('SF:'+relative(name)+'\n');f.writelines(f'DA:{n},{c}\n' for n,c in sorted(values.items()));f.write('end_of_record\n')
(h/'final-helper-coverage.json').write_text(json.dumps(helper,indent=2)+'\n')
print(json.dumps({name:{k:value[k] for k in ['covered','executable','percent']} for name,value in [('app',app),('helper',helper)]}))
