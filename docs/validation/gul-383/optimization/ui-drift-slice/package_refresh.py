"""Refresh only the current app/resources around the verified unchanged native helper."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import time

root = Path.cwd()
out = Path(__file__).resolve().parent
app = root / '.build/candidate/Typeflux.app'
products = root / '.build/out/Products/Release'
start = time.monotonic()
records = []
def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
def run(command):
    before = time.monotonic()
    result = subprocess.run(command, capture_output=True, text=True)
    records.append({'command': command, 'wall_seconds': time.monotonic() - before,
                    'exit_code': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr})
    if result.returncode:
        (out / 'package-refresh-failure.json').write_text(json.dumps(records, indent=2) + '\n')
        raise RuntimeError(result.stderr)

helper = app / 'Contents/Resources/LocalRuntimes/SemanticSearch/TypefluxSemanticHelper'
helper_before = sha(helper)
for source, target in [(products / 'Typeflux', app / 'Contents/MacOS/Typeflux')]:
    shutil.copy2(source, target)
for script, target in [('copy_inference_helper.sh', app), ('copy_media_helper.sh', app),
                       ('copy_resource_bundles.sh', app / 'Contents/Resources')]:
    run(['bash', str(root / 'scripts' / script), str(products), str(target)])
run(['codesign', '--force', '--sign', '-', '--options', 'runtime', str(app / 'Contents/Helpers/swift-transformers_Hub.bundle')])
for target in ['Contents/Helpers/TypefluxInferenceHelper', 'Contents/Helpers/TypefluxMediaHelper', 'Contents/MacOS/Typeflux']:
    path = app / target
    path.chmod(0o755)
    run(['codesign', '--force', '--sign', '-', '--options', 'runtime', str(path)])
run(['codesign', '--force', '--sign', '-', '--options', 'runtime', '--entitlements', str(root / 'app/TypefluxRuntime.entitlements'), str(app)])
run(['codesign', '--verify', '--deep', '--strict', '--verbose=2', str(app)])
run(['bash', str(root / 'scripts/audit_macho_minos.sh'), str(app), '13.4', 'arm64'])
assert sha(helper) == helper_before == sha(root / '.build/semantic/TypefluxSemanticHelper')
manifest = {str(path.relative_to(app)): {'sha256': sha(path), 'bytes': path.stat().st_size}
            for path in sorted(app.rglob('*')) if path.is_file()}
(out / 'bundle-files.json').write_text(json.dumps(manifest, indent=2) + '\n')
(out / 'package-refresh.json').write_text(json.dumps({'source_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    'records': records, 'wall_seconds': time.monotonic() - start, 'native_helper_unchanged_sha256': helper_before,
    'scope': 'Current-source app/file helper and current resource/helper copy scripts; unchanged signed semantic helper retained. Local ad-hoc arm64 signature/architecture/deployment audit, no distribution/notarization claim.'}, indent=2) + '\n')
print('package verified; files', len(manifest), 'seconds', time.monotonic() - start)
