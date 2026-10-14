"""Exercise coverage orchestration with fake Swift/LLVM tools, never the real suite."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class FocusedCoverageTests(unittest.TestCase):
    def invoke(self, args, fail_tests=False):
        with tempfile.TemporaryDirectory(prefix="typeflux coverage ") as temporary:
            directory = Path(temporary)
            binary = directory / "bin/TypefluxPackageTests.xctest/Contents/MacOS/TypefluxPackageTests"
            binary.parent.mkdir(parents=True)
            binary.touch()
            profile = directory / "bin/codecov/default.profdata"
            profile.parent.mkdir()
            profile.touch()
            log = directory / "calls.jsonl"
            swift = directory / "swift"
            swift.write_text(
                '#!/usr/bin/env python3\n'
                'import json, os, sys\n'
                'from pathlib import Path\n'
                'with Path(os.environ["COVERAGE_TEST_LOG"]).open("a") as log:\n'
                '    log.write(json.dumps(sys.argv[1:]) + "\\n")\n'
                'if sys.argv[-1] == "list":\n'
                '    print("TypefluxTests.LLMRouterTests/testRoutes")\n'
                '    print("TypefluxTests.ProcessCommandRunnerTests/testExit")\n'
                'elif sys.argv[1:] == ["build", "--show-bin-path"]:\n'
                '    print(os.environ["COVERAGE_TEST_BIN"])\n'
                'else:\n'
                '    sys.exit(int(os.environ["COVERAGE_TEST_FAIL"]))\n'
            )
            swift.chmod(0o755)
            llvm = directory / "xcrun"
            llvm.write_text('#!/bin/sh\nexit 0\n')
            llvm.chmod(0o755)
            environment = dict(os.environ, PATH=f"{directory}{os.pathsep}{os.environ['PATH']}",
                               COVERAGE_TEST_LOG=str(log), COVERAGE_TEST_BIN=str(directory / "bin"),
                               COVERAGE_TEST_FAIL="7" if fail_tests else "0")
            result = subprocess.run([str(ROOT / "scripts/coverage.sh"), *args], cwd=directory,
                                    env=environment, text=True, capture_output=True)
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return result, calls

    def test_missing_scope_and_unannounced_full_never_invoke_swift(self):
        for args in ([], ["--full"]):
            result, calls = self.invoke(args)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(calls, [])

    def test_focused_coverage_builds_and_executes_only_its_scope(self):
        result, calls = self.invoke(["--suite", "LLMRouterTests"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[0], ["test", "--enable-code-coverage", "list"])
        self.assertIn("--no-parallel", calls[1])
        self.assertIn("--enable-code-coverage", calls[1])
        self.assertIn("LLMRouterTests", calls[1][-1])
        self.assertNotIn("ProcessCommandRunnerTests", calls[1][-1])
        self.assertEqual(calls[2], ["build", "--show-bin-path"])

    def test_test_failure_is_not_masked_by_report_generation(self):
        result, calls = self.invoke(["--suite", "LLMRouterTests"], fail_tests=True)
        self.assertEqual(result.returncode, 7)
        self.assertEqual(len(calls), 2)


if __name__ == "__main__":
    unittest.main()
