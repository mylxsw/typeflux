#!/usr/bin/env python3
"""Build and launch the iOS client using the selected local Xcode installation."""

import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
from urllib.parse import urlsplit


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
MIN_XCODE_VERSION = 26
MIN_IOS_VERSION = 17
COMMANDS = ("doctor", "devices", "build", "install", "run", "preview", "deploy", "archive")


class CLIError(Exception):
    """An actionable local setup or configuration error."""


def run(arguments, capture=False):
    """Execute argv directly; captured diagnostics are reported by main on failure."""
    if not capture:
        print("+ " + shlex.join(str(argument) for argument in arguments), flush=True)
    result = subprocess.run(
        [str(argument) for argument in arguments],
        cwd=REPOSITORY_ROOT,
        check=True,
        text=True,
        capture_output=capture,
    )
    return result.stdout or ""


def repository_path(value, default):
    path = Path(value).expanduser() if value else Path(default)
    return path if path.is_absolute() else REPOSITORY_ROOT / path


def validate_api_url(value):
    if not value:
        return ""
    message = "TYPEFLUX_API_URL must be an HTTPS URL without credentials, query, or fragment."
    try:
        parsed = urlsplit(value)
        port = parsed.port
        if (
            parsed.scheme != "https"
            or not parsed.hostname
            or parsed.username is not None
            or parsed.password is not None
            or "?" in value
            or "#" in value
            or any(character.isspace() for character in value)
            or "\\" in value
            or (port is not None and port == 0)
        ):
            raise ValueError(message)
        # Reject malformed hostnames early without printing a potentially secret URL.
        host = parsed.hostname
        if ":" not in host:
            labels = host.rstrip(".").split(".")
            if not all(re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label) for label in labels):
                raise ValueError(message)
    except ValueError as error:
        raise CLIError(message) from error
    return value


def selected_simulator(devices, identifier=""):
    available = []
    for runtime, group in devices.get("devices", {}).items():
        match = re.search(r"\.iOS-(\d+(?:-\d+)*)$", runtime)
        if not match:
            continue
        version = tuple(int(part) for part in match.group(1).split("-"))
        if version[0] < MIN_IOS_VERSION:
            continue
        available.extend((version, device) for device in group if device.get("isAvailable", False))
    if identifier:
        for _, device in available:
            if device.get("udid", "").lower() == identifier.lower():
                return device
        raise CLIError(
            "TYPEFLUX_IOS_SIMULATOR must identify an available iOS 17+ simulator by UDID. "
            "Run make ios-devices to list simulators."
        )
    phones = [(version, device) for version, device in available if device.get("name", "").startswith("iPhone")]
    if not phones:
        raise CLIError(
            "No available iPhone simulator with iOS 17 or later. Install an iOS runtime in "
            "Xcode > Settings > Components and create an iPhone in Window > Devices and Simulators."
        )
    phones.sort(key=lambda item: (item[1].get("state") == "Booted", item[0]), reverse=True)
    return phones[0][1]


def simulator():
    devices = json.loads(run(["xcrun", "simctl", "list", "devices", "available", "--json"], capture=True))
    device = selected_simulator(devices, os.environ.get("TYPEFLUX_IOS_SIMULATOR", ""))
    print("Selected simulator: {name} ({udid}, {state})".format(**device), flush=True)
    return device


def preflight(command):
    if platform.system() != "Darwin":
        raise CLIError("iOS builds require macOS and the full Xcode application (version 26 or later).")
    for executable in ("xcode-select", "xcodebuild", "xcrun"):
        if shutil.which(executable) is None:
            raise CLIError("Missing {}. Install Xcode 26+ and select its Developer directory.".format(executable))
    developer = run(["xcode-select", "-p"], capture=True).strip()
    if not developer.endswith("/Contents/Developer"):
        raise CLIError(
            "The active developer directory is not a full Xcode installation. Run "
            "sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer "
            "(adjust the path for your installation), then open Xcode to finish setup."
        )
    version = run(["xcodebuild", "-version"], capture=True).strip()
    match = re.search(r"Xcode (\d+)", version)
    if not match or int(match.group(1)) < MIN_XCODE_VERSION:
        raise CLIError("Xcode 26 or later is required. Select it with xcode-select or DEVELOPER_DIR.")
    tools = ("devicectl",) if command in ("deploy", "archive") else ("simctl",)
    if command in ("doctor", "devices"):
        tools = ("simctl", "devicectl", "xctrace")
    for tool in tools:
        run(["xcrun", "--find", tool], capture=True)
    sdks = ("iphoneos",) if command in ("deploy", "archive") else ("iphonesimulator",)
    if command == "doctor":
        sdks = ("iphonesimulator", "iphoneos")
    for sdk in sdks:
        sdk_version = run(["xcrun", "--sdk", sdk, "--show-sdk-version"], capture=True).strip()
        if command == "doctor":
            print("{} SDK: {}".format(sdk, sdk_version))
    if command == "doctor":
        print("{}\nDeveloper directory: {}".format(version, developer))
    return Path(developer)


def build_arguments(configuration, destination, derived_data, api_url="", team=""):
    arguments = [
        "xcodebuild", "-project", str(REPOSITORY_ROOT / "Apps/iOS/TypefluxIOS.xcodeproj"),
        "-scheme", "TypefluxIOS", "-configuration", configuration,
        "-destination", destination, "-derivedDataPath", str(derived_data),
    ]
    if api_url:
        arguments.append("TYPEFLUX_API_URL=" + api_url)
    if team:
        arguments.extend(["-allowProvisioningUpdates", "DEVELOPMENT_TEAM=" + team])
    return arguments


def bundle_identifier(app_path):
    try:
        with (app_path / "Info.plist").open("rb") as handle:
            identifier = plistlib.load(handle).get("CFBundleIdentifier", "")
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        raise CLIError("Cannot read the built app's Info.plist: {}".format(app_path)) from error
    if not isinstance(identifier, str) or not identifier or "$" in identifier:
        raise CLIError("The built app has no resolved CFBundleIdentifier: {}".format(app_path))
    return identifier


def signing_team():
    team = os.environ.get("TYPEFLUX_IOS_TEAM", "")
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise CLIError(
            "Set TYPEFLUX_IOS_TEAM to your 10-character Apple Developer Team ID. "
            "Sign in under Xcode > Settings > Accounts and enable Sign in with Apple "
            "for the app.typeflux.ios App ID."
        )
    return team


def execute(command):
    api_url = validate_api_url(os.environ.get("TYPEFLUX_API_URL", ""))
    configuration = os.environ.get("TYPEFLUX_IOS_CONFIGURATION", "Debug")
    if command not in ("doctor", "devices", "archive") and configuration not in ("Debug", "Release"):
        raise CLIError("TYPEFLUX_IOS_CONFIGURATION must be Debug or Release.")
    if command == "preview" and configuration != "Debug":
        raise CLIError("Offline preview requires Debug. Use TYPEFLUX_IOS_CONFIGURATION=Debug make ios-preview.")
    derived_data = repository_path(os.environ.get("TYPEFLUX_IOS_DERIVED_DATA", ""), REPOSITORY_ROOT / ".xcode-ios-derived")
    team = signing_team() if command in ("deploy", "archive") else ""
    device_id = os.environ.get("TYPEFLUX_IOS_DEVICE", "")
    if command == "deploy" and not re.fullmatch(r"(?:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{40})", device_id):
        raise CLIError(
            "Set TYPEFLUX_IOS_DEVICE to the physical iPhone/iPad UDID shown by "
            "xcrun xctrace list devices (not the CoreDevice UUID). Run make ios-devices."
        )
    archive_path = repository_path(
        os.environ.get("TYPEFLUX_IOS_ARCHIVE_PATH", ""), derived_data / "archives/TypefluxIOS.xcarchive",
    )
    if command == "archive" and (archive_path.exists() or archive_path.is_symlink()):
        raise CLIError("Archive already exists: {}. Choose a new TYPEFLUX_IOS_ARCHIVE_PATH.".format(archive_path))
    developer = preflight(command)
    if command == "doctor":
        simulator()
        print("Ready for make ios-run or make ios-preview. Physical device UDIDs: xcrun xctrace list devices.")
        return
    if command == "devices":
        run(["xcrun", "simctl", "list", "devices", "available"])
        print("Connected devices (CoreDevice UUIDs below are not Xcode destination UDIDs):", flush=True)
        run(["xcrun", "devicectl", "list", "devices"])
        print("Physical UDIDs for TYPEFLUX_IOS_DEVICE are shown in the Devices section below:", flush=True)
        run(["xcrun", "xctrace", "list", "devices"])
        return
    if command in ("deploy", "archive"):
        print("Automatic signing may update development profiles using your Xcode account.", flush=True)
        if command == "archive":
            archive_path.parent.mkdir(parents=True, exist_ok=True)
            arguments = build_arguments("Release", "generic/platform=iOS", derived_data, api_url, team)
            run(arguments + ["-archivePath", str(archive_path), "archive"])
            print("Archive created: {}. Open it in Xcode Organizer to export or distribute; nothing was uploaded.".format(archive_path))
            return
        print("Xcode may register the explicitly selected device with your developer team.", flush=True)
        run(build_arguments(configuration, "platform=iOS,id=" + device_id, derived_data, api_url, team)
            + ["-allowProvisioningDeviceRegistration", "build"])
        app_path = derived_data / "Build/Products" / (configuration + "-iphoneos") / "TypefluxIOS.app"
        identifier = bundle_identifier(app_path)
        run(["xcrun", "devicectl", "device", "install", "app", "--device", device_id, str(app_path)])
        run(["xcrun", "devicectl", "device", "process", "launch", "--terminate-existing", "--device", device_id, identifier])
        return
    device = simulator()
    device_id = device["udid"]
    run(build_arguments(configuration, "platform=iOS Simulator,id=" + device_id, derived_data, api_url) + ["build"])
    app_path = derived_data / "Build/Products" / (configuration + "-iphonesimulator") / "TypefluxIOS.app"
    if command == "build":
        print("Built app: " + str(app_path))
        return
    identifier = bundle_identifier(app_path)
    run(["xcrun", "simctl", "bootstatus", device_id, "-b"])
    run(["xcrun", "simctl", "install", device_id, str(app_path)])
    if command == "install":
        print("Installed {} on {}.".format(identifier, device["name"]))
        return
    simulator_app = developer / "Applications/Simulator.app"
    application = str(simulator_app) if simulator_app.exists() else "Simulator"
    if application == "Simulator":
        print("Simulator.app is not visible under the selected Xcode path; using the registered Simulator application.", flush=True)
    run(["open", "-a", application, "--args", "-CurrentDeviceUDID", device_id])
    arguments = ["xcrun", "simctl", "launch", "--terminate-running-process", device_id, identifier]
    if command == "preview":
        arguments.extend(["--synthetic-preview", "--synthetic-rich"])
    run(arguments)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""Commands:
  doctor    Check macOS, full Xcode 26+, SDKs, tools, and simulator readiness.
  devices   List simulators, connected devices, and physical device UDIDs.
  build     Build for the selected simulator without installing or booting it.
  install   Build, boot if needed, and install on the selected simulator.
  run       Install and launch the normal app in Simulator.
  preview   Install and launch the Debug-only offline rich conversation preview.
  deploy    Build, install, and launch on a connected physical iPhone or iPad.
  archive   Create a signed local Release .xcarchive; does not upload it.

Environment:
  TYPEFLUX_IOS_SIMULATOR       Optional available iOS 17+ simulator UDID.
                              Default: booted iPhone, otherwise newest runtime.
  TYPEFLUX_IOS_DEVICE          Physical UDID for deploy (xctrace list devices).
  TYPEFLUX_IOS_TEAM            Apple Developer Team ID for deploy/archive.
  TYPEFLUX_IOS_CONFIGURATION   Debug (default) or Release; preview needs Debug.
  TYPEFLUX_IOS_DERIVED_DATA    Build directory; default: .xcode-ios-derived.
  TYPEFLUX_IOS_ARCHIVE_PATH    New archive path; default: build directory's
                              archives/TypefluxIOS.xcarchive. Never overwritten.
  TYPEFLUX_API_URL             Optional HTTPS API base URL without credentials,
                              query, or fragment. Default: project setting.
Relative paths are resolved from the repository root, regardless of shell cwd.
See docs/IOS_QUICKSTART.zh-CN.md for setup and troubleshooting.
""",
    )
    parser.add_argument("command", choices=COMMANDS)
    arguments = parser.parse_args(argv)
    try:
        execute(arguments.command)
    except (CLIError, OSError, ValueError) as error:
        print("Error: {}".format(error), file=sys.stderr)
        return 1
    except subprocess.CalledProcessError as error:
        print("Command failed (exit {}): {}".format(error.returncode, shlex.join(error.cmd)), file=sys.stderr)
        if error.stdout:
            print(error.stdout, file=sys.stderr)
        if error.stderr:
            print(error.stderr, file=sys.stderr)
        print("See docs/IOS_QUICKSTART.zh-CN.md for Xcode, signing, and device troubleshooting.", file=sys.stderr)
        return error.returncode if 0 < error.returncode < 126 else 1
    except KeyboardInterrupt:
        print("Cancelled.", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
