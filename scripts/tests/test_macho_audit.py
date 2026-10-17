"""The optional semantic executable has an independent, narrowly scoped platform floor."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SEMANTIC = 'Contents/Resources/LocalRuntimes/SemanticSearch/TypefluxSemanticHelper'


class MachOAuditTests(unittest.TestCase):
    def audit(self, helper_path=SEMANTIC, helper_minos='14.0', helper_arch='arm64',
              host_minos='13.0', required='arm64'):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / 'Typeflux.app'
            for name, value in [('Contents/MacOS/Typeflux', host_minos + ' ' + ('arm64 x86_64' if required == 'universal' else 'arm64')),
                                (helper_path, helper_minos + ' ' + helper_arch)]:
                path = app / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(value)
            tools = root / 'tools'
            tools.mkdir()
            for name, text in {
                'file': '#!/bin/sh\necho Mach-O\n',
                'vtool': '#!/bin/sh\nread minos arch < "$2"\necho "minos $minos"\n',
                'lipo': '#!/bin/sh\nread minos arch < "$2"\necho "$arch"\n',
            }.items():
                path = tools / name
                path.write_text(text)
                path.chmod(0o755)
            trace_env = root / 'trace-env'
            trace_env.write_text("PS4='+${BASH_SOURCE##*/}:${LINENO}:'\n")
            result = subprocess.run(['bash', '-x', str(ROOT / 'scripts/audit_macho_minos.sh'), str(app), '13.4', required],
                                  env=dict(os.environ, BASH_ENV=str(trace_env), PATH=str(tools) + os.pathsep + os.environ['PATH']),
                                  capture_output=True, text=True, timeout=20)
            if os.environ.get('SHELL_COVERAGE_TRACE'):
                with open(os.environ['SHELL_COVERAGE_TRACE'], 'a') as trace:
                    trace.write(result.stderr)
            return result

    def test_optional_arm64_helper_passes_without_raising_host_floor(self):
        for required in ['arm64', 'universal', 'native']:
            with self.subTest(required=required):
                result = self.audit(required=required)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_host_and_unrelated_nested_code_keep_original_floor(self):
        for kwargs in [{'host_minos': '14.0'}, {'helper_path': 'Contents/Helpers/OtherHelper'}]:
            with self.subTest(kwargs=kwargs):
                self.assertNotEqual(self.audit(**kwargs).returncode, 0)

    def test_semantic_helper_still_rejects_higher_floor_and_wrong_architecture(self):
        for kwargs in [{'helper_minos': '15.0'}, {'helper_arch': 'x86_64'}, {'required': 'x86_64'}]:
            with self.subTest(kwargs=kwargs):
                self.assertNotEqual(self.audit(**kwargs).returncode, 0)


if __name__ == '__main__':
    unittest.main()
