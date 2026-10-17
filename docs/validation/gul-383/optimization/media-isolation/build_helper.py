#!/usr/bin/env python3
"""Build only the changed native Swift helper against the retained pinned native archive."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time


def sha(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--native-cache', type=Path, required=True)
    args = parser.parse_args()
    start = time.monotonic()
    root = Path.cwd()
    out = Path(__file__).resolve().parent
    cache = args.native_cache.resolve()
    scratch = root / '.build/media-isolation'
    scratch.mkdir(parents=True, exist_ok=True)
    source = root / 'Sources/TypefluxSemanticHelper/main.swift'
    binary = scratch / 'TypefluxSemanticHelper-coverage'
    command = ['swiftc', '-O', '-profile-generate', '-profile-coverage-mapping', '-target',
               'arm64-apple-macos14.0', '-I', str(cache / 'include'), '-L', str(cache / 'lib'),
               str(source), '-o', str(binary)]
    result = subprocess.run(command, capture_output=True, text=True)
    (out / 'helper-build.log').write_text((result.stdout + result.stderr)
                                        .replace(str(root), '<repo>').replace(str(cache), '<native-cache>'))
    record = {'wall_seconds': time.monotonic() - start, 'exit_code': result.returncode,
              'command': [part.replace(str(root), '<repo>').replace(str(cache), '<native-cache>') for part in command],
              'source_sha256': sha(source)}
    if result.returncode == 0:
        record['binary_sha256'] = sha(binary)
    (out / 'helper-build.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record))
    raise SystemExit(result.returncode)


if __name__ == '__main__':
    main()
