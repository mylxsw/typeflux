"""Verify cache invalidation, compact source contracts and bounded native execution."""

from contextlib import redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import test_runtime as RUNTIME
from test_profiles import PROFILES, selected_profile_files


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="typeflux test runtime ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.directory = self.root / ".build/test-runner"
        self.directory.mkdir(parents=True)
        self.source = self.root / "Sources/Example.swift"
        self.source.parent.mkdir()
        self.source.write_text("let value = 1")
        self.tests = self.root / "Tests/TypefluxTests"
        self.tests.mkdir(parents=True)
        (self.tests / "ExampleTests.swift").write_text("struct ExampleTests {}")
        (self.root / "Package.swift").write_text("manifest")
        self.bundle = self.root / ".build/debug/TypefluxTests.xctest"
        self.binary = self.bundle / "Contents/MacOS/TypefluxTests"
        self.binary.parent.mkdir(parents=True)
        self.binary.write_bytes(b"compiled")
        self.tools = {}
        for name in ("xctest", "swift-testing"):
            executable = self.root / name
            executable.write_text("fake tool")
            self.tools[name] = executable
        self.environment = {"PATH": "/usr/bin", "DEVELOPER_DIR": str(self.root / "developer"), "LANG": "C"}
        self.args = SimpleNamespace(jobs=None, rebuild=False, skip_build=False)

    def prepare(self, output="TypefluxTests.ExampleTests/example()", action=None):
        def build(*args, **kwargs):
            if action:
                action()
            return subprocess.CompletedProcess([], 0, stdout=output)
        with patch.object(RUNTIME.subprocess, "run", side_effect=build) as run, \
                patch.object(RUNTIME, "discover", return_value=output), redirect_stdout(io.StringIO()):
            result = RUNTIME.prepare(self.root, None, self.args, self.environment, self.directory, self.tools)
        return result, run

    def save(self, result):
        discovery, _, inputs, artifacts, _ = result
        RUNTIME.save_build(self.directory, discovery, inputs, artifacts)

    def test_cache_reuses_only_identical_inputs_and_products(self):
        result, run = self.prepare()
        self.assertEqual(run.call_count, 1)
        self.save(result)
        again, run = self.prepare()
        run.assert_not_called()
        self.assertEqual(again[:4], result[:4])
        self.binary.write_bytes(b"another build")
        _, run = self.prepare()
        self.assertEqual(run.call_count, 1)

    def test_source_changes_even_same_size_and_restored_mtime_invalidate(self):
        result, _ = self.prepare()
        self.save(result)
        before = self.source.stat()
        self.source.write_text("let value = 2")
        os.utime(self.source, ns=(before.st_atime_ns, before.st_mtime_ns))
        _, run = self.prepare()
        self.assertEqual(run.call_count, 1)

    def test_package_dependency_toolchain_environment_and_added_files_invalidate(self):
        changes = [lambda: (self.root / "Package.resolved").write_text("new lockfile"),
                   lambda: self.tools["xctest"].write_text("new tool"),
                   lambda: self.environment.update(LANG="en_US.UTF-8"),
                   lambda: (self.root / "Sources/New.swift").write_text("let added = 1")]
        for change in changes:
            result, _ = self.prepare()
            self.save(result)
            change()
            _, run = self.prepare()
            self.assertEqual(run.call_count, 1)

    def test_deleted_source_and_build_products_invalidate(self):
        result, _ = self.prepare()
        self.save(result)
        self.source.unlink()
        _, run = self.prepare()
        self.assertEqual(run.call_count, 1)
        self.binary.unlink()
        _, run = self.prepare(action=lambda: self.binary.write_bytes(b"rebuilt"))
        self.assertEqual(run.call_count, 1)

    def test_rebuild_and_skip_build_never_bless_a_stale_binary(self):
        self.args.skip_build = True
        with self.assertRaisesRegex(ValueError, "matching verified build"):
            self.prepare()
        self.args.skip_build = False
        result, _ = self.prepare()
        self.save(result)
        self.args.rebuild = True
        _, run = self.prepare()
        self.assertEqual(run.call_count, 1)

    def test_source_edits_during_build_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "Sources changed"):
            self.prepare(action=lambda: self.source.write_text("edited during compilation"))
        self.assertFalse((self.directory / "build.json").exists())

    def test_invalid_cache_and_wrong_bundle_layout_rebuild_or_fail(self):
        (self.directory / "build.json").write_text("not JSON")
        (self.directory / "files.json").write_text("[]")
        _, run = self.prepare()
        self.assertEqual(run.call_count, 1)
        extra = self.root / ".build/debug/OtherTests.xctest"
        extra.mkdir()
        self.assertEqual(RUNTIME.find_bundle(self.root), self.bundle.resolve())
        shutil.rmtree(self.bundle)
        with self.assertRaisesRegex(ValueError, "Expected a"):
            self.prepare()

    def test_selection_variables_are_not_compiler_inputs(self):
        result, _ = self.prepare()
        self.save(result)
        self.environment.update(FILTER="another method", SUITE="another suite", REASON="requested")
        _, run = self.prepare()
        run.assert_not_called()

    def test_cache_stores_hashes_not_environment_values(self):
        self.environment["ARBITRARY_SETTING"] = "private-environment-value"
        result, _ = self.prepare()
        self.save(result)
        data = (self.directory / "build.json").read_text() + (self.directory / "files.json").read_text()
        self.assertNotIn("private-environment-value", data)
        with patch.dict(os.environ, {"MULTICA_TOKEN": "runtime-credential", "API_KEY": "provider-credential",
                                     "TYPEFLUX_REAL_SCREEN_CAPTURE_TESTS": "1"}, clear=True):
            self.assertEqual(RUNTIME.child_environment(), {"TYPEFLUX_REAL_SCREEN_CAPTURE_TESTS": "1"})

    def test_json_writes_and_runner_lock_release_on_failure(self):
        path = self.directory / "state.json"
        RUNTIME.write_json(path, {"valid": True})
        self.assertEqual(RUNTIME.read_json(path), {"valid": True})
        with self.assertRaisesRegex(RuntimeError, "failed"):
            with RUNTIME.runner_lock(self.root):
                raise RuntimeError("failed")
        with RUNTIME.runner_lock(self.root) as directory:
            self.assertEqual(directory, self.directory)

    def test_compact_profiles_preserve_reviewed_files_and_unknown_scopes(self):
        self.assertEqual(selected_profile_files(["ScrollStitcherTests"]), sorted(PROFILES["scroll"]["files"]))
        self.assertIsNone(selected_profile_files(["UnknownTests"]))
        self.assertIsNone(selected_profile_files(["ScrollStitcherTests", "UnknownTests"]))
        self.assertIsNone(selected_profile_files([]))
        both = selected_profile_files(["ScrollStitcherTests", "BitmapTestPixelsTests"])
        self.assertIn("ScrollCaptureFixtures.swift", both)
        self.assertIn("ExclusiveUIStateTrait.swift", both)
        with self.assertRaisesRegex(ValueError, "outside"):
            selected_profile_files(["UnknownTests"], "calculator")
        for profile in PROFILES.values():
            for file in profile["files"]:
                self.assertTrue((ROOT / "Tests/TypefluxTests" / file).is_file(), file)

    def test_native_xctest_batches_execute_each_method_once_with_bounded_workers(self):
        tests = {f"TypefluxTests.ExampleTests/testValue{index}" for index in range(9)}
        calls = []
        def run(command, **kwargs):
            calls.append((command, kwargs))
            count = len(command[2].split(","))
            return subprocess.CompletedProcess([], 0, stdout=f"Executed {count} tests, with 0 failures\n")
        with patch.object(RUNTIME.subprocess, "run", side_effect=run), redirect_stdout(io.StringIO()):
            status = RUNTIME.run_native("xctest", tests, 4, self.bundle, self.tools, {}, str, self.root)
        self.assertEqual(status, 0)
        self.assertEqual(len(calls), 4)
        selectors = [item for command, _ in calls for item in command[2].split(",")]
        self.assertEqual(set(selectors), tests)
        self.assertEqual(len(selectors), len(tests))
        self.assertTrue(all(kwargs["cwd"] == self.root for _, kwargs in calls))
        self.assertTrue(all(kwargs["env"]["SWIFT_TESTING_ENABLED"] == "0" for _, kwargs in calls))

    def test_native_discovery_is_complete_and_rejects_bad_classes(self):
        data = {"name": "All Tests", "tests": [{"name": "bundle", "tests": [
            {"name": "TypefluxFocusedTests.ExampleTests", "tests": [{"name": "testA"}, {"name": "testB"}]}
        ]}]}
        self.assertEqual(RUNTIME.xctest_identifiers(data), ["TypefluxFocusedTests.ExampleTests/testA",
                                                         "TypefluxFocusedTests.ExampleTests/testB"])
        self.assertEqual(RUNTIME.xctest_identifiers({"name": "All", "tests": []}), [])
        for bad in ({"tests": []}, {"name": "All", "tests": "invalid"}, {"name": "testMethod"}):
            with self.assertRaises(ValueError):
                RUNTIME.xctest_identifiers(bad)

    def test_discovery_uses_both_libraries_without_executing_tests(self):
        self.tools["xctest-discovery"] = self.root / "discovery-helper"
        calls = []
        def invoke(command, **kwargs):
            calls.append((command, kwargs))
            if command[0] == str(self.tools["xctest-discovery"]):
                Path(command[-1]).write_text(json.dumps({"name": "All", "tests": [
                    {"name": "TypefluxTests.XTests", "tests": [{"name": "testX"}]}
                ]}))
                return subprocess.CompletedProcess([], 0)
            return subprocess.CompletedProcess([], 0, stdout="TypefluxTests.SwiftTests/run()")
        with patch.object(RUNTIME.subprocess, "run", side_effect=invoke):
            result = RUNTIME.discover(self.bundle, self.tools, {}, self.root, self.directory)
        self.assertIn("TypefluxTests.XTests/testX", result)
        self.assertIn("TypefluxTests.SwiftTests/run()", result)
        self.assertEqual(calls[0][1]["env"]["SWIFT_TESTING_ENABLED"], "0")
        self.assertIn("--list-tests", calls[1][0])

    def test_xctest_only_discovery_accepts_empty_swift_testing_but_not_real_failures(self):
        self.tools["xctest-discovery"] = self.root / "discovery-helper"
        for status, output, valid in ((69, "", True), (69, "unexpected output", False), (7, "", False)):
            def invoke(command, **kwargs):
                if command[0] == str(self.tools["xctest-discovery"]):
                    Path(command[-1]).write_text(json.dumps({"name": "All", "tests": [
                        {"name": "TypefluxTests.XTests", "tests": [{"name": "testX"}]}
                    ]}))
                    return subprocess.CompletedProcess([], 0)
                return subprocess.CompletedProcess([], status, stdout=output)
            with patch.object(RUNTIME.subprocess, "run", side_effect=invoke):
                if valid:
                    self.assertIn("TypefluxTests.XTests/testX", RUNTIME.discover(
                        self.bundle, self.tools, {}, self.root, self.directory))
                else:
                    with self.assertRaises(subprocess.CalledProcessError):
                        RUNTIME.discover(self.bundle, self.tools, {}, self.root, self.directory)

    def test_native_unknown_xctest_is_serial_and_missing_tests_fail(self):
        tests = {"TypefluxTests.ExampleTests/testA", "TypefluxTests.ExampleTests/testB"}
        for output, expected in (("Executed 2 tests, with 0 failures", 0),
                                 ("Executed 0 tests, with 0 failures", 1), ("no tests", 1)):
            with patch.object(RUNTIME.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, stdout=output)) as run, \
                    redirect_stdout(io.StringIO()):
                status = RUNTIME.run_native("serial", tests, 4, self.bundle, self.tools, {}, str, self.root)
            self.assertEqual(status, expected)
            self.assertEqual(run.call_count, 1)

    def test_complete_classes_compress_selectors_without_expanding_partial_scope(self):
        tests = {"TypefluxTests.ExampleTests/testA", "TypefluxTests.ExampleTests/testB"}
        with patch.object(RUNTIME.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, stdout="Executed 2 tests,")) as run, \
                redirect_stdout(io.StringIO()):
            status = RUNTIME.run_native("serial", tests, 4, self.bundle, self.tools, {}, str, self.root, tests)
        self.assertEqual(status, 0)
        self.assertEqual(run.call_args.args[0][2], "TypefluxTests.ExampleTests")
        with patch.object(RUNTIME.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, stdout="Executed 1 test,")) as run, \
                redirect_stdout(io.StringIO()):
            RUNTIME.run_native("serial", {next(iter(tests))}, 4, self.bundle, self.tools, {}, str, self.root, tests)
        self.assertIn("/test", run.call_args.args[0][2])

    def test_native_failure_is_propagated_and_never_retried(self):
        tests = {"TypefluxTests.ExampleTests/testA", "TypefluxTests.OtherTests/run()"}
        with patch.object(RUNTIME.subprocess, "run", return_value=subprocess.CompletedProcess([], 7, stdout="failed")) as run, \
                redirect_stdout(io.StringIO()):
            status = RUNTIME.run_native("serial", tests, 4, self.bundle, self.tools, {}, str, self.root)
        self.assertEqual(status, 7)
        self.assertEqual(run.call_count, 1)

    def test_swift_testing_uses_the_binary_and_keeps_ui_serial(self):
        tests = {"TypefluxTests.ExampleTests/run()"}
        with patch.object(RUNTIME.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run:
            status = RUNTIME.run_native("serial", tests, 4, self.bundle, self.tools, {}, lambda _: "anchored filter", self.root)
        self.assertEqual(status, 0)
        command = run.call_args.args[0]
        self.assertEqual(command[2], str(self.binary))
        self.assertIn("--no-parallel", command)
        self.assertEqual(command[-1], "anchored filter")
        self.binary.unlink()
        with self.assertRaisesRegex(ValueError, "layout"):
            RUNTIME.run_native("serial", tests, 4, self.bundle, self.tools, {}, str, self.root)


if __name__ == "__main__":
    unittest.main()
