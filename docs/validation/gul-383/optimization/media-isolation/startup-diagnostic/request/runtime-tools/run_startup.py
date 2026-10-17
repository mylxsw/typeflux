#!/usr/bin/env python3
"""One real CPU text request, unchanged production budgets, at most 60 s of observation."""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time


def sha(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def write(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def identity(pid):
    return subprocess.run(['ps', '-p', str(pid), '-o', 'lstart=,comm='],
                          capture_output=True, text=True, check=True).stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache-checkout', type=Path, required=True)
    parser.add_argument('--model-assets', type=Path, required=True)
    args = parser.parse_args()
    total = time.monotonic()
    root = Path.cwd()
    source = Path(__file__).resolve().parent
    out = source / 'request'
    out.mkdir()  # Never overwrite an earlier attempt or silently run twice.
    cache = args.cache_checkout.resolve()
    assets = args.model_assets.resolve()
    binary = root / '.build/startup-diagnostic/MediaProbe'
    helper = root / '.build/media-isolation/TypefluxSemanticHelper-coverage'
    private = root / ('gul405-startup-private-' + str(os.getpid()))
    replacements = [(str(private), '<private>'), (str(cache), '<accepted-cache>'),
                    (str(assets), '<native-model-cache>'), (str(root), '<repo>')]

    def clean(value):
        text = json.dumps(value)
        for old, new in replacements:
            text = text.replace(old, new)
        return json.loads(text)

    def ps_rows():
        raw = subprocess.check_output(['ps', '-axo', 'pid,ppid,pgid,stat,%cpu,rss,time,comm'], text=True)
        return [row.split(None, 7) for row in raw.splitlines()[1:]]

    record = {'attempts': 1, 'observation_limit_seconds': 60, 'production_policy_unchanged': True}
    snapshots, samples, owned = [], [], {}
    process = None
    exit_code = 125
    try:
        built = json.loads((source / 'probe-binary.json').read_text())
        native = json.loads((source.parent / 'helper-build.json').read_text())
        assert sha(binary) == built['sha256']
        assert sha(source / 'media_probe.swift') == built['source_sha256']
        assert sha(helper) == native['binary_sha256']
        assert sha(root / 'Sources/TypefluxSemanticHelper/main.swift') == native['source_sha256']
        verified = {}
        for name in ['reused-objects.json', 'reused-modules-resources.json']:
            manifest = json.loads((source / name).read_text())
            assert all(sha(cache / path) == digest for path, digest in manifest.items()), name
            verified[name] = len(manifest)
        native_manifest = json.loads((source.parent / 'native-dependencies.json').read_text())
        assert all(sha(assets / path) == digest for path, digest in native_manifest.items())
        model = assets / 'embeddinggemma-2-Q8_0.gguf'
        expected = json.loads((source.parent.parent / 'real-path-short/runtime-fingerprints.json').read_text())
        assert sha(model) == expected[model.name]['sha256']
        write(out / 'preflight.json', dict(verified, helper_sha256=sha(helper),
            probe_sha256=sha(binary), model_sha256=sha(model), native_archive_sha256=sha(assets / 'lib/libllamacpp.a'),
            native_dependencies_checked=len(native_manifest)))
        private.mkdir(mode=0o700)
        cloned = private / model.name
        subprocess.run(['/bin/cp', '-c', str(model), str(cloned)], check=True)
        cloned.chmod(0o600)
        assert sha(cloned) == expected[model.name]['sha256']
        env = dict(os.environ)
        dev = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
        (out / 'trace.jsonl').touch()
        env.update(GUL405_TRACE=str(out / 'trace.jsonl'), GUL405_REPORT=str(out / 'report.json'),
                   GUL405_MODEL=str(cloned), GUL405_HELPER=str(helper),
                   LLVM_PROFILE_FILE=str(private / 'diagnostic-%p%c.profraw'),
                   DYLD_FRAMEWORK_PATH=str(dev / 'Platforms/MacOSX.platform/Developer/Library/Frameworks'),
                   DYLD_LIBRARY_PATH=str(dev / 'Platforms/MacOSX.platform/Developer/usr/lib'))
        runtime = out / 'runtime-tools'
        runtime.mkdir()
        for name in ['run_startup.py', 'media_probe.swift', 'probe-binary.json', 'build_probe.py']:
            shutil.copyfile(source / name, runtime / name)
        record['preparation_seconds'] = time.monotonic() - total
        started = time.monotonic()
        with (out / 'runtime.log').open('w') as log:
            process = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            record['probe_pid'] = process.pid
            sample_due = [8, 32]
            while process.poll() is None and time.monotonic() - started < 60:
                elapsed = time.monotonic() - started
                rows = ps_rows()
                descendants = {process.pid}
                while True:
                    expanded = descendants | {int(row[0]) for row in rows
                        if len(row) == 8 and int(row[1]) in descendants}
                    if expanded == descendants:
                        break
                    descendants = expanded
                active = [row for row in rows if len(row) == 8 and int(row[0]) in descendants]
                for row in active:
                    pid = int(row[0])
                    if pid not in owned:
                        try:
                            owned[pid] = identity(pid)
                        except subprocess.CalledProcessError:
                            pass  # Child exited before identity collection; never signal it later.
                snapshots.append({'seconds': elapsed, 'processes': active})
                helper_rows = [row for row in active if row[7] == str(helper)]
                if sample_due and elapsed >= sample_due[0] and helper_rows:
                    point = sample_due.pop(0)
                    target = int(helper_rows[0][0])
                    path = out / ('helper-sample-' + str(point) + '.txt')
                    sample_start = time.monotonic()
                    try:
                        sampled = subprocess.run(['sample', str(target), '1', '5', '-file', str(path)],
                            capture_output=True, text=True, timeout=min(3, max(0.1, 59 - elapsed)))
                        samples.append({'at_seconds': elapsed, 'pid': target, 'exit_code': sampled.returncode,
                            'output': sampled.stdout + sampled.stderr,
                            'wall_seconds': time.monotonic() - sample_start})
                    except subprocess.TimeoutExpired:
                        samples.append({'at_seconds': elapsed, 'pid': target, 'timeout_seconds': 3,
                            'wall_seconds': time.monotonic() - sample_start})
                try:
                    process.wait(timeout=min(0.25, max(0.001, 60 - (time.monotonic() - started))))
                except subprocess.TimeoutExpired:
                    pass
            record['observation_seconds'] = time.monotonic() - started
            record['deadline_exceeded'] = process.poll() is None
            exit_code = process.poll() if process.poll() is not None else 124
    except Exception as error:
        record['error'] = str(error)
    finally:
        # Only the descendant PIDs observed in this invocation, still matching their start identity.
        cleanup = []
        live = []
        for pid, expected_identity in owned.items():
            try:
                if identity(pid) == expected_identity:
                    live.append(pid)
            except subprocess.CalledProcessError:
                pass
        if live:
            daemon = json.loads(subprocess.check_output(['multica', 'daemon', 'status', '--output', 'json']))['pid']
            for pid in live:
                assert pid != daemon
                try:
                    if identity(pid) != owned[pid]:
                        continue
                    os.kill(pid, signal.SIGKILL)
                    cleanup.append(pid)
                except (ProcessLookupError, subprocess.CalledProcessError):
                    pass
        if process is not None:
            process.wait(timeout=5)
        record.update(exit_code=exit_code, forced_cleanup_pids=cleanup,
                      wall_seconds=time.monotonic() - total, owned_identity=owned)
        # No new coverage claim: retain materialized profiles as raw diagnostic artifacts only.
        if private.exists():
            profiles = out / 'raw-profiles'
            profiles.mkdir()
            for path in private.glob('*.profraw'):
                with gzip.open(profiles / (path.name + '.gz'), 'wb') as target:
                    target.write(path.read_bytes())
            shutil.rmtree(private)
        record['private_root_removed'] = not private.exists()
        write(out / 'command.json', clean(record))
        write(out / 'processes.json', clean(snapshots))
        write(out / 'samples.json', clean(samples))
        for path in out.glob('helper-sample-*.txt'):
            path.write_text(clean(path.read_text()))
        print(json.dumps(clean(record)))
    raise SystemExit(exit_code)


if __name__ == '__main__':
    main()
