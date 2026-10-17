#!/usr/bin/env python3
"""Link only the new probe against fingerprinted, accepted Debug objects. No product rebuild."""
import argparse, hashlib, json, os, subprocess, time
from pathlib import Path


def sha(p):
    with p.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache-checkout', type=Path, required=True)
    args = parser.parse_args()
    root = Path.cwd()
    out = Path(__file__).resolve().parent
    scratch = root / '.build/media-isolation'
    scratch.mkdir(parents=True, exist_ok=True)
    cache = args.cache_checkout.resolve()
    build = cache / '.build/video-frames/arm64-apple-macosx/debug'
    description = json.loads((build / 'description.json').read_text())
    compile_info = description['swiftCommands']['C.TypefluxFocusedTests-arm64-apple-macosx-debug.module']
    frozen = json.loads((root / 'docs/validation/gul-383/optimization/download-resume/inputs-final.json').read_text())
    matched, changed = {}, {}
    for name, digest in frozen.items():
        if not name.startswith(('Sources/', 'Tests/', 'Packages/', 'scripts/')):
            continue
        cached = cache / name
        assert cached.is_file() and sha(cached) == digest, 'Cache source changed: ' + name
        current = root / name
        if current.is_file() and sha(current) == digest:
            matched[name] = digest
        else:
            changed[name] = {'cached_sha256': digest, 'current_sha256': sha(current) if current.is_file() else None}
    # Changes outside the accepted search closure are disclosed, never called current-main full-tree testing.
    relevant = ('/Semantic/', '/Files/', '/TypefluxMedia', '/TypefluxSemanticHelper/')
    assert not any(any(token in n for token in relevant) for n in changed), changed
    object_manifest = json.loads((root / 'docs/validation/gul-383/optimization/download-resume/objects-final.json').read_text())
    objects = {name: digest for name, digest in object_manifest.items() if (cache / name).is_file()}
    assert all(sha(cache / name) == digest for name, digest in objects.items()), 'Accepted objects changed'
    (out / 'cached-input-reconciliation.json').write_text(json.dumps({'matched': matched, 'changed': changed,
        'scope': 'Accepted PR646 Debug objects. Main-only changes disclosed; relevant search and worker sources match.'}, indent=2) + '\n')
    (out / 'reused-objects.json').write_text(json.dumps(objects, indent=2) + '\n')
    modules = json.loads((root / 'docs/validation/gul-383/optimization/real-path-short/cached-modules-resources.json').read_text())
    assert all(sha(cache / name) == digest for name, digest in modules.items()), 'Accepted modules/resources changed'
    (out / 'reused-modules-resources.json').write_text(json.dumps(modules, indent=2) + '\n')
    other = compile_info['otherArguments']
    clean = []
    i = 0
    while i < len(other):
        flag = other[i]
        if flag in ['-index-store-path', '-module-cache-path']:
            i += 2
        elif flag in ['-incremental', '-enable-batch-mode', '-serialize-diagnostics', '-parseable-output', '-j10']:
            i += 1
        else:
            clean.append(flag); i += 1
    source = out / 'media_probe.swift'
    obj = scratch / 'probe.o'
    command = [compile_info['executable'], '-c', str(source), '-I', str(build / 'Modules'),
        '-module-name', 'GUL405MediaIsolation', '-o', str(obj), *clean]
    lines = (cache / '.build/video-frames/debug.yaml').read_text().splitlines()
    link = next(json.loads(lines[i+1].split('args: ', 1)[1]) for i, line in enumerate(lines)
        if 'description: "Linking' in line and 'TypefluxPackageTests' in line)
    old_list = next(x[1:] for x in link if x.startswith('@') and x.endswith('Objects.LinkFileList'))
    selected = [line for line in Path(old_list).read_text().splitlines()
                if '/TypefluxPackageTests.build/' not in line and '/TypefluxPackageDiscoveredTests.build/' not in line]
    filelist = scratch / 'Objects.LinkFileList'
    filelist.write_text('\n'.join([*selected, str(obj)]) + '\n')
    binary = scratch / 'MediaProbe'
    linked = []
    i = 0
    while i < len(link):
        if link[i:i+2] == ['-Xlinker', '-bundle']:
            i += 2; continue
        if link[i] == '-o':
            linked.extend(['-o', str(binary)]); i += 2; continue
        if link[i].startswith('@') and link[i].endswith('Objects.LinkFileList'):
            linked.append('@' + str(filelist))
        else:
            linked.append(link[i])
        i += 1
    records = []
    for label, command in [('compile-probe', command), ('link-probe', linked)]:
        start = time.monotonic()
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        log = result.stdout.replace(str(cache), '<accepted-cache>').replace(str(root), '<repo>')
        (out / (label + '.log')).write_text(log)
        records.append({'phase': label, 'wall_seconds': time.monotonic() - start, 'exit_code': result.returncode})
        (out / 'build-commands.json').write_text(json.dumps(records, indent=2) + '\n')
        print(records[-1], flush=True)
        if result.returncode:
            print(log[-6000:]); raise SystemExit(result.returncode)
    (out / 'probe-binary.json').write_text(json.dumps({'sha256': sha(binary), 'source_sha256': sha(source),
        'reused_object_count': len(selected), 'configuration': 'Debug, accepted coverage-instrumented production objects'}, indent=2) + '\n')


if __name__ == '__main__':
    main()
