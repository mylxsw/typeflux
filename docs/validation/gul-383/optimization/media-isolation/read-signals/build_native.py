"""Build unchanged candidate native source with the pinned archive; no diagnostic hooks."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

root = Path.cwd()
out = Path(__file__).resolve().parent
cache = Path(sys.argv[1]).resolve()
sha = lambda path: hashlib.file_digest(path.open('rb'), 'sha256').hexdigest()
started = time.monotonic()
pinned = json.loads((out.parent / 'native-dependencies.json').read_text())
assert all(sha(cache / name) == digest for name, digest in pinned.items())
source = root / 'Sources/TypefluxSemanticHelper/main.swift'
binary = root / '.build/stage-budget/ProductSemanticHelper'
command = ['swiftc', '-O', '-profile-generate', '-profile-coverage-mapping', '-target',
           'arm64-apple-macos14.0', '-I', str(cache / 'include'), '-L', str(cache / 'lib'),
           str(source), '-o', str(binary)]
result = subprocess.run(command, capture_output=True, text=True)
record = {'command': [p.replace(str(root), '<repo>').replace(str(cache), '<native-cache>') for p in command],
          'wall_seconds': time.monotonic() - started, 'exit_code': result.returncode,
          'source_sha256': sha(source)}
if result.returncode == 0: record['binary_sha256'] = sha(binary)
(out / 'product-native-build.json').write_text(json.dumps(record, indent=2) + '\n')
(out / 'product-native-build.log').write_text(result.stdout + result.stderr)
print(json.dumps(record))
raise SystemExit(result.returncode)
