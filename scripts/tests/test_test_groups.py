"""Verify complete grouping and safe SwiftPM command orchestration."""

from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("test_groups", ROOT / "scripts/test_groups.py")
GROUPING = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GROUPING)


class TestGroupingTests(unittest.TestCase):
    def sources(self, files):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for name, source in files.items():
                (directory / name).write_text(source, encoding="utf-8")
            return GROUPING.source_groups(directory)

    def test_resource_groups_and_mixed_files_are_conservative(self):
        groups = self.sources({
            "Logic.swift": "struct LogicTests { }\nfinal class ParserTests: XCTestCase { }",
            "Disk.swift": "import Foundation\nstruct DiskTests { let manager = FileManager.default }",
            "Process.swift": "final class ProcessTests: XCTestCase { let process = Process() }",
            "Network.swift": "struct NetworkTests { let session = URLSession.shared }",
            "Timer.swift": "struct TimerTests { func run() async { try? await Task.sleep(for: .seconds(1)) } }",
            "Visual.swift": "@MainActor\nstruct VisualTests { }\nstruct MixedTests { }",
            "SearchBenchmarkTests.swift": "struct SearchBenchmarkTests { let manager = FileManager.default }",
        })
        self.assertEqual(groups, {
            "LogicTests": "unit", "ParserTests": "unit", "DiskTests": "integration",
            "ProcessTests": "integration", "NetworkTests": "integration", "TimerTests": "integration",
            "VisualTests": "ui", "MixedTests": "ui", "SearchBenchmarkTests": "benchmark",
        })

    def test_shared_state_and_storage_markers_are_classified(self):
        for marker in (".exclusiveUIState", "AppLocalization.shared", 'L("key")', "NSApp.windows",
                       "NSApplication.shared", "NSWindow()", "NSPanel()", "NSPasteboard.general"):
            with self.subTest(marker=marker):
                self.assertEqual(self.sources({"Example.swift": f"struct ExampleTests {{ {marker} }}"}),
                                 {"ExampleTests": "ui"})
        for marker in ("SQLiteDatabase()", "KeychainTokenStore.loadToken()", "SecItemCopyMatching()",
                       "Data(contentsOf: url)", "Thread.sleep(forTimeInterval: 1)", "usleep(1000)"):
            with self.subTest(marker=marker):
                self.assertEqual(self.sources({"Example.swift": f"struct ExampleTests {{ {marker} }}"}),
                                 {"ExampleTests": "integration"})

    def test_extensions_upgrade_the_suite_regardless_of_file_order(self):
        for declaration, extension in (("A.swift", "Z.swift"), ("Z.swift", "A.swift")):
            with self.subTest(declaration=declaration):
                groups = self.sources({declaration: "struct ExampleTests {}",
                                       extension: "extension ExampleTests { let label = L(\"key\") }"})
                self.assertEqual(groups["ExampleTests"], "ui")

    def test_discovery_is_disjoint_and_complete_for_both_test_frameworks(self):
        identifiers = ["TypefluxTests.LogicTests/testParse", "TypefluxTests/DiskTests/write()",
                       "TypefluxTests.VisualTests/click()", "TypefluxTests.OuterTests.Nested/testValue()",
                       "TypefluxTests.SearchBenchmarkTests/searching()"]
        sources = {"LogicTests": "unit", "DiskTests": "integration", "VisualTests": "ui",
                   "OuterTests": "ui", "SearchBenchmarkTests": "benchmark"}
        result = GROUPING.partition_tests("Build complete!\n" + "\n".join(identifiers + identifiers), sources)
        partition = [test for suites in result.values() for tests in suites.values() for test in tests]
        self.assertEqual(set(partition), set(identifiers))
        self.assertEqual(len(partition), len(identifiers))
        self.assertEqual(result["ui"]["OuterTests"], [identifiers[3]])

    def test_unknown_malformed_and_empty_discovery_fail(self):
        for output in ("TypefluxTests.UnknownTests/testValue", "TypefluxTests.Malformed",
                       "TypefluxTests/Bad-ID/testValue", "OtherTests.KnownTests/testValue",
                       "Build failed before discovery"):
            with self.subTest(output=output), self.assertRaises(ValueError):
                GROUPING.partition_tests(output, {"KnownTests": "unit"})

    def test_filter_matches_suite_boundaries_and_nested_tests(self):
        pattern = GROUPING.suite_filter({"ExampleTests", "OtherTests"})
        for identifier in ("TypefluxTests.ExampleTests/testValue", "TypefluxTests/OtherTests/run()",
                           "TypefluxTests.ExampleTests.Nested/run()"):
            self.assertRegex(identifier, pattern)
        for identifier in ("TypefluxTests.ExampleTestsExtra/testValue", "DifferentTests.ExampleTests/testValue",
                           "TypefluxTests.NotExampleTests/testValue"):
            self.assertIsNone(re.search(pattern, identifier))
        with self.assertRaises(ValueError):
            GROUPING.suite_filter(set())

    def test_repository_sources_assign_known_multi_suite_and_extension_files(self):
        sources = GROUPING.source_groups(ROOT / "Tests/TypefluxTests")
        self.assertEqual(sources["AskFileIndexStateTests"], "integration")
        self.assertEqual(sources["AskFileIndexServiceTests"], "integration")
        self.assertEqual(sources["AskQuickResultsInteractionTests"], "ui")
        self.assertEqual(sources["AskFileIndexBenchmarkTests"], "benchmark")
        self.assertEqual(sources["LLMRouterTests"], "unit")


class TestGroupCommandTests(unittest.TestCase):
    def invoke(self, args, test_returncode=0, discovery=None, failure=None):
        if discovery is None:
            discovery = ("TypefluxTests.LogicTests/testValue\nTypefluxTests.DiskTests/testRead\n"
                         "TypefluxTests.VisualTests/render()\nTypefluxTests.SearchBenchmarkTests/search()")
        stdout, stderr = io.StringIO(), io.StringIO()
        responses = [subprocess.CompletedProcess([], 0, stdout=discovery),
                     subprocess.CompletedProcess([], test_returncode)]
        with patch.object(GROUPING, "source_groups", return_value={
            "LogicTests": "unit", "DiskTests": "integration", "VisualTests": "ui",
            "SearchBenchmarkTests": "benchmark",
        }), patch.object(GROUPING.subprocess, "run", side_effect=failure or responses) as run, \
                redirect_stdout(stdout), redirect_stderr(stderr):
            result = GROUPING.main(args)
        return result, run.call_args_list, stdout.getvalue(), stderr.getvalue()

    def test_group_builds_once_then_runs_an_anchored_filter_without_parallel_workers(self):
        result, calls, stdout, _ = self.invoke(["unit", "--jobs", "2"])
        self.assertEqual(result, 0)
        self.assertEqual(calls[0].args[0], ["swift", "test", "--jobs", "2", "list"])
        command = calls[1].args[0]
        self.assertEqual(command[:5], ["swift", "test", "--skip-build", "--no-parallel", "--filter"])
        self.assertRegex("TypefluxTests.LogicTests/testValue", command[5])
        self.assertIsNone(re.search(command[5], "TypefluxTests.VisualTests/render()"))
        self.assertEqual(calls[1].kwargs["cwd"], ROOT)
        self.assertIn("Test execution (unit):", stdout)

    def test_all_remains_unfiltered_and_does_not_enable_benchmarks(self):
        with patch.dict(os.environ, {}, clear=True):
            result, calls, _, _ = self.invoke([])
        self.assertEqual(result, 0)
        self.assertEqual(calls[1].args[0], ["swift", "test", "--skip-build", "--no-parallel"])
        self.assertNotIn("TYPEFLUX_SEARCH_BENCH", calls[1].kwargs["env"])

    def test_benchmark_enables_only_the_child_environment(self):
        with patch.dict(os.environ, {"TYPEFLUX_SEARCH_BENCH": "0", "EXAMPLE": "preserved"}, clear=True):
            result, calls, _, _ = self.invoke(["benchmark", "--skip-build"])
            self.assertEqual(os.environ["TYPEFLUX_SEARCH_BENCH"], "0")
        self.assertEqual(result, 0)
        self.assertIn("--skip-build", calls[0].args[0])
        self.assertEqual(calls[1].kwargs["env"]["TYPEFLUX_SEARCH_BENCH"], "1")
        self.assertEqual(calls[1].kwargs["env"]["EXAMPLE"], "preserved")

    def test_list_audits_without_running_tests(self):
        result, calls, stdout, _ = self.invoke(["ui", "--list"])
        self.assertEqual(result, 0)
        self.assertEqual(len(calls), 1)
        self.assertIn("ui: 1 suites, 1 discovered tests", stdout)
        self.assertTrue(stdout.endswith("VisualTests\n"))

    def test_selection_errors_and_discovery_failures_never_run_tests(self):
        for discovery in ("TypefluxTests.UnknownTests/testValue", "", "TypefluxTests.DiskTests/testRead"):
            with self.subTest(discovery=discovery):
                result, calls, _, stderr = self.invoke(["unit"], discovery=discovery)
                self.assertEqual(result, 1)
                self.assertEqual(len(calls), 1)
                self.assertIn("Error:", stderr)
        for error, status in ((FileNotFoundError("swift"), 1),
                              (subprocess.CalledProcessError(7, ["swift"]), 7),
                              (subprocess.CalledProcessError(-15, ["swift"]), 143)):
            with self.subTest(error=error):
                result, calls, _, _ = self.invoke(["unit"], failure=error)
                self.assertEqual(result, status)
                self.assertEqual(len(calls), 1)

    def test_failed_tests_and_signals_propagate(self):
        for status, expected in ((1, 1), (8, 8), (-15, 143)):
            with self.subTest(status=status):
                result, calls, _, _ = self.invoke(["integration"], test_returncode=status)
                self.assertEqual(result, expected)
                self.assertEqual(len(calls), 2)

    def test_invalid_jobs_and_group_fail_before_building(self):
        for arguments in (["unit", "--jobs", "0"], ["unit", "--jobs", "-2"],
                          ["unit", "--jobs", "bad"], ["unknown"]):
            with self.subTest(arguments=arguments), patch.object(GROUPING.subprocess, "run") as run, \
                    redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                GROUPING.main(arguments)
            run.assert_not_called()

    def test_cli_runs_from_another_directory_and_preserves_argument_boundaries(self):
        with tempfile.TemporaryDirectory(prefix="typeflux grouping ") as temporary:
            directory = Path(temporary)
            swift = directory / "swift"
            swift.write_text(
                '#!/usr/bin/env python3\n'
                'import json, os, sys\n'
                'from pathlib import Path\n'
                'with Path(os.environ["GROUP_TEST_LOG"]).open("a") as log:\n'
                '    log.write(json.dumps({"args": sys.argv[1:], "cwd": os.getcwd()}) + "\\n")\n'
                'if sys.argv[-1] == "list":\n'
                '    print("TypefluxTests.LLMRouterTests/testRoutes")\n'
                '    print("TypefluxTests.ProcessCommandRunnerTests/testExit")\n'
                'else:\n'
                '    sys.exit(5)\n', encoding="utf-8",
            )
            swift.chmod(0o755)
            log = directory / "commands.jsonl"
            environment = dict(os.environ, PATH=f"{directory}{os.pathsep}{os.environ['PATH']}",
                               GROUP_TEST_LOG=str(log))
            result = subprocess.run(
                [sys.executable, str(ROOT / "scripts/test_groups.py"), "unit", "--skip-build"],
                cwd=directory, env=environment, text=True, capture_output=True,
            )
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertEqual(result.returncode, 5)
            self.assertEqual(len(calls), 2)
            self.assertTrue(all(call["cwd"] == str(ROOT) for call in calls))
            self.assertEqual(calls[0]["args"], ["test", "--skip-build", "list"])
            self.assertEqual(calls[1]["args"][-2], "--filter")
            self.assertRegex("TypefluxTests.LLMRouterTests/testRoutes", calls[1]["args"][-1])


if __name__ == "__main__":
    unittest.main()
