"""Exercise release signing order without building, models or real signing identities."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ReleasePackagingTests(unittest.TestCase):
    def run_release(self, fail_tokenizer=False):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scripts = root / 'scripts'
            scripts.mkdir()
            for name in ['build_release.sh', 'copy_inference_helper.sh', 'copy_media_helper.sh',
                         'copy_resource_bundles.sh']:
                shutil.copyfile(ROOT / 'scripts' / name, scripts / name)
            app = root / 'app'
            app.mkdir()
            for name in ['Info.plist', 'Typeflux.icns', 'TypefluxRuntime.entitlements']:
                shutil.copyfile(ROOT / 'app' / name, app / name)
            products = root / 'products'
            products.mkdir()
            for name in ['Typeflux', 'TypefluxInferenceHelper', 'TypefluxMediaHelper']:
                binary = products / name
                binary.write_text('#!/bin/sh\nexit 0\n')
                binary.chmod(0o755)
            for name in ['swift-transformers_Hub.bundle', 'Typeflux_Typeflux.bundle', 'TypefluxChat_TypefluxChat.bundle']:
                bundle = products / name
                bundle.mkdir()
                (bundle / 'resource.json').write_text('{}')
            (scripts / 'install_semantic_helper.sh').write_text('#!/bin/sh\nmkdir -p "$1/SemanticSearch"\n')
            (scripts / 'audit_macho_minos.sh').write_text('#!/bin/sh\nexit 0\n')
            (scripts / 'audit_macho_minos.sh').chmod(0o755)
            binaries = root / 'tools'
            binaries.mkdir()
            tools = {
                'swift': '#!/bin/sh\ncase "$*" in *--show-bin-path*) echo "$FIXTURE_PRODUCTS";; esac\n',
                'lipo': '#!/bin/sh\necho arm64\n',
                'ditto': '#!/bin/sh\nexit 0\n',
                'codesign': '''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
target = args[-1]
log = pathlib.Path(os.environ['FIXTURE_SIGNATURES'])
rows = json.loads(log.read_text()) if log.exists() else []
rows.append(args)
log.write_text(json.dumps(rows))
if target.endswith('swift-transformers_Hub.bundle') and os.environ['FIXTURE_FAIL'] == '1':
    sys.exit(23)
if target.endswith('/MacOS/Typeflux') or target.endswith('.app'):
    if not any(row[-1].endswith('swift-transformers_Hub.bundle') for row in rows[:-1]):
        sys.exit(24)
''',
            }
            for name, text in tools.items():
                path = binaries / name
                path.write_text(text)
                path.chmod(0o755)
            env = {key: value for key, value in os.environ.items() if not key.startswith('TYPEFLUX_')}
            env.update(PATH=str(binaries) + os.pathsep + env['PATH'],
                       TYPEFLUX_RELEASE_VARIANT='app-only', TYPEFLUX_CODESIGN_IDENTITY='fixture-identity',
                       FIXTURE_PRODUCTS=str(products), FIXTURE_SIGNATURES=str(root / 'signatures.json'),
                       FIXTURE_FAIL='1' if fail_tokenizer else '0')
            trace_env = root / 'trace-env'
            trace_env.write_text("PS4='+${BASH_SOURCE}:${LINENO}:'\n")
            env['BASH_ENV'] = str(trace_env)
            result = subprocess.run(['bash', '-x', str(scripts / 'build_release.sh')], env=env,
                                    capture_output=True, text=True, timeout=30)
            if os.environ.get('SHELL_COVERAGE_TRACE'):
                with open(os.environ['SHELL_COVERAGE_TRACE'], 'a') as trace:
                    trace.write(result.stderr)
            rows = json.loads((root / 'signatures.json').read_text())
            return result, rows

    def test_tokenizer_is_signed_before_workers_and_host_without_host_entitlements(self):
        result, rows = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        tokenizer = next(i for i, row in enumerate(rows) if row[-1].endswith('swift-transformers_Hub.bundle'))
        host = next(i for i, row in enumerate(rows) if row[-1].endswith('/MacOS/Typeflux'))
        worker = next(i for i, row in enumerate(rows) if row[-1].endswith('/TypefluxInferenceHelper'))
        self.assertLess(tokenizer, worker)
        self.assertLess(worker, host)
        self.assertIn('--timestamp', rows[tokenizer])
        self.assertIn('runtime', rows[tokenizer])
        self.assertNotIn('--entitlements', rows[tokenizer])
        self.assertTrue(any('--verify' in row and '--strict' in row for row in rows))

    def test_tokenizer_signature_failure_stops_before_signing_host(self):
        result, rows = self.run_release(fail_tokenizer=True)
        self.assertEqual(result.returncode, 23)
        self.assertEqual(len(rows), 1)
        self.assertTrue(rows[0][-1].endswith('swift-transformers_Hub.bundle'))


if __name__ == '__main__':
    unittest.main()
