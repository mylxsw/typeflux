"""Build the small observer only; retain every build attempt."""
import hashlib
import json
from pathlib import Path
import subprocess
import time

out = Path(__file__).resolve().parent
binary = Path.cwd() / '.build/stage-budget/observe.dylib'
attempt = 1
while (out / f'build-{attempt}.json').exists():
    attempt += 1
command = ['clang', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror', '-dynamiclib',
           str(out / 'observe.c'), '-o', str(binary)]
started = time.monotonic()
result = subprocess.run(command, capture_output=True, text=True)
record = {'command': [part.replace(str(Path.cwd()), '<repo>') for part in command],
          'wall_seconds': time.monotonic() - started, 'exit_code': result.returncode,
          'source_sha256': hashlib.file_digest((out / 'observe.c').open('rb'), 'sha256').hexdigest()}
if result.returncode == 0:
    record['binary_sha256'] = hashlib.file_digest(binary.open('rb'), 'sha256').hexdigest()
(out / f'build-{attempt}.log').write_text(result.stdout + result.stderr)
(out / f'build-{attempt}.json').write_text(json.dumps(record, indent=2) + '\n')
if result.returncode == 0:
    (out / 'build.json').write_text(json.dumps(record, indent=2) + '\n')
print(json.dumps(record))
raise SystemExit(result.returncode)
