#!/usr/bin/env python3
"""Check the isolated rejection contract and collect the helper's own counters."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import uuid

root = Path.cwd().resolve()
out = Path(__file__).resolve().parent
helper = root / '.build/video-frames/arm64-apple-macosx/debug/TypefluxMediaHelper'
fixture = out.parent.parent / 'video-frames/longer-audio.mov'
expected = '902e4d62bc5f6b745963c89766e680b917a8cd1104c9ef733f698b31d73195ec'
assert hashlib.sha256(fixture.read_bytes()).hexdigest() == expected
profiles = out / 'helper-profiles'
profiles.mkdir(exist_ok=True)
env = {'PATH': '/usr/bin:/bin', 'LANG': 'en_US.UTF-8',
       'LLVM_PROFILE_FILE': str(profiles / 'helper-%p.profraw')}
records = []
started = time.monotonic()
for start in (1.5, 7, 1.55):
    with tempfile.TemporaryDirectory(prefix='preview-contract-', dir=root / '.build') as folder:
        directory = Path(folder)
        shutil.copyfile(fixture, directory / 'input')
        request = {'version': 1, 'id': str(uuid.uuid4()), 'operation': 'previewVideo',
                   'preview': {'width': 400, 'height': 400, 'start': start, 'container': 'mov'}}
        began = time.monotonic()
        result = subprocess.run([str(helper)], input=json.dumps(request), text=True,
                                capture_output=True, cwd=directory, env=env, timeout=5, check=True)
        response = json.loads(result.stdout)
        assert response['id'].lower() == request['id'].lower()
        assert not result.stderr, result.stderr
        if start == 1.5:
            assert response['preview']['start'] == start and len(response['preview']['rasters']) == 1
            assert (directory / 'raster-0').is_file()
        else:
            assert response.get('failure') == 'unreadable', response
            assert response.get('preview') is None and not (directory / 'raster-0').exists()
        assert not (directory / 'decode.mov').exists()
        records.append({'start': start, 'response': response, 'wall_seconds': time.monotonic() - began})
record = {'command': 'python3 ' + str(Path(__file__).relative_to(root)),
          'wall_seconds': time.monotonic() - started, 'cases': records,
          'fixture_sha256': expected, 'helper_sha256': hashlib.sha256(helper.read_bytes()).hexdigest()}
(out / 'helper-contract.json').write_text(json.dumps(record, indent=2) + '\n')
print(json.dumps({'cases_passed': len(records), 'wall_seconds': record['wall_seconds']}))
