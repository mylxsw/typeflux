"""Compile the observer and link against the just-validated product objects."""
import hashlib
import json
from pathlib import Path
import subprocess
import time
import shlex
import sys

root = Path.cwd()
out = Path(__file__).resolve().parent
stage = out.parent / 'stage-budget'
build = root / '.build/video-frames/arm64-apple-macosx/debug'
scratch = root / '.build/stage-budget'
sha = lambda p: hashlib.file_digest(p.open('rb'), 'sha256').hexdigest()
started = time.monotonic()
description = json.loads((build / 'description.json').read_text())
info = description['swiftCommands']['C.TypefluxFocusedTests-arm64-apple-macosx-debug.module']
clean = []; i = 0
other = info['otherArguments']
while i < len(other):
    flag = other[i]
    if flag in ['-index-store-path', '-module-cache-path']: i += 2
    elif flag in ['-incremental', '-enable-batch-mode', '-serialize-diagnostics', '-parseable-output'] or flag.startswith('-j'):
        i += 1
    else: clean.append(flag); i += 1
source = stage / 'media_probe.swift'
obj = scratch / 'product-probe.o'
compile_command = [info['executable'], '-c', str(source), '-I', str(build / 'Modules'),
    '-module-name', 'GUL405StageBudget', '-o', str(obj), *clean]
lines = (root / '.build/video-frames/debug.yaml').read_text().splitlines()
link = next(json.loads(lines[i+1].split('args: ', 1)[1]) for i, line in enumerate(lines)
    if 'description: "Linking' in line and 'TypefluxPackageTests' in line)
original = next(p[1:] for p in link if p.startswith('@') and p.endswith('Objects.LinkFileList'))
selected = [p for p in Path(original).read_text().splitlines()
    if '/TypefluxPackageTests.build/' not in p and '/TypefluxPackageDiscoveredTests.build/' not in p]
filelist = scratch / 'ProductProbe.LinkFileList'
filelist.write_text('\n'.join([*selected, str(obj)]) + '\n')
binary = scratch / 'MediaProbe'
linked = []; i = 0
while i < len(link):
    if link[i:i+2] == ['-Xlinker', '-bundle']: i += 2; continue
    if link[i] == '-o': linked.extend(['-o', str(binary)]); i += 2; continue
    linked.append('@' + str(filelist) if link[i].startswith('@') and link[i].endswith('Objects.LinkFileList') else link[i])
    i += 1
collect_only = '--collect-linked' in sys.argv
if collect_only:
    records = json.loads((out / 'product-probe-build.json').read_text())
    assert len(records) == 2 and all(r['exit_code'] == 0 for r in records)
    assert binary.is_file() and obj.stat().st_mtime >= source.stat().st_mtime
else:
    records = []
    for label, command in [('compile-product-probe', compile_command), ('link-product-probe', linked)]:
        s = time.monotonic(); p = subprocess.run(command, capture_output=True, text=True)
        records.append({'phase': label, 'wall_seconds': time.monotonic()-s, 'exit_code': p.returncode})
        (out / (label + '.log')).write_text(p.stdout+p.stderr)
        (out / 'product-probe-build.json').write_text(json.dumps(records, indent=2)+'\n')
        if p.returncode: print((p.stdout+p.stderr)[-4000:]); raise SystemExit(p.returncode)
paths = [Path(shlex.split(p)[0]) for p in selected]
objects = {str(p.relative_to(root)): sha(p) for p in paths}
(out / 'product-linked-objects.json').write_text(json.dumps(objects, indent=2)+'\n')
(stage / 'probe-binary.json').write_text(json.dumps({'sha256': sha(binary), 'source_sha256': sha(source),
    'reused_object_count': len(selected), 'configuration': 'Current Debug coverage product objects; no interposition'}, indent=2)+'\n')
(out / 'product-binaries.json').write_text(json.dumps({'file-helper': sha(build/'Typeflux'),
    'probe': sha(binary), 'worker_source': sha(root/'Sources/Typeflux/Ask/QuickResults/Semantic/SemanticEmbeddingWorker.swift')}, indent=2)+'\n')
(out / 'product-probe-total.json').write_text(json.dumps({'wall_seconds':time.monotonic()-started,'exit_code':0,
    'metadata_only_retry':collect_only,'compile_link_seconds':sum(r['wall_seconds'] for r in records)},indent=2)+'\n')
print('Product probe linked:', len(selected), 'objects')
