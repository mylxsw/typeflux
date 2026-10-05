#!/usr/bin/env python3
"""Build and launch the iOS client using the selected local Xcode installation."""

import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shlex
import shutil
import ssl
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
MIN_XCODE_VERSION = 26
MIN_IOS_VERSION = 17
COMMANDS = ("doctor", "devices", "build", "install", "run", "start", "preview", "deploy", "archive")


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


def local_development_host(host):
    if host == "localhost" or (host.endswith(".local") and len(host) > 6):
        return True
    try:
        address = ipaddress.ip_address(host)
        return address.is_loopback or address.is_link_local or any(
            address in ipaddress.ip_network(network)
            for network in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "fc00::/7")
            if address.version == ipaddress.ip_network(network).version
        )
    except ValueError:
        return False


def validate_api_url(value, allow_local_http=False):
    if not value:
        return ""
    message = "TYPEFLUX_API_URL requires HTTPS, or explicitly opted-in Debug local HTTP, without credentials, query, or fragment."
    try:
        parsed = urlsplit(value)
        port = parsed.port
        if (
            (parsed.scheme != "https" and not (
                parsed.scheme == "http" and allow_local_http and parsed.hostname
                and local_development_host(parsed.hostname)
            ))
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


def available_simulators(devices):
    available = []
    for runtime, group in devices.get("devices", {}).items():
        match = re.search(r"\.iOS-(\d+(?:-\d+)*)$", runtime)
        if not match:
            continue
        version = tuple(int(part) for part in match.group(1).split("-"))
        if version[0] < MIN_IOS_VERSION:
            continue
        available.extend((version, device) for device in group if device.get("isAvailable", False))
    return available


def selected_simulator(devices, identifier=""):
    available = available_simulators(devices)
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


def physical_targets(payload):
    targets = []
    for device in payload.get("result", {}).get("devices", []):
        properties = device.get("properties", {})
        hardware = properties.get("hardware") or device.get("hardwareProperties", {})
        state = properties.get("state") or device.get("deviceProperties", {})
        connection = properties.get("connection") or device.get("connectionProperties", {})
        if (hardware.get("platform") != "iOS" or hardware.get("reality") == "simulated"
                or connection.get("pairingState") != "paired" or not hardware.get("udid")):
            continue
        targets.append({"udid": hardware["udid"], "name": state.get("name", hardware["udid"]),
                        "kind": "physical", "state": connection.get("state", connection.get("tunnelState", "paired"))})
    return sorted(targets, key=lambda device: (device["state"] != "connected", device["name"]))


def ios_targets():
    with tempfile.TemporaryDirectory(prefix="typeflux-ios-devices-") as directory:
        output = Path(directory) / "devices.json"
        run(["xcrun", "devicectl", "list", "devices", "--json-output", str(output)], capture=True)
        targets = physical_targets(json.loads(output.read_text()))
    catalog = json.loads(run(["xcrun", "simctl", "list", "devices", "available", "--json"], capture=True))
    simulators = sorted(available_simulators(catalog), key=lambda item: (item[1].get("state") == "Booted", item[0]), reverse=True)
    targets.extend(dict(device, kind="simulator") for _, device in simulators)
    return targets


def select_ios_target(targets, identifier=""):
    if identifier:
        for device in targets:
            if device["udid"].lower() == identifier.lower():
                return device
        raise CLIError("DEVICE must identify an available iOS simulator or paired iPhone/iPad. Run make ios-devices.")
    if not targets:
        raise CLIError("No iOS devices available. Connect an iPhone/iPad or create an iOS 17+ simulator in Xcode.")
    if len(targets) == 1:
        return targets[0]
    print("Available iOS devices:", flush=True)
    for number, device in enumerate(targets, start=1):
        print(f"  [{number}] {device['name']} ({device['kind']}, {device['state']}) — {device['udid']}", flush=True)
    if not sys.stdin.isatty():
        raise CLIError("Multiple iOS devices found without an interactive terminal. Set DEVICE=<UDID> from the list above.")
    while True:
        try:
            choice = input(f"Select a device [1-{len(targets)}] (q to cancel): ").strip()
        except EOFError:
            raise CLIError("Device selection cancelled.") from None
        if choice.lower() == "q":
            raise KeyboardInterrupt
        if choice.isascii() and choice.isdecimal() and 1 <= int(choice) <= len(targets):
            return targets[int(choice) - 1]
        print(f"Enter a number from 1 to {len(targets)}, or q to cancel.", flush=True)


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
    allow_http = configuration == "Debug" and urlsplit(api_url).scheme == "http"
    arguments.append("TYPEFLUX_ALLOW_INSECURE_HTTP=" + ("YES" if allow_http else "NO"))
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


def project_signing_team(configuration):
    project = REPOSITORY_ROOT / "Apps/iOS/TypefluxIOS.xcodeproj/project.pbxproj"
    payload = json.loads(run(["plutil", "-convert", "json", "-o", "-", str(project)], capture=True))
    objects = payload.get("objects", {})
    for target in objects.values():
        if target.get("isa") != "PBXNativeTarget" or target.get("name") != "TypefluxIOS":
            continue
        config_list = objects.get(target.get("buildConfigurationList"), {})
        for identifier in config_list.get("buildConfigurations", []):
            config = objects.get(identifier, {})
            if config.get("name") == configuration:
                team = config.get("buildSettings", {}).get("DEVELOPMENT_TEAM", "")
                return team if re.fullmatch(r"[A-Z0-9]{10}", team) else ""
    return ""


def apple_development_teams():
    identities = run(["security", "find-identity", "-v", "-p", "codesigning"], capture=True)
    usable = dict(re.findall(r'\b([0-9A-Fa-f]{40})\s+"((?:Apple Development|iPhone Developer|iOS Development):[^\"]+)"', identities))
    usable = {fingerprint.upper(): name for fingerprint, name in usable.items()}
    if not usable:
        return {}
    certificates = run(["security", "find-certificate", "-a", "-p"], capture=True)
    teams = {}
    for certificate in re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", certificates, re.DOTALL):
        fingerprint = hashlib.sha1(ssl.PEM_cert_to_DER_cert(certificate)).hexdigest().upper()
        if fingerprint not in usable:
            continue
        # The identity name's parenthesized suffix can be a certificate ID.
        # The certificate's subject OU is the actual Apple Developer Team ID.
        subject = subprocess.run(
            ["openssl", "x509", "-noout", "-subject", "-nameopt", "RFC2253"],
            input=certificate, check=True, text=True, capture_output=True,
        ).stdout
        match = re.search(r"(?:^|,)OU=([A-Z0-9]{10})(?:,|$)", subject.strip())
        if match:
            teams.setdefault(match.group(1), usable[fingerprint])
    return teams


def signing_team(configuration="Debug"):
    team = os.environ.get("TYPEFLUX_IOS_TEAM", "")
    if team:
        if not re.fullmatch(r"[A-Z0-9]{10}", team):
            raise CLIError("TYPEFLUX_IOS_TEAM must be your 10-character Apple Developer Team ID.")
        return team
    team = project_signing_team(configuration)
    if team:
        print(f"Using Xcode project's development team: {team}", flush=True)
        return team
    teams = apple_development_teams()
    if not teams:
        raise CLIError(
            "No usable Apple Development signing identity found. "
            "Sign in under Xcode > Settings > Accounts and enable Sign in with Apple "
            "for the app.typeflux.ios App ID, or set TYPEFLUX_IOS_TEAM explicitly."
        )
    if len(teams) == 1:
        team = next(iter(teams))
        print(f"Using development team from signing certificate: {team} ({teams[team]})", flush=True)
        return team
    choices = list(teams)
    print("Available Apple development teams:", flush=True)
    for number, team in enumerate(choices, start=1):
        print(f"  [{number}] {teams[team]} — Team ID: {team}", flush=True)
    if not sys.stdin.isatty():
        raise CLIError("Multiple development teams found without an interactive terminal. Set TYPEFLUX_IOS_TEAM=<Team ID>.")
    while True:
        try:
            choice = input(f"Select a development team [1-{len(choices)}] (q to cancel): ").strip()
        except EOFError:
            raise CLIError("Development team selection cancelled.") from None
        if choice.lower() == "q":
            raise KeyboardInterrupt
        if choice.isascii() and choice.isdecimal() and 1 <= int(choice) <= len(choices):
            return choices[int(choice) - 1]
        print(f"Enter a number from 1 to {len(choices)}, or q to cancel.", flush=True)


def execute(command, selected_device=None):
    configuration = os.environ.get("TYPEFLUX_IOS_CONFIGURATION", "Debug")
    allow_http = (command != "archive" and configuration == "Debug"
                  and os.environ.get("TYPEFLUX_ALLOW_INSECURE_HTTP", "") == "YES")
    api_url = validate_api_url(os.environ.get("TYPEFLUX_API_URL", ""), allow_local_http=allow_http)
    if command not in ("doctor", "devices", "archive") and configuration not in ("Debug", "Release"):
        raise CLIError("TYPEFLUX_IOS_CONFIGURATION must be Debug or Release.")
    if command == "preview" and configuration != "Debug":
        raise CLIError("Offline preview requires Debug. Use TYPEFLUX_IOS_CONFIGURATION=Debug make ios-preview.")
    if command == "start":
        preflight("devices")
        identifier = (os.environ.get("TYPEFLUX_IOS_TARGET") or os.environ.get("TYPEFLUX_IOS_DEVICE")
                      or os.environ.get("TYPEFLUX_IOS_SIMULATOR", ""))
        device = select_ios_target(ios_targets(), identifier)
        print(f"Selected {device['kind']}: {device['name']} ({device['udid']})", flush=True)
        return execute("deploy" if device["kind"] == "physical" else "run", selected_device=device)
    derived_data = repository_path(os.environ.get("TYPEFLUX_IOS_DERIVED_DATA", ""), REPOSITORY_ROOT / ".xcode-ios-derived")
    team = signing_team("Release" if command == "archive" else configuration) if command in ("deploy", "archive") else ""
    device_id = selected_device["udid"] if selected_device else os.environ.get("TYPEFLUX_IOS_DEVICE", "")
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
    device = selected_device or simulator()
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
    try:
        run(["open", "-a", application, "--args", "-CurrentDeviceUDID", device_id])
    except subprocess.CalledProcessError:
        print("Simulator window could not be opened; continuing to launch on the booted simulator. "
              "Open Simulator manually if it is installed.", flush=True)
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
  start     Select a physical device or simulator, then build, install and launch.
  preview   Install and launch the Debug-only offline rich conversation preview.
  deploy    Build, install, and launch on a connected physical iPhone or iPad.
  archive   Create a signed local Release .xcarchive; does not upload it.

Environment:
  TYPEFLUX_IOS_SIMULATOR       Optional available iOS 17+ simulator UDID.
                              Default: booted iPhone, otherwise newest runtime.
  TYPEFLUX_IOS_DEVICE          Physical UDID for deploy (xctrace list devices).
  TYPEFLUX_IOS_TARGET          Optional physical/simulator UDID for start (Make DEVICE).
  TYPEFLUX_IOS_TEAM            Optional team override; otherwise use the project
                              setting or usable Apple Development certificates.
  TYPEFLUX_IOS_CONFIGURATION   Debug (default) or Release; preview needs Debug.
  TYPEFLUX_IOS_DERIVED_DATA    Build directory; default: .xcode-ios-derived.
  TYPEFLUX_IOS_ARCHIVE_PATH    New archive path; default: build directory's
                              archives/TypefluxIOS.xcarchive. Never overwritten.
  TYPEFLUX_ALLOW_INSECURE_HTTP YES opts into local HTTP in Debug only.
  TYPEFLUX_API_URL             Optional HTTPS (or opted-in Debug local HTTP) API URL without credentials,
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
