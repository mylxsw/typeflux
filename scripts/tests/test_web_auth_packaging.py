"""Exercise login channel packaging without launching the application."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class WebAuthPackagingTests(unittest.TestCase):
    def package(self, channel):
        with tempfile.TemporaryDirectory() as directory:
            plist = Path(directory) / 'Info.plist'
            shutil.copyfile(ROOT / 'app/Info.plist', plist)
            environment = {k: v for k, v in os.environ.items() if not k.startswith('TYPEFLUX_WEB_AUTH_')}
            if channel is not None:
                environment['TYPEFLUX_WEB_AUTH_CHANNEL'] = channel
            result = subprocess.run(['bash', str(ROOT / 'scripts/configure_dev_web_auth.sh'), str(plist)],
                                    env=environment, capture_output=True, text=True)
            return result, plistlib.loads(plist.read_bytes())

    def test_default_development_keeps_separate_callback(self):
        result, info = self.package(None)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(info['TYPEFLUX_WEB_AUTH_CHANNEL'], 'development')
        self.assertIn('ai.gulu.app.typeflux.dev', [s for t in info['CFBundleURLTypes'] for s in t['CFBundleURLSchemes']])

    def test_production_uses_production_callback(self):
        result, info = self.package('production')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(info['TYPEFLUX_WEB_AUTH_CHANNEL'], 'production')
        schemes = [s for t in info['CFBundleURLTypes'] for s in t['CFBundleURLSchemes']]
        self.assertIn('ai.gulu.app.typeflux', schemes)
        self.assertNotIn('ai.gulu.app.typeflux.dev', schemes)

    def test_invalid_channel_fails_before_mutation(self):
        result, info = self.package('prod')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(info, plistlib.loads((ROOT / 'app/Info.plist').read_bytes()))

    def test_prod_target_overrides_inherited_local_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            shutil.copyfile(ROOT / 'Makefile', workspace / 'Makefile')
            launcher = workspace / 'scripts/run_dev_attached.sh'
            launcher.parent.mkdir()
            launcher.write_text('#!/usr/bin/env python3\nimport os, json\nprint(json.dumps(dict(os.environ)))\n')
            launcher.chmod(0o755)
            environment = dict(os.environ, TYPEFLUX_WEB_AUTH_CHANNEL='development',
                               TYPEFLUX_WEB_AUTH_ORIGIN='http://localhost:5174',
                               TYPEFLUX_WEB_AUTH_API_ORIGIN='http://localhost:5174',
                               TYPEFLUX_API_URL='http://localhost:8080', TYPEFLUX_API_URLS='http://localhost:8080')
            output = subprocess.check_output(['make', '--no-print-directory', 'prod'], cwd=workspace,
                                             env=environment, text=True)
            actual = json.loads(output.splitlines()[-1])
            self.assertEqual(actual['TYPEFLUX_WEB_AUTH_CHANNEL'], 'production')
            self.assertEqual(actual['TYPEFLUX_WEB_AUTH_ORIGIN'], 'https://typeflux.app')
            self.assertEqual(actual['TYPEFLUX_WEB_AUTH_API_ORIGIN'], 'https://api.typeflux.app')
            self.assertEqual(actual['TYPEFLUX_API_URL'], 'https://api.typeflux.app')
            self.assertEqual(actual['TYPEFLUX_API_URLS'], 'https://api.typeflux.app,https://typeflux-api.aicode.cc')
