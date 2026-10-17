"""Fetch only the pinned semantic runtime license inputs used by normal packaging."""
import hashlib
import json
from pathlib import Path
import subprocess
import time

started = time.monotonic()
revision = '4d756bc72bf00a4aacf410ae15a2d315f3db400d'
paths = ['LICENSE', 'licenses/LICENSE-jsonhpp', 'vendor/hash/xxhash/LICENSE',
         'vendor/hash/sha256/LICENSE', 'vendor/hash/rotate-bits/LICENSE.md']
root = Path.cwd() / '.build/license-source'
manifest = {}
for name in paths:
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    data = subprocess.check_output(['gh', 'api', f'repos/ggml-org/llama.cpp/contents/{name}?ref={revision}',
                                    '-H', 'Accept: application/vnd.github.raw+json'])
    path.write_bytes(data)
    manifest[name] = hashlib.sha256(data).hexdigest()
Path(__file__).with_name('license-inputs.json').write_text(json.dumps(
    {'revision': revision, 'files': manifest, 'wall_seconds': time.monotonic()-started}, indent=2) + '\n')
print('Pinned license inputs:', len(manifest))
