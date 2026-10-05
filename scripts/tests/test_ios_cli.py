"""Exercise the iOS developer commands without building or touching devices."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "ios.py"
SPEC = importlib.util.spec_from_file_location("typeflux_ios_cli", SCRIPT)
ios = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ios)


def device(identifier, name="iPhone 17 Pro", state="Shutdown", available=True):
    return {"udid": identifier, "name": name, "state": state, "isAvailable": available}


def simulator_catalog(*groups):
    return {"devices": dict(groups)}


class SimulatorSelectionTests(unittest.TestCase):
    def test_ignores_runtimes_older_than_deployment_target(self):
        catalog = simulator_catalog(
            ("com.apple.CoreSimulator.SimRuntime.iOS-16-4", [device("old", state="Booted")]),
            ("com.apple.CoreSimulator.SimRuntime.iOS-17-0", [device("supported")]),
        )
        self.assertEqual(ios.selected_simulator(catalog)["udid"], "supported")
        with self.assertRaises(ios.CLIError):
            ios.selected_simulator(catalog, "old")

    def test_prefers_booted_phone_over_newer_runtime(self):
        catalog = simulator_catalog(
            ("com.apple.CoreSimulator.SimRuntime.iOS-26-10", [device("new")]),
            ("com.apple.CoreSimulator.SimRuntime.iOS-26-5", [device("booted", state="Booted")]),
        )
        self.assertEqual(ios.selected_simulator(catalog)["udid"], "booted")

    def test_chooses_latest_runtime_numerically_and_filters_nonphones(self):
        catalog = simulator_catalog(
            ("com.apple.CoreSimulator.SimRuntime.tvOS-30-0", [device("tv")]),
            ("com.apple.CoreSimulator.SimRuntime.iOS-27-0", [device("unavailable", available=False)]),
            ("com.apple.CoreSimulator.SimRuntime.iOS-26-5", [device("old")]),
            ("com.apple.CoreSimulator.SimRuntime.iOS-26-10", [device("ipad", "iPad Pro"), device("new")]),
        )
        self.assertEqual(ios.selected_simulator(catalog)["udid"], "new")

    def test_explicit_identifier_can_select_ipad_case_insensitively(self):
        catalog = simulator_catalog(
            ("com.apple.CoreSimulator.SimRuntime.iOS-26-5", [device("PHONE"), device("IPAD", "iPad Pro")]),
        )
        self.assertEqual(ios.selected_simulator(catalog, "ipad")["udid"], "IPAD")

    def test_rejects_unknown_or_unavailable_requested_device(self):
        catalog = simulator_catalog(
            ("com.apple.CoreSimulator.SimRuntime.iOS-26-5", [device("available"), device("unavailable", available=False)]),
        )
        for identifier in ("missing", "unavailable", "booted"):
            with self.subTest(identifier=identifier), self.assertRaises(ios.CLIError):
                ios.selected_simulator(catalog, identifier)

    def test_no_available_iphone_has_actionable_error(self):
        for catalog in ({}, {"devices": {}}, simulator_catalog(("iOS-26-0", [device("ipad", "iPad Pro")]))):
            with self.subTest(catalog=catalog), self.assertRaisesRegex(ios.CLIError, "iPhone|runtime"):
                ios.selected_simulator(catalog)


class ConfigurationTests(unittest.TestCase):
    def test_accepts_https_api_origin_and_path(self):
        for value in ("", "https://api.example.com", "https://api.example.com/v1", "https://localhost:8443", "https://[::1]:8443"):
            with self.subTest(value=value):
                self.assertEqual(ios.validate_api_url(value), value)

    def test_rejects_insecure_or_ambiguous_api_urls(self):
        for value in ("http://localhost:8080", "api.example.com", "https://", "https://user:secret@example.com", "https://example.com?token=secret", "https://example.com/#secret", "https://bad_host", "https://example.com:0", "https://example.com:invalid", "https://example.com/white space", "https://example.com\\path"):
            with self.subTest(value=value), self.assertRaises(ios.CLIError):
                ios.validate_api_url(value)

    def test_relative_paths_are_resolved_from_repository_not_cwd(self):
        default = ios.REPOSITORY_ROOT / "build" / "ios"
        self.assertEqual(ios.repository_path("", default), default)
        self.assertEqual(ios.repository_path("custom directory/ios", default), ios.REPOSITORY_ROOT / "custom directory/ios")
        self.assertEqual(ios.repository_path("/some absolute path/ios", default), Path("/some absolute path/ios"))

    def test_build_arguments_preserve_paths_and_api_as_single_values(self):
        derived = Path("/Build output/Typeflux iOS")
        arguments = ios.build_arguments("Debug", "platform=iOS Simulator,id=SIM", derived, "https://api.example.com/v1")
        self.assertEqual(arguments[arguments.index("-derivedDataPath") + 1], str(derived))
        self.assertEqual(arguments[arguments.index("-destination") + 1], "platform=iOS Simulator,id=SIM")
        self.assertIn("TYPEFLUX_API_URL=https://api.example.com/v1", arguments)
        self.assertNotIn("-allowProvisioningUpdates", arguments)


class CommandTests(unittest.TestCase):
    """Execute command orchestration against a synthetic build and device catalogue."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="typeflux ios tests ")
        self.addCleanup(self.directory.cleanup)
        self.derived = Path(self.directory.name) / "Derived Data"
        self.archive = Path(self.directory.name) / "archives" / "TypefluxIOS.xcarchive"
        self.environ = {
            "TYPEFLUX_IOS_DERIVED_DATA": str(self.derived),
            "TYPEFLUX_IOS_ARCHIVE_PATH": str(self.archive),
        }
        self.environment_patch = mock.patch.dict(os.environ, self.environ, clear=True)
        self.environment_patch.start()
        self.addCleanup(self.environment_patch.stop)
        self.catalog = simulator_catalog(("com.apple.CoreSimulator.SimRuntime.iOS-26-5", [device("SIM")]))
        self.calls = []
        self.failure = None
        self.runner = mock.patch.object(ios, "run", side_effect=self.run_command)
        self.runner.start()
        self.addCleanup(self.runner.stop)
        self.developer = Path(self.directory.name) / "Selected Xcode.app/Contents/Developer"
        (self.developer / "Applications/Simulator.app").mkdir(parents=True)
        self.preflight = mock.patch.object(ios, "preflight", return_value=self.developer)
        self.preflight.start()
        self.addCleanup(self.preflight.stop)
        for configuration in ("Debug", "Release"):
            for platform in ("iphonesimulator", "iphoneos"):
                app = self.derived / "Build" / "Products" / f"{configuration}-{platform}" / "TypefluxIOS.app"
                app.mkdir(parents=True)
                with (app / "Info.plist").open("wb") as file:
                    plistlib.dump({"CFBundleIdentifier": "com.example.typeflux.ios"}, file)

    def run_command(self, arguments, capture=False):
        self.calls.append(list(arguments))
        if self.failure and self.failure(arguments):
            raise subprocess.CalledProcessError(65, arguments)
        if arguments[:4] == ["xcrun", "simctl", "list", "devices"]:
            return json.dumps(self.catalog)
        return ""

    def invoke(self, command):
        self.stdout = io.StringIO()
        self.stderr = io.StringIO()
        with contextlib.redirect_stdout(self.stdout), contextlib.redirect_stderr(self.stderr):
            return ios.main([command])

    def command_index(self, prefix):
        return next(index for index, command in enumerate(self.calls) if command[:len(prefix)] == prefix)

    def test_build_does_not_install_or_launch(self):
        self.assertEqual(self.invoke("build"), 0, self.stderr.getvalue())
        build = self.calls[self.command_index(["xcodebuild"])]
        self.assertIn("build", build)
        self.assertIn("platform=iOS Simulator,id=SIM", build)
        self.assertNotIn("-allowProvisioningDeviceRegistration", build)
        self.assertFalse(any("install" in call or "launch" in call for call in self.calls))

    def test_install_builds_before_install_and_does_not_launch(self):
        self.assertEqual(self.invoke("install"), 0, self.stderr.getvalue())
        self.assertLess(self.command_index(["xcodebuild"]), self.command_index(["xcrun", "simctl", "install"]))
        self.assertFalse(any("launch" in call for call in self.calls))

    def test_run_builds_installs_and_launches_same_simulator(self):
        self.assertEqual(self.invoke("run"), 0, self.stderr.getvalue())
        build = self.command_index(["xcodebuild"])
        install = self.command_index(["xcrun", "simctl", "install"])
        launch = self.command_index(["xcrun", "simctl", "launch"])
        self.assertLess(build, install)
        self.assertLess(install, launch)
        self.assertIn(["xcrun", "simctl", "bootstatus", "SIM", "-b"], self.calls)
        self.assertEqual(self.calls[install][3], "SIM")
        self.assertIn("SIM", self.calls[launch])
        self.assertIn("com.example.typeflux.ios", self.calls[launch])
        self.assertIn("--terminate-running-process", self.calls[launch])
        self.assertNotIn("--synthetic-preview", self.calls[launch])
        self.assertIn(["open", "-a", str(self.developer / "Applications/Simulator.app"), "--args", "-CurrentDeviceUDID", "SIM"], [[str(argument) for argument in command] for command in self.calls])

    def test_preview_launches_offline_fixture_and_builds_debug(self):
        self.assertEqual(self.invoke("preview"), 0, self.stderr.getvalue())
        build = self.calls[self.command_index(["xcodebuild"])]
        self.assertEqual(build[build.index("-configuration") + 1], "Debug")
        launch = self.calls[self.command_index(["xcrun", "simctl", "launch"])]
        self.assertIn("--synthetic-preview", launch)

    def test_run_falls_back_to_registered_simulator_when_developer_app_is_missing(self):
        (self.developer / "Applications/Simulator.app").rmdir()
        self.assertEqual(self.invoke("run"), 0, self.stderr.getvalue())
        self.assertIn(["open", "-a", "Simulator", "--args", "-CurrentDeviceUDID", "SIM"], self.calls)

    def test_preview_rejects_release_without_building(self):
        os.environ["TYPEFLUX_IOS_CONFIGURATION"] = "Release"
        self.assertEqual(self.invoke("preview"), 1)
        self.assertIn("Debug", self.stderr.getvalue())
        self.assertFalse(self.calls)

    def test_doctor_validates_available_simulator(self):
        self.assertEqual(self.invoke("doctor"), 0, self.stderr.getvalue())
        self.assertIn("make ios-run", self.stdout.getvalue())
        self.assertFalse(any(call[0] == "xcodebuild" for call in self.calls))

    def test_devices_lists_physical_udid_separately_from_coredevice_identifier(self):
        self.assertEqual(self.invoke("devices"), 0, self.stderr.getvalue())
        self.assertIn(["xcrun", "devicectl", "list", "devices"], self.calls)
        self.assertIn(["xcrun", "xctrace", "list", "devices"], self.calls)
        self.assertIn("not Xcode destination UDIDs", self.stdout.getvalue())

    def test_failed_build_cannot_install_or_launch_existing_app(self):
        self.failure = lambda arguments: arguments[0] == "xcodebuild"
        self.assertEqual(self.invoke("run"), 65)
        self.assertFalse(any("install" in call or "launch" in call for call in self.calls))

    def test_failed_install_cannot_launch_stale_app(self):
        self.failure = lambda arguments: arguments[:3] == ["xcrun", "simctl", "install"]
        self.assertEqual(self.invoke("run"), 65)
        self.assertFalse(any("launch" in call for call in self.calls))

    def test_missing_built_bundle_prevents_install_or_launch(self):
        info = self.derived / "Build/Products/Debug-iphonesimulator/TypefluxIOS.app/Info.plist"
        info.unlink()
        self.assertEqual(self.invoke("run"), 1)
        self.assertIn("Cannot read", self.stderr.getvalue())
        self.assertFalse(any("install" in call or "launch" in call for call in self.calls))

    def test_release_configuration_is_used_for_normal_build(self):
        os.environ["TYPEFLUX_IOS_CONFIGURATION"] = "Release"
        self.assertEqual(self.invoke("build"), 0, self.stderr.getvalue())
        build = self.calls[self.command_index(["xcodebuild"])]
        self.assertEqual(build[build.index("-configuration") + 1], "Release")

    def test_invalid_configuration_prevents_build(self):
        os.environ["TYPEFLUX_IOS_CONFIGURATION"] = "Debug; touch /tmp/unsafe"
        self.assertEqual(self.invoke("build"), 1)
        self.assertFalse(any(call[0] == "xcodebuild" for call in self.calls))

    def test_requested_simulator_is_used(self):
        self.catalog["devices"]["com.apple.CoreSimulator.SimRuntime.iOS-26-5"].append(device("OTHER", "iPad Pro"))
        os.environ["TYPEFLUX_IOS_SIMULATOR"] = "OTHER"
        self.assertEqual(self.invoke("run"), 0, self.stderr.getvalue())
        self.assertIn(["xcrun", "simctl", "bootstatus", "OTHER", "-b"], self.calls)

    def test_deploy_requires_team_and_physical_identifier(self):
        for values in ({}, {"TYPEFLUX_IOS_TEAM": "ABCDEFGHIJ"}, {"TYPEFLUX_IOS_DEVICE": "00008101-0000000000000001"}):
            with self.subTest(values=values), mock.patch.dict(os.environ, values):
                self.calls.clear()
                self.assertEqual(self.invoke("deploy"), 1)
                self.assertFalse(any(call[0] == "xcodebuild" for call in self.calls))

    def test_deploy_signs_installs_and_launches_same_device(self):
        physical_id = "00008101-0000000000000001"
        os.environ.update(TYPEFLUX_IOS_TEAM="ABCDEFGHIJ", TYPEFLUX_IOS_DEVICE=physical_id)
        self.assertEqual(self.invoke("deploy"), 0, self.stderr.getvalue())
        build = self.calls[self.command_index(["xcodebuild"])]
        self.assertIn(f"platform=iOS,id={physical_id}", build)
        self.assertIn("DEVELOPMENT_TEAM=ABCDEFGHIJ", build)
        self.assertIn("-allowProvisioningUpdates", build)
        self.assertIn("-allowProvisioningDeviceRegistration", build)
        install = self.command_index(["xcrun", "devicectl", "device", "install", "app"])
        launch = self.command_index(["xcrun", "devicectl", "device", "process", "launch"])
        self.assertLess(install, launch)
        self.assertIn(physical_id, self.calls[install])
        self.assertIn(physical_id, self.calls[launch])
        self.assertIn("com.example.typeflux.ios", self.calls[launch])

    def test_deploy_rejects_coredevice_uuid_before_building(self):
        os.environ.update(TYPEFLUX_IOS_TEAM="ABCDEFGHIJ", TYPEFLUX_IOS_DEVICE="00000000-1111-2222-3333-444444444444")
        self.assertEqual(self.invoke("deploy"), 1)
        self.assertIn("not the CoreDevice UUID", self.stderr.getvalue())
        self.assertFalse(self.calls)

    def test_deploy_accepts_legacy_physical_udid(self):
        os.environ.update(TYPEFLUX_IOS_TEAM="ABCDEFGHIJ", TYPEFLUX_IOS_DEVICE="A" * 40)
        self.assertEqual(self.invoke("deploy"), 0, self.stderr.getvalue())

    def test_deploy_failed_install_does_not_launch(self):
        os.environ.update(TYPEFLUX_IOS_TEAM="ABCDEFGHIJ", TYPEFLUX_IOS_DEVICE="00008101-0000000000000001")
        self.failure = lambda arguments: arguments[:5] == ["xcrun", "devicectl", "device", "install", "app"]
        self.assertEqual(self.invoke("deploy"), 65)
        self.assertFalse(any("launch" in call for call in self.calls))

    def test_archive_always_release_and_requires_team(self):
        self.assertEqual(self.invoke("archive"), 1)
        os.environ["TYPEFLUX_IOS_TEAM"] = "ABCDEFGHIJ"
        self.assertEqual(self.invoke("archive"), 0, self.stderr.getvalue())
        build = self.calls[self.command_index(["xcodebuild"])]
        self.assertIn("archive", build)
        self.assertEqual(build[build.index("-configuration") + 1], "Release")
        self.assertEqual(build[build.index("-archivePath") + 1], str(self.archive))
        self.assertIn("generic/platform=iOS", build)
        self.assertNotIn("-allowProvisioningDeviceRegistration", build)

    def test_archive_refuses_existing_output_without_running_build(self):
        os.environ["TYPEFLUX_IOS_TEAM"] = "ABCDEFGHIJ"
        self.archive.mkdir(parents=True)
        self.assertEqual(self.invoke("archive"), 1)
        self.assertFalse(any(call[0] == "xcodebuild" for call in self.calls))

    def test_archive_refuses_dangling_symlink(self):
        os.environ["TYPEFLUX_IOS_TEAM"] = "ABCDEFGHIJ"
        self.archive.parent.mkdir(parents=True)
        self.archive.symlink_to(self.archive.parent / "missing-target")
        self.assertEqual(self.invoke("archive"), 1)
        self.assertTrue(self.archive.is_symlink())
        self.assertFalse(any(call[0] == "xcodebuild" for call in self.calls))

    def test_invalid_api_url_prevents_build_and_hides_credentials(self):
        os.environ["TYPEFLUX_API_URL"] = "https://user:secret-value@example.com"
        self.assertEqual(self.invoke("build"), 1)
        self.assertFalse(any(call[0] == "xcodebuild" for call in self.calls))
        self.assertNotIn("secret-value", self.stdout.getvalue() + self.stderr.getvalue())


class PreflightTests(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.developer = "/Applications/Xcode.app/Contents/Developer"
        self.version = "Xcode 26.0\nBuild version 17A000"
        self.platform_patch = mock.patch.object(ios.platform, "system", return_value="Darwin")
        self.platform_mock = self.platform_patch.start()
        self.addCleanup(self.platform_patch.stop)
        self.which_patch = mock.patch.object(ios.shutil, "which", side_effect=lambda command: "/usr/bin/" + command)
        self.which_mock = self.which_patch.start()
        self.addCleanup(self.which_patch.stop)
        self.run_patch = mock.patch.object(ios, "run", side_effect=self.run_command)
        self.run_mock = self.run_patch.start()
        self.addCleanup(self.run_patch.stop)

    def run_command(self, arguments, capture=False):
        self.calls.append(arguments)
        if arguments == ["xcode-select", "-p"]:
            return self.developer
        if arguments == ["xcodebuild", "-version"]:
            return self.version
        return "26.0"

    def test_rejects_non_macos_before_invoking_commands(self):
        self.platform_mock.return_value = "Linux"
        with self.assertRaisesRegex(ios.CLIError, "macOS"):
            ios.preflight("run")
        self.run_mock.assert_not_called()

    def test_reports_missing_tool(self):
        self.which_mock.side_effect = lambda command: None if command == "xcodebuild" else "/usr/bin/" + command
        with self.assertRaisesRegex(ios.CLIError, "Missing xcodebuild"):
            ios.preflight("run")

    def test_rejects_command_line_tools_directory(self):
        self.developer = "/Library/Developer/CommandLineTools"
        with self.assertRaisesRegex(ios.CLIError, "full Xcode"):
            ios.preflight("run")

    def test_rejects_old_or_unreadable_xcode_version(self):
        for self.version in ("Xcode 16.4", "not a version"):
            with self.subTest(version=self.version), self.assertRaisesRegex(ios.CLIError, "Xcode 26"):
                ios.preflight("run")

    def test_simulator_preflight_uses_simctl_and_simulator_sdk(self):
        ios.preflight("run")
        self.assertIn(["xcrun", "--find", "simctl"], self.calls)
        self.assertIn(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"], self.calls)
        self.assertNotIn(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"], self.calls)

    def test_device_preflight_requires_devicectl_and_device_sdk(self):
        ios.preflight("deploy")
        self.assertIn(["xcrun", "--find", "devicectl"], self.calls)
        self.assertIn(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"], self.calls)

    def test_doctor_reports_both_sdks_and_developer_directory(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            ios.preflight("doctor")
        self.assertIn("iphoneos SDK", output.getvalue())
        self.assertIn("iphonesimulator SDK", output.getvalue())
        self.assertIn(self.developer, output.getvalue())
        self.assertIn(["xcrun", "--find", "xctrace"], self.calls)

    def test_missing_platform_propagates_preflight_failure(self):
        original = self.run_command

        def missing_sdk(arguments, capture=False):
            if "--show-sdk-version" in arguments:
                raise subprocess.CalledProcessError(1, arguments, stderr="SDK not found")
            return original(arguments, capture)

        self.run_mock.side_effect = missing_sdk
        with self.assertRaises(subprocess.CalledProcessError):
            ios.preflight("run")


class BundleTests(unittest.TestCase):
    def test_bundle_rejects_missing_or_malformed_plist(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory)
            with self.assertRaisesRegex(ios.CLIError, "Cannot read"):
                ios.bundle_identifier(app)
            (app / "Info.plist").write_text("not a plist")
            with self.assertRaisesRegex(ios.CLIError, "Cannot read"):
                ios.bundle_identifier(app)

    def test_bundle_rejects_missing_unresolved_or_non_string_identifier(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory)
            for identifier in ("", "$(PRODUCT_BUNDLE_IDENTIFIER)", 123):
                with self.subTest(identifier=identifier):
                    with (app / "Info.plist").open("wb") as file:
                        plistlib.dump({"CFBundleIdentifier": identifier}, file)
                    with self.assertRaisesRegex(ios.CLIError, "no resolved"):
                        ios.bundle_identifier(app)


class ProcessTests(unittest.TestCase):
    def test_runner_passes_argument_array_and_anchors_working_directory(self):
        arguments = ["tool", Path("/path with spaces/app"), "value=$(touch /tmp/should-not-run)"]
        with mock.patch.object(ios.subprocess, "run", return_value=subprocess.CompletedProcess(arguments, 0, stdout=None)) as process:
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(ios.run(arguments), "")
        process.assert_called_once_with([str(value) for value in arguments], cwd=ios.REPOSITORY_ROOT, check=True, text=True, capture_output=False)

    def test_capture_returns_stdout_without_echoing_command(self):
        output = io.StringIO()
        with mock.patch.object(ios.subprocess, "run", return_value=subprocess.CompletedProcess(["tool"], 0, stdout="result")) as process:
            with contextlib.redirect_stdout(output):
                self.assertEqual(ios.run(["tool"], capture=True), "result")
        self.assertTrue(process.call_args.kwargs["capture_output"])
        self.assertEqual(output.getvalue(), "")

    def test_failed_command_reports_captured_diagnostics_and_exit_status(self):
        for error_code, expected in ((65, 65), (-9, 1), (130, 1)):
            error = subprocess.CalledProcessError(error_code, ["xcodebuild", "build"], output="build output", stderr="build error")
            stderr = io.StringIO()
            with self.subTest(error_code=error_code), mock.patch.object(ios, "execute", side_effect=error), contextlib.redirect_stderr(stderr):
                self.assertEqual(ios.main(["run"]), expected)
            self.assertIn("build output", stderr.getvalue())
            self.assertIn("build error", stderr.getvalue())
            self.assertIn("IOS_QUICKSTART.zh-CN.md", stderr.getvalue())

    def test_filesystem_json_and_keyboard_errors_are_handled(self):
        for error, status in ((OSError("file missing"), 1), (ValueError("invalid JSON"), 1), (KeyboardInterrupt(), 130)):
            with self.subTest(error=error), mock.patch.object(ios, "execute", side_effect=error), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(ios.main(["run"]), status)

    def test_unknown_command_is_rejected_before_execution(self):
        with mock.patch.object(ios, "execute") as execute, contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as error:
                ios.main(["not-a-command"])
        self.assertEqual(error.exception.code, 2)
        execute.assert_not_called()


if __name__ == "__main__":
    unittest.main()
