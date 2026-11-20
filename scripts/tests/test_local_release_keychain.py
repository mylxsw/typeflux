"""Keep local packaging credentials scoped to one build, even on failure."""

import base64
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import with_release_keychain as signing


class LocalReleaseKeychainTests(unittest.TestCase):
    def exercise(self, *, fail_import=False, notarize=True):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'fixture.env'
            source.write_text(
                '# fixture\nexport CODESIGN_IDENTITY="Developer ID Application: Fixture"\n'
                f'APPLE_CERTIFICATE_BASE64={base64.b64encode(b"fixture").decode()}\n'
                'APPLE_CERTIFICATE_PASSWORD=not-a-secret\nNOTARYTOOL_APPLE_ID=fixture\n'
                'APPLE_TEAM_ID=test-team\nNOTARYTOOL_PASSWORD=not-a-secret\n'
            )
            command = ['./release_notarize.sh' if notarize else './build_release.sh']
            keychains, configured, built = [], [], []

            def run(args, **kwargs):
                failure = 0
                if args == command:
                    environment = kwargs['env']
                    self.assertEqual(environment['TYPEFLUX_CODESIGN_KEYCHAIN'], str(keychains[0]))
                    self.assertEqual(environment['TYPEFLUX_CODESIGN_IDENTITY'], 'Developer ID Application: Fixture')
                    self.assertNotIn('APPLE_CERTIFICATE_PASSWORD', environment)
                    if notarize:
                        self.assertEqual(environment['TYPEFLUX_NOTARY_KEYCHAIN'], str(keychains[0]))
                    self.assertFalse((keychains[0].parent / 'identity.p12').exists())
                    built.append(True)
                else:
                    configured.append(args[1])
                    if args[1] == 'create-keychain':
                        keychains.append(args[-1])
                        keychains[0].touch()
                    elif args[1] == 'import':
                        self.assertEqual(Path(args[2]).read_bytes(), b'fixture')
                        self.assertIn('/usr/bin/codesign', args)
                        failure = int(fail_import)
                    elif args[1] == 'delete-keychain':
                        self.assertEqual(args[-1], keychains[0])
                        keychains[0].unlink()
                return subprocess.CompletedProcess(args, failure)

            with patch.dict(os.environ, {}, clear=True), patch.object(signing.subprocess, 'run', side_effect=run):
                if fail_import:
                    with self.assertRaisesRegex(RuntimeError, r'^Import signing identity failed \(exit 1\)$'):
                        signing.package(source, command)
                else:
                    self.assertEqual(signing.package(source, command), 0)
            self.assertEqual(configured[-1], 'delete-keychain')
            self.assertEqual('notarytool' in configured, notarize and not fail_import)
            self.assertEqual(bool(built), not fail_import)
            self.assertFalse(keychains[0].parent.exists())

    def test_release_uses_disposable_signing_and_notary_credentials(self):
        self.exercise()

    def test_standalone_signing_skips_notary_setup(self):
        self.exercise(notarize=False)

    def test_denied_import_stops_and_cleans_up_without_exposing_passwords(self):
        self.exercise(fail_import=True)
