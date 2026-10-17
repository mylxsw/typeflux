"""Record actual measured products and retained instrumented helper profiles."""
import gzip
import hashlib
import json
from pathlib import Path
import subprocess

root = Path.cwd()
out = Path(__file__).resolve().parent
def item(path):
    return {'bytes': path.stat().st_size, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
paths = ['.build/out/Products/Release/Typeflux',
         '.build/out/Products/Release/TypefluxFocusedTests.xctest/Contents/MacOS/TypefluxFocusedTests',
         '.build/semantic/TypefluxSemanticHelper', '.build/semantic/embeddinggemma-2-Q8_0.gguf',
         '.build/SemanticNativeResponseProbe.app/Contents/MacOS/SemanticNativeResponseProbe',
         '.build/candidate/Typeflux.app/Contents/MacOS/Typeflux']
objects = {}
for path in (root / '.build/out').rglob('*.o'):
    if '/Typeflux.build/' in str(path) or '/TypefluxFocusedTests.build/' in str(path):
        objects[str(path.relative_to(root))] = item(path)
profiles = {}
for path in sorted((root / '.build').glob('scale-resource-helper-*.profraw')):
    profiles[path.name] = item(path)
    if path.stat().st_size:
        folder = out / 'raw-profiles'
        folder.mkdir(exist_ok=True)
        (folder / (path.name + '.gz')).write_bytes(gzip.compress(path.read_bytes(), mtime=0))
source = json.loads((out / 'source-freeze.json').read_text())
for name, expected in source['production_sha256'].items():
    assert item(root / name)['sha256'] == expected, name
source['test_sha256'] = {name: item(root / name)['sha256'] for name in source['test_sha256']}
(out / 'source-freeze.json').write_text(json.dumps(source, indent=2) + '\n')
report = {'source_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
          'binaries': {name: item(root / name) for name in paths}, 'objects': objects, 'profiles': profiles,
          'boundary': 'Current Release app/test source and linked products. Unchanged native helper remains the accepted first-slice instrumented optimized binary. Empty helper-exit profiles are retained as zero-byte observations; no new product coverage inferred.'}
(out / 'binary-profile.json').write_text(json.dumps(report, indent=2) + '\n')
print('fingerprinted binaries', len(paths), 'objects', len(objects), 'profiles', len(profiles))
