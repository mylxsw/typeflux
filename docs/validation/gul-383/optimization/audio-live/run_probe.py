"""One bounded production audio pass; retain synthetic vectors before clearing private state."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import struct
import subprocess
import time
import wave
from observer import started_identity


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def write(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--cache-checkout', type=Path, required=True)
parser.add_argument('--video', action='store_true')
parser.add_argument('--reuse', action='store_true')
parser.add_argument('--label', default='live-visible-root')
parser.add_argument('--seconds', type=int, default=75)
args = parser.parse_args()
assert 1 <= args.seconds <= 90
started = time.monotonic()
root = Path.cwd()
source = Path(__file__).resolve().parent
assert Path(args.label).name == args.label and args.label not in ['.', '..']
out = source / args.label
out.mkdir()
private = root / ('gul405-audio-runtime-' + str(os.getpid()))
private.mkdir(mode=0o700)
cache = args.cache_checkout.resolve()
corpus = private / 'corpus'
models = private / 'models'
corpus.mkdir(mode=0o700)
models.mkdir(mode=0o700)
binary = root / ('.build/audio-live/VideoProbe' if args.video else ('.build/audio-live/ServiceProbe' if args.reuse else '.build/audio-live/AudioProbe'))
helper = cache / '.build/stage-budget/ProductSemanticHelper'
app = cache / '.build/video-frames/arm64-apple-macosx/debug/Typeflux'
process = None
identities = {}
record = {'stage_seconds': args.seconds, 'budget_enabled': True, 'idle_callback_controlled': True}
try:
    build = json.loads((source / ('video-binary.json' if args.video else ('service-binary.json' if args.reuse else 'probe-binary.json'))).read_text())
    assert sha(binary) == build['sha256']
    assert sha(source / ('video_probe.swift' if args.video else ('service_probe.swift' if args.reuse else 'executed_audio_probe.swift'))) == build['source_sha256']
    native = json.loads((source.parent / 'media-isolation/read-signals/product-native-build.json').read_text())
    assert sha(helper) == native['binary_sha256']
    assert sha(root / 'Sources/TypefluxSemanticHelper/main.swift') == native['source_sha256']
    products = json.loads((source.parent / 'media-isolation/read-signals/product-binaries.json').read_text())
    assert sha(app) == products['file-helper']
    expected = json.loads((source.parent / 'real-path-short/runtime-fingerprints.json').read_text())
    fingerprints = {'probe': sha(binary), 'file-helper': sha(app), 'model-helper': sha(helper)}
    for name in ['embeddinggemma-2-Q8_0.gguf', 'mmproj-embeddinggemma-2-Q8_0.gguf']:
        asset = cache / '.build/model-assets' / name
        assert sha(asset) == expected[name]['sha256']
        subprocess.run(['/bin/cp', '-c', str(asset), str(models / name)], check=True)
        (models / name).chmod(0o600)
        fingerprints[name] = expected[name]
    fixture = corpus / 'boundary.wav'
    with wave.open(str(fixture), 'wb') as audio:
        audio.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
        samples = [int(math.sin(i * 0.17) * 0.1 * 32767) if 29 * 16000 <= i < 31 * 16000 else 0
                   for i in range(56 * 16000)]
        audio.writeframes(struct.pack('<' + 'h' * len(samples), *samples))
    if args.video:
        fixture.unlink()
        fixture = corpus / 'scene.mov'
        shutil.copyfile(source.parent / 'video-frames/short-scene.mov', fixture)
    fingerprints['fixture'] = sha(fixture)
    shutil.copyfile(fixture, out / ('scene.mov' if args.video else 'boundary.wav'))
    write(out / 'fingerprints.json', fingerprints)
    shutil.copyfile(Path(__file__), out / 'executed_runner.py')
    shutil.copyfile(source / ('video_probe.swift' if args.video else ('service_probe.swift' if args.reuse else 'executed_audio_probe.swift')), out / 'executed_probe.swift')
    env = dict(os.environ)
    dev = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
    trace = out / 'trace.jsonl'
    trace.touch()
    env.update(GUL405_REPORT=str(out / 'report.json'), GUL405_TRACE=str(trace),
               GUL405_PRIVATE_ROOT=str(private), GUL405_MODEL_HELPER=str(helper),
               GUL405_FILE_HELPER=str(app), GUL405_MEDIA='video' if args.video else 'audio', GUL405_MODE='service',
               GUL405_STAGE_SECONDS=str(args.seconds),
               LLVM_PROFILE_FILE=str(root / '.build/audio-live/probe-%p.profraw'),
               DYLD_FRAMEWORK_PATH=str(dev / 'Platforms/MacOSX.platform/Developer/Library/Frameworks'),
               DYLD_LIBRARY_PATH=str(dev / 'Platforms/MacOSX.platform/Developer/usr/lib'))
    snapshots = []
    with (out / 'runtime.log').open('w') as log:
        process = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        deadline = time.monotonic() + args.seconds + 20
        while process.poll() is None and time.monotonic() < deadline:
            raw = subprocess.check_output(['ps', '-axo', 'pid,ppid,stat,%cpu,rss,time,comm'], text=True)
            rows = [line.split(None, 6) for line in raw.splitlines()[1:]]
            owned = {process.pid}
            for _ in range(len(rows)):
                more = owned | {int(r[0]) for r in rows if len(r) == 7 and int(r[1]) in owned}
                if more == owned:
                    break
                owned = more
            selected = [r for r in rows if len(r) == 7 and int(r[0]) in owned]
            for r in selected:
                pid = int(r[0])
                if pid not in identities:
                    identity = started_identity(pid)
                    if identity is not None:
                        identities[pid] = identity
            snapshots.append({'seconds': time.monotonic() - started, 'processes': selected})
            write(out / 'processes.json', snapshots)
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                pass
        record['exit_code'] = process.poll() if process.poll() is not None else 124
except Exception as error:
    record['runner_error'] = str(error)
    record['wrapper_exit_code'] = 1
finally:
    # Only exact children with matching launch identities can be signalled.
    daemon = json.loads(subprocess.check_output(['multica', 'daemon', 'status', '--output', 'json'], text=True))
    for pid, identity in identities.items():
        observed = subprocess.run(['ps', '-p', str(pid), '-o', 'lstart=,comm='], capture_output=True, text=True)
        if observed.stdout.strip() == identity:
            assert pid != daemon['pid']
            os.kill(pid, signal.SIGCONT)
            os.kill(pid, signal.SIGKILL)
    if process is not None:
        process.wait(timeout=5)
        record['probe_exit_code'] = process.returncode
        record.setdefault('exit_code', process.returncode)
    db = models / 'semantic-files.sqlite'
    if db.exists() and not (out / 'final.sqlite').exists():
        with sqlite3.connect(db) as original, sqlite3.connect(out / 'emergency.sqlite') as backup:
            original.backup(backup)
    # Database and generated vectors have independent retained copies; remove only this private model clone.
    shutil.rmtree(private)
    record['wall_seconds'] = time.monotonic() - started
    record['private_root_removed'] = not private.exists()
    write(out / 'command.json', record)
    print(json.dumps(record), flush=True)
raise SystemExit(record.get('wrapper_exit_code', record.get('exit_code', 1)))
