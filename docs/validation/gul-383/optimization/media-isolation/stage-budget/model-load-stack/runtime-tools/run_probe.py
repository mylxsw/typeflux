#!/usr/bin/env python3
"""Observe one synthetic media path with pinned cached assets and production budgets."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import shlex
import signal
import sqlite3
import struct
import subprocess
import time
import wave


def sha(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def write(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def sample_gate(events, trace, owned, identities, helper, launched, now, parent_deadline, stage_seconds):
    """Return the first owned loader PID, or a recorded reason to skip this one attempt."""
    begins = [e for e in events if e.get('stage') == 'model-begin']
    if not begins:
        return None
    event = begins[0]
    pid = event.get('pid')
    result = {'pid': pid, 'phase': event, 'trigger_monotonic': now}
    paths = {int(row[0]): row[7] for row in owned}
    if (not isinstance(pid, int) or paths.get(pid) != str(helper)
            or not identities.get(pid) or not isinstance(event.get('uptime'), (int, float))
            or not launched <= event['uptime'] <= now):
        return dict(result, skipped='stage PID/start identity is not an owned current helper')
    origin = next((e['uptime'] - e['seconds'] for e in trace
                   if isinstance(e.get('uptime'), (int, float))
                   and isinstance(e.get('seconds'), (int, float))), None)
    if origin is None:
        return dict(result, skipped='probe clock unavailable; cannot prove remaining cutoff')
    remaining = min(origin + stage_seconds, parent_deadline) - now
    result.update(identity=identities[pid], remaining_before_cutoff_seconds=remaining,
                  tool_limit_seconds=12, cleanup_reserve_seconds=2)
    if any(e.get('pid') == pid and e.get('stage') == 'model-end' for e in events):
        return dict(result, skipped='loader already ended before sampling')
    if remaining < 14:
        return dict(result, skipped='less than 12 s tool processing plus 2 s cleanup remain')
    return result


def read_events(path):
    # An append can be observed before its newline; leave incomplete data for the next poll.
    result = []
    for line in path.read_text().splitlines():
        try:
            value = json.loads(line)
            if isinstance(value, dict):
                result.append(value)
        except json.JSONDecodeError:
            continue
    return result


def capture_stack(out, record, expected_identity):
    pid = record['pid']
    current = subprocess.run(['ps', '-p', str(pid), '-o', 'lstart=,comm='],
                             capture_output=True, text=True, timeout=1)
    record['identity_before_sample'] = current.stdout.strip()
    if record['identity_before_sample'] != expected_identity:
        record['skipped'] = 'PID start identity changed before sample'
        return
    started = time.monotonic()
    command = ['/usr/bin/sample', str(pid), '1', '1', '-file', str(out / 'current-stack.txt')]
    record['command'] = command
    # Files retain partial output even when symbolication exceeds the tool deadline.
    with (out / 'sample.stdout.txt').open('w') as stdout, (out / 'sample.stderr.txt').open('w') as stderr:
        try:
            result = subprocess.run(command, stdout=stdout, stderr=stderr, timeout=12)
            record['exit_code'] = result.returncode
        except subprocess.TimeoutExpired:
            record['timeout_seconds'] = 12
    record['wall_seconds'] = time.monotonic() - started
    record['stack_file_exists'] = (out / 'current-stack.txt').is_file()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache-checkout', type=Path, required=True)
    parser.add_argument('--model-assets', type=Path, required=True)
    parser.add_argument('--media', choices=['screenshot'], required=True)
    parser.add_argument('--stage-seconds', type=int, default=40)
    parser.add_argument('--cpu-registration', action='store_true', help='Diagnostic: suppress unused Metal device registration for the existing CPU media helper only')
    parser.add_argument('--label', help='Unique attempt directory; defaults to the media/configuration name')
    parser.add_argument('--fixed-helper', type=Path, help='Use the instrumented minimal helper fix recorded in helper-build.json')
    parser.add_argument('--mode', choices=['service', 'startup'], default='service')
    args = parser.parse_args()
    if not 1 <= args.stage_seconds <= 45:
        parser.error('stage-seconds must be in 1...45')
    started = time.monotonic()
    root = Path.cwd()
    source = Path(__file__).resolve().parent
    label = args.label or (args.media + ('-cpu-registration' if args.cpu_registration else ''))
    if Path(label).name != label or label in ['.', '..']:
        parser.error('label must be one directory name')
    out = Path(__file__).resolve().parent / label
    out.mkdir()  # Never overwrite an earlier run.
    private = root / ('gul405-media-runtime-' + str(os.getpid()))
    private.mkdir(mode=0o700)  # Creation succeeded before entering owned cleanup scope.
    corpus = private / 'corpus'; corpus.mkdir(mode=0o700)
    models = private / 'models'; models.mkdir(mode=0o700)
    cache = args.cache_checkout.resolve()
    assets = args.model_assets.resolve()
    binary = root / '.build/stage-budget/MediaProbe'
    app = cache / '.build/video-frames/arm64-apple-macosx/debug/Typeflux'
    helper = args.fixed_helper.resolve() if args.fixed_helper else assets / 'TypefluxSemanticHelper'
    replacements = [(str(private), '<private>'), (str(cache), '<accepted-cache>'),
                    (str(assets), '<model-cache>'), (str(root), '<repo>')]
    def clean(value):
        result = json.dumps(value)
        for old, new in replacements:
            result = result.replace(old, new)
        return json.loads(result)
    process = None
    code = 125
    record = {'media': args.media, 'mode': args.mode, 'stage_seconds': args.stage_seconds, 'budget_enabled': True}
    snapshots = []
    sampled = False
    owned_pids = set()
    owned_identity = {}
    fingerprints = {}
    try:
        expected = json.loads((source.parent.parent / 'real-path-short/runtime-fingerprints.json').read_text())
        built = json.loads((source / 'probe-binary.json').read_text())
        assert sha(binary) == built['sha256'], 'Probe build has not completed or binary changed'
        assert sha(source / 'media_probe.swift') == built['source_sha256'], 'Probe source/build mismatch'
        for name in ['embeddinggemma-2-Q8_0.gguf', 'mmproj-embeddinggemma-2-Q8_0.gguf']:
            path = assets / name
            digest = sha(path)
            assert digest == expected[name]['sha256'], 'Pinned weights changed'
            subprocess.run(['/bin/cp', '-c', str(path), str(models / name)], check=True)
            (models / name).chmod(0o600)
            fingerprints[name] = {'sha256': digest, 'bytes': path.stat().st_size}
        for name, path in [('file-helper', app), ('model-helper', helper), ('probe', binary)]:
            digest = sha(path)
            if name == 'model-helper' and args.fixed_helper:
                fixed = json.loads((source / 'helper-build.json').read_text())
                assert digest == fixed['binary_sha256'], 'Fixed helper build mismatch'
                assert sha(source / 'semantic_helper.swift') == fixed['source_sha256'], 'Fixed helper source mismatch'
            elif name != 'probe':
                assert digest == expected[name]['sha256'], 'Accepted helper changed'
            fingerprints[name] = {'sha256': digest, 'bytes': path.stat().st_size}
        if args.media == 'audio':
            # Exact boundary recipe from SemanticAudioWindowTests: 56 s, active 29..<31 s.
            fixture = corpus / 'boundary.wav'
            with wave.open(str(fixture), 'wb') as audio:
                audio.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
                samples = [int(math.sin(index * 0.17) * 0.1 * 32767)
                           if 29 * 16000 <= index < 31 * 16000 else 0 for index in range(56 * 16000)]
                audio.writeframes(struct.pack('<' + 'h' * len(samples), *samples))
            fingerprints['fixture_recipe'] = 'SemanticAudioWindowTests: 56 s/16 kHz, tone active 29..<31 s; PCM16 encoding'
        else:
            suffix = 'image-ocr-slice/synthetic-error.png' if args.media == 'screenshot' else 'video-frames/short-scene.mov'
            original = source.parent.parent / suffix
            fixture = corpus / ('screen.png' if args.media == 'screenshot' else 'scene.mov')
            shutil.copyfile(original, fixture)
            fingerprints['fixture_source'] = suffix
        fingerprints['fixture'] = {'sha256': sha(fixture), 'bytes': fixture.stat().st_size}
        write(out / 'runtime-fingerprints.json', fingerprints)
        env = dict(os.environ)
        dev = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
        (out / 'trace.jsonl').touch()
        (out / 'native-stages.jsonl').touch(mode=0o600)
        record['runner_start_monotonic'] = started
        record['launch_monotonic'] = time.monotonic()
        env.update(GUL405_REPORT=str(out / 'report.json'), GUL405_TRACE=str(out / 'trace.jsonl'),
                   GUL405_PRIVATE_ROOT=str(private), GUL405_MODEL_HELPER=str(helper),
                   GUL405_FILE_HELPER=str(app), GUL405_MEDIA=args.media,
                   GUL405_MODE=args.mode,
                   GUL405_STAGE_SECONDS=str(args.stage_seconds),
                   LLVM_PROFILE_FILE=str(root / '.build/stage-budget/probe-%p%c.profraw'),
                   GUL405_NATIVE_TRACE=str(out / 'native-stages.jsonl'),
                   DYLD_FRAMEWORK_PATH=str(dev / 'Platforms/MacOSX.platform/Developer/Library/Frameworks'),
                   DYLD_LIBRARY_PATH=str(dev / 'Platforms/MacOSX.platform/Developer/usr/lib'))
        if args.cpu_registration:
            wrapper = private / 'cpu-helper'
            wrapper.write_text('#!/bin/sh\nGGML_METAL_DEVICES=0 exec ' + shlex.quote(str(helper)) + ' "$@"\n')
            wrapper.chmod(0o700)
            env['GUL405_MEDIA_HELPER'] = str(wrapper)
            record['diagnostic_media_environment'] = {'GGML_METAL_DEVICES': '0'}
        versions = out / 'runtime-tools'
        versions.mkdir()
        for name in ['run_probe.py', 'build_probe.py', 'media_probe.swift', 'probe-binary.json']:
            shutil.copyfile(Path(__file__) if name == 'run_probe.py' else source / name, versions / name)
        if args.fixed_helper:
            shutil.copyfile(source / 'semantic_helper.swift', versions / 'semantic_helper.swift')
            shutil.copyfile(source / 'helper-build.json', versions / 'helper-build.json')
        with (out / 'runtime.log').open('w') as log:
            process = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            record['owned_pid'] = process.pid
            deadline = time.monotonic() + 60
            record['observation_limit_seconds'] = 60
            while process.poll() is None and time.monotonic() < deadline:
                raw = subprocess.check_output(['ps', '-axo', 'pid,ppid,pgid,stat,%cpu,rss,time,comm'], text=True)
                rows = [line.split(None, 7) for line in raw.splitlines()[1:]]
                descendants = {process.pid}
                for _ in range(len(rows)):
                    expanded = descendants | {int(r[0]) for r in rows if len(r) == 8 and int(r[1]) in descendants}
                    if expanded == descendants:
                        break
                    descendants = expanded
                owned = [r for r in rows if len(r) == 8 and int(r[0]) in descendants]
                owned_pids.update(descendants)
                for pid in descendants - set(owned_identity):
                    identity = subprocess.run(['ps', '-p', str(pid), '-o', 'lstart=,comm='], capture_output=True, text=True)
                    if identity.stdout.strip():
                        owned_identity[pid] = identity.stdout.strip()
                snapshot = {'seconds': time.monotonic() - started, 'processes': owned}
                database = models / 'semantic-files.sqlite'
                if database.is_file():
                    try:
                        with sqlite3.connect('file:' + str(database) + '?mode=ro', uri=True, timeout=0.1) as db:
                            db.row_factory = sqlite3.Row
                            snapshot['jobs'] = [dict(row) for row in db.execute('SELECT * FROM jobs')]
                            snapshot['chunks'] = [dict(row) for row in db.execute(
                                'SELECT path,modality,segment_kind,page,time,end_time,length(vector) AS vector_bytes FROM chunks')]
                            snapshot['media_segments'] = [dict(row) for row in db.execute(
                                'SELECT path,ordinal,kind,time,end_time,length(vector) AS vector_bytes FROM media_segments')]
                    except sqlite3.Error as error:
                        snapshot['db_snapshot_error'] = str(error)
                snapshots.append(clean(snapshot))
                write(out / 'process-and-persistence.json', snapshots)
                poll_end = min(time.monotonic() + 1, deadline)
                while process.poll() is None and time.monotonic() < poll_end:
                    if not sampled:
                        decision = sample_gate(read_events(out / 'native-stages.jsonl'),
                            read_events(out / 'trace.jsonl'), owned, owned_identity, helper,
                            record['launch_monotonic'], time.monotonic(), deadline, args.stage_seconds)
                        if decision is not None:
                            sampled = True  # Never retry, including a failed gate or tool capture.
                            if 'skipped' not in decision:
                                try:
                                    capture_stack(out, decision, owned_identity[decision['pid']])
                                except Exception as error:
                                    decision['error'] = str(error)
                            write(out / 'sample-command.json', clean(decision))
                    try:
                        process.wait(timeout=min(0.1, max(0.001, poll_end - time.monotonic())))
                    except subprocess.TimeoutExpired:
                        pass
            if not sampled:
                write(out / 'sample-command.json', {'skipped': 'no model-begin observed before process exit/deadline',
                                                   'tool_limit_seconds': 12, 'attempts': 0})
            code = process.poll()
            if code is None:
                record['parent_deadline_exceeded'] = True
                code = 124
    except Exception as error:
        record['error'] = str(error)
    finally:
        if process is not None and process.poll() is None:
            # This exact process group belongs to this Popen. Never target by executable name.
            daemon = json.loads(subprocess.check_output(['multica', 'daemon', 'status', '--output', 'json'], text=True))
            assert daemon['pid'] != process.pid
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=10)
        # Helpers have their own groups. Normal service.clear joins them; forced exits need exact-PID cleanup.
        remaining = []
        for pid in owned_pids - ({process.pid} if process else set()):
            observation = subprocess.run(['ps', '-p', str(pid), '-o', 'ppid=,comm='], capture_output=True, text=True)
            if not observation.stdout.strip():
                continue
            # Refuse to signal an unrelated reused PID. All helper paths were explicitly supplied above.
            if not any(str(path) in observation.stdout for path in [app, helper]):
                remaining.append(pid)
                continue
            identity = subprocess.run(['ps', '-p', str(pid), '-o', 'lstart=,comm='], capture_output=True, text=True)
            if not owned_identity.get(pid) or owned_identity[pid] != identity.stdout.strip():
                remaining.append(pid)
                continue
            daemon = json.loads(subprocess.check_output(['multica', 'daemon', 'status', '--output', 'json'], text=True))
            assert daemon['pid'] != pid
            try:
                os.kill(pid, signal.SIGCONT)
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            remaining.append(pid)
        record['post_clear_pids_requiring_cleanup'] = sorted(remaining)
        shutil.rmtree(private)
        for path in out.iterdir():
            if path.suffix in ['.json', '.jsonl', '.log', '.txt']:
                content = path.read_text()
                for old, new in replacements:
                    content = content.replace(old, new)
                path.write_text(content)
        record.update(exit_code=code, wall_seconds=time.monotonic() - started,
                      private_root_removed=not private.exists())
        write(out / 'command.json', clean(record))
        print(json.dumps(clean(record)), flush=True)
    raise SystemExit(code)


if __name__ == '__main__':
    main()
