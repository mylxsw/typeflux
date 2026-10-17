"""Summarize observed results and preserve execution identities without local model paths."""
import csv
import gzip
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess

root = Path.cwd()
out = Path(__file__).resolve().parent
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
read = lambda name: json.loads((out/name).read_text()) if (out/name).exists() else {}
ui = read('native-ui.json')
run = read('native-ui-run.json')
rows = ui.get('rows', [])
groups = []
for entry in ['mixed','file-mode']:
    for group in ['lexical','cross_language']:
        selected = [r for r in rows if r['entry']==entry and r['group']==group]
        metrics = {}
        for key in ['publication_ms','layout_ax_ms','complete_query_ms']:
            values = sorted(r[key] for r in selected)
            if values:
                metrics[key] = {f'p{p}':values[min(len(values)-1, math.ceil(len(values)*p/100)-1)] for p in [50,95,99]}
                metrics[key]['max']=max(values)
        groups.append({'entry':entry,'group':group,'samples':len(selected),'metrics':metrics})
if rows:
    with (out/'native-ui.csv').open('w') as f:
        writer=csv.DictWriter(f,fieldnames=list(rows[0]));writer.writeheader();writer.writerows(rows)
app=root/'.build/candidate/Typeflux.app'
products=root/'.build/out/Products/Release'
identities={str(p.relative_to(root)):{'sha256':sha(p),'bytes':p.stat().st_size} for p in [
    app/'Contents/MacOS/Typeflux',app/'Contents/Helpers/TypefluxInferenceHelper',
    app/'Contents/Helpers/TypefluxMediaHelper',app/'Contents/Resources/LocalRuntimes/SemanticSearch/TypefluxSemanticHelper',
    products/'TypefluxFocusedTests.xctest/Contents/MacOS/TypefluxFocusedTests'] if p.exists()}
profiles=sorted((root/'.build/candidate').glob('*.profraw'))
profile_report={'raw_files':{p.name:{'sha256':sha(p),'bytes':p.stat().st_size} for p in profiles},
                'scope':'Unchanged optimized semantic helper execution counters. Host/test products are not newly coverage-instrumented; Swift changed lines are 0/0 N/A.'}
if profiles:
    merged=root/'.build/candidate/helper.profdata'
    result=subprocess.run(['xcrun','llvm-profdata','merge','-sparse',*[str(p) for p in profiles],'-o',str(merged)],capture_output=True,text=True)
    profile_report.update(merge_exit_code=result.returncode,merge_error=result.stderr)
    if result.returncode==0:
        with (out/'helper.profdata.gz').open('wb') as f:
            with gzip.GzipFile(fileobj=f,mode='wb',mtime=0) as g:g.write(merged.read_bytes())
        profile_report['merged_sha256']=sha(merged)
(out/'binary-profile.json').write_text(json.dumps({'binaries':identities,'profile':profile_report},indent=2)+'\n')
tools=[root/'scripts'/name for name in ['build_release.sh','copy_inference_helper.sh','copy_media_helper.sh',
       'copy_resource_bundles.sh','install_semantic_helper.sh','build_semantic_helper.sh','audit_macho_minos.sh',
       'test_groups.py','test_runtime.py','test_profiles.py','tests/test_release_packaging.py','tests/test_macho_audit.py']]
tools += list(out.glob('*.py'))+[root/'Tests/TypefluxTests/SemanticReleaseUISliceTests.swift']
(out/'tool-manifest.json').write_text(json.dumps({str(p.relative_to(root)):sha(p) for p in sorted(tools)},indent=2)+'\n')
summary={'native_pass':run.get('exit_code')==0 and ui.get('complete') is True and len(rows)==12,
         'native_stage':ui.get('stage','no report'),'groups':groups,'mutation':ui.get('mutation',{}),
         'package_pass':bool(read('package.json')) and all(x['exit_code']==0 for x in read('package.json').get('records',[])),
         'native_commands':{p.name:json.loads(p.read_text()).get('wall_seconds') for p in out.glob('native-ui-run*.json')},
         'changed_swift_coverage':{name:{'covered':0,'executable_lines':0,'status':'N/A'} for name in ['application','file-helper','native-helper','runtime']},
         'limits':'Three observations per entry/group over 50 existing text sources. No 100k latency, broad quality, physical HID/monitor presentation, or sustained resource acceptance.'}
(out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
text=['\nFinal observed native results: '+('pass' if summary['native_pass'] else 'partial; see raw failure/stage')+'.\n',
      '| Entry | Group | n | publication p50 / p95 ms | layout/AX p50 / p95 ms | complete-query p95 ms |',
      '| --- | --- | ---: | --- | --- | --- |']
for g in groups:
    m=g['metrics']
    fmt=lambda key: ' / '.join(f"{m[key][p]:.2f}" for p in ['p50','p95']) if key in m else 'unmeasured'
    complete=f"{m['complete_query_ms']['p95']:.2f}" if 'complete_query_ms' in m else 'unmeasured'
    text.append(f"| {g['entry']} | {g['group']} | {g['samples']} | {fmt('publication_ms')} | {fmt('layout_ax_ms')} | {complete} |")
text.append('\nThese small-sample quantiles describe the observations only; they are not scale latency acceptance. The new complete-query column includes semantic completion after the FTS first screen. See raw source version/chunk/offset records and FSEvents mutation timing in `native-ui.json`.')
(out/'results.md').write_text('\n'.join(text)+'\n')
# Only task-owned generated evidence is sanitized. Production sources and captured pixels are untouched.
for p in out.iterdir():
    if p.suffix in ['.json','.log','.csv']:
        s=p.read_text()
        s=s.replace(str(root),'<repo>')
        s=re.sub(r'/Users/[^/]+/multica_workspaces_desktop-api\.multica\.ai/gulu-[^/]+/gul-405-[^/]+/workdir/typeflux','<accepted-cache>',s)
        s=re.sub(r'/tmp/multica-task-[^/]+/tmp[^/\s\"\']+','<fixture>',s)
        s=re.sub(r'/Users/[^/]+','<user>',s)
        p.write_text(s)
for p in out.glob('*.log'):
    with (p.with_suffix(p.suffix+'.gz')).open('wb') as f:
        with gzip.GzipFile(fileobj=f,mode='wb',mtime=0) as g:g.write(p.read_bytes())
    p.unlink()
print(json.dumps({'native_pass':summary['native_pass'],'rows':len(rows),'stage':summary['native_stage']}))
