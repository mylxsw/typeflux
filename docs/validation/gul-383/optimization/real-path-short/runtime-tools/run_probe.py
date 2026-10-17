#!/usr/bin/env python3
"""Run the opt-in real-path tool with existing pinned local weights and synthetic fixtures only."""
import argparse, hashlib, json, os, platform, shutil, signal, subprocess, time
from pathlib import Path


def sha(p):
    with p.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache-checkout', type=Path, required=True)
    parser.add_argument('--model-assets', type=Path, required=True)
    parser.add_argument('--resource-seconds', type=int, default=0)
    parser.add_argument('--native-probe', type=Path)
    parser.add_argument('--documents-only', action='store_true')
    args = parser.parse_args()
    root = Path.cwd()
    out = Path(__file__).resolve().parent
    scratch = root / '.build/real-path-short'
    private = root / ('gul405-private-runtime-' + str(os.getpid()))
    private.mkdir(mode=0o700)
    corpus = private / 'corpus'; corpus.mkdir(mode=0o700)
    models = private / 'models'; models.mkdir(mode=0o700)
    cache = args.cache_checkout.resolve()
    assets = args.model_assets.resolve()
    binary = scratch / 'RealPathProbe'
    app = cache / '.build/video-frames/arm64-apple-macosx/debug/Typeflux'
    helper = assets / 'TypefluxSemanticHelper'
    samples = {
        'body.docx': 'word-body-slice/synthetic-body.docx',
        'scan.pdf': 'content-ocr-slice/synthetic-invoice.pdf',
        'screen.png': 'image-ocr-slice/synthetic-error.png',
        'scene.mov': 'video-frames/short-scene.mov',
    }
    if args.documents_only:
        samples = {name: suffix for name, suffix in samples.items() if name in ['body.docx', 'scan.pdf']}
    fingerprints = {}
    started = time.monotonic()
    process = None
    native = None
    native_log = None
    try:
        for name, digest in [('embeddinggemma-2-Q8_0.gguf', '2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135'),
                ('mmproj-embeddinggemma-2-Q8_0.gguf', 'c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f')]:
            source = assets / name
            assert sha(source) == digest, 'Pinned model mismatch'
            subprocess.run(['/bin/cp', '-c', str(source), str(models / name)], check=True)
            (models / name).chmod(0o600)
            fingerprints[name] = {'sha256': digest, 'bytes': source.stat().st_size}
        for name, suffix in samples.items():
            source = root / 'docs/validation/gul-383/optimization' / suffix
            shutil.copyfile(source, corpus / name)
            fingerprints[name] = {'sha256': sha(source), 'source': str(source.relative_to(root))}
        fingerprints.update({name: {'sha256': sha(path), 'bytes': path.stat().st_size}
            for name, path in [('probe', binary), ('file-helper', app), ('model-helper', helper)]})
        (out / 'runtime-fingerprints.json').write_text(json.dumps(fingerprints, indent=2) + '\n')
        env = dict(os.environ)
        dev = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
        env.update(GUL405_REPORT=str(out / 'real-path.json'), GUL405_PRIVATE_ROOT=str(private),
            GUL405_FILE_HELPER=str(app), GUL405_MODEL_HELPER=str(helper),
            LLVM_PROFILE_FILE=str(scratch / 'probe-%p.profraw'),
            DYLD_FRAMEWORK_PATH=str(dev / 'Platforms/MacOSX.platform/Developer/Library/Frameworks'),
            DYLD_LIBRARY_PATH=str(dev / 'Platforms/MacOSX.platform/Developer/usr/lib'))
        if args.documents_only:
            env['GUL405_DOCUMENTS_ONLY'] = '1'
        env['TYPEFLUX_SEMANTIC_REFERENCE_BUDGET'] = '1'
        if args.resource_seconds:
            env['GUL405_RESOURCE_SECONDS'] = str(args.resource_seconds)
        with (out / 'runtime.log').open('w') as log:
            process = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                deadline = time.monotonic() + 600 + args.resource_seconds
                while True:
                    try:
                        code = process.wait(timeout=1)
                        break
                    except subprocess.TimeoutExpired:
                        if time.monotonic() >= deadline:
                            raise
                        reportpath = out / 'real-path.json'
                        if args.native_probe and native is None and reportpath.exists():
                            current = json.loads(reportpath.read_text())
                            if current.get('resource_started_uptime'):
                                native_log = (out / 'native-response.log').open('w')
                                native = subprocess.Popen([str(args.native_probe.resolve()), str(out / 'native-response.json'),
                                    str(args.resource_seconds)], stdout=native_log, stderr=subprocess.STDOUT, start_new_session=True)
                                fingerprints['native-probe'] = {'sha256': sha(args.native_probe), 'bytes': args.native_probe.stat().st_size}
                                (out / 'runtime-fingerprints.json').write_text(json.dumps(fingerprints, indent=2) + '\n')
                if native:
                    native_code = native.wait(timeout=args.resource_seconds + 30)
                    if native_code != 0:
                        code = native_code
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                try: process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL); process.wait(timeout=10)
                code = 124
        # Retain complete command wall time, including checksums, cloning and cleanup.
    finally:
        if process and process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM); process.wait(timeout=10)
        if native and native.poll() is None:
            os.killpg(native.pid, signal.SIGTERM); native.wait(timeout=10)
        if native_log:
            native_log.close()
        shutil.rmtree(private)
        logpath = out / 'runtime.log'
        if logpath.exists():
            logpath.write_text(logpath.read_text().replace(str(cache), '<accepted-cache>').replace(str(assets), '<model-cache>').replace(str(root), '<repo>'))
    record = {'command': ['RealPathProbe'], 'wall_seconds': time.monotonic() - started, 'exit_code': code,
        'hardware': platform.machine(), 'macos': platform.mac_ver()[0], 'private_root_removed': not private.exists(),
        'configuration': 'Debug, reused coverage-instrumented PR646 objects; no SwiftPM or product rebuild',
        'cached_weights_only': True}
    (out / 'runtime-command.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record)); raise SystemExit(code)


if __name__ == '__main__':
    main()
