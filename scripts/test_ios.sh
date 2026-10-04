#!/usr/bin/env bash
set -euo pipefail

repository_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
destination="${TYPEFLUX_IOS_TEST_DESTINATION:-}"
derived_data_dir="$repository_dir/.xcode-ios-derived"
result_bundle_path="${TYPEFLUX_IOS_TEST_RESULT_BUNDLE_PATH:-}"

simulator_id="$(xcrun simctl list devices available --json | python3 -c '
import json
import sys
import uuid

devices = json.load(sys.stdin)["devices"]
available = [device for runtime, group in devices.items() if "iOS" in runtime
             for device in group if device.get("isAvailable", False)]
destination = sys.argv[1]
if destination:
    fields = dict(part.strip().split("=", 1) for part in destination.split(",") if "=" in part)
    identifier = fields.get("id", "")
    try:
        uuid.UUID(identifier)
    except ValueError:
        sys.exit("TYPEFLUX_IOS_TEST_DESTINATION must include a concrete simulator UDID: "
                 "platform=iOS Simulator,id=<UDID>. Names and id=booted are not supported.")
    if fields.get("platform") != "iOS Simulator":
        sys.exit("TYPEFLUX_IOS_TEST_DESTINATION must use platform=iOS Simulator.")
    if not any(device["udid"].lower() == identifier.lower() for device in available):
        sys.exit("The requested iOS simulator is not available. Check xcrun simctl list devices available.")
    print(identifier)
    sys.exit(0)

phones = [device for device in available if device["name"].startswith("iPhone")]
if not phones:
    sys.exit("No available iPhone simulator. Install an iOS runtime in Xcode Settings.")
phones.sort(key=lambda device: device.get("state") != "Booted")
print(phones[0]["udid"])
' "$destination")"
if [[ -z "$destination" ]]; then
    destination="platform=iOS Simulator,id=$simulator_id"
fi

result_arguments=()
if [[ -n "$result_bundle_path" ]]; then
    if [[ -e "$result_bundle_path" ]]; then
        echo "Result bundle already exists: $result_bundle_path. Choose a new path or remove it explicitly." >&2
        exit 1
    fi
    mkdir -p "$(dirname "$result_bundle_path")"
    result_arguments=(-resultBundlePath "$result_bundle_path")
fi

build_arguments=(
    -project "$repository_dir/Apps/iOS/TypefluxIOS.xcodeproj"
    -scheme TypefluxIOS
    -configuration Debug
    -destination "$destination"
    -derivedDataPath "$derived_data_dir"
    -enableCodeCoverage YES
    -parallel-testing-enabled NO
)

xcodebuild build-for-testing "${build_arguments[@]}"

# PhotosPicker needs a real library asset. Generate it inside the DEBUG-only,
# network-free fixture app instead of relying on the simulator image catalogue.
xcrun simctl bootstatus "$simulator_id" -b
app_path="$derived_data_dir/Build/Products/Debug-iphonesimulator/TypefluxIOS.app"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Info.plist")"
xcrun simctl install "$simulator_id" "$app_path"
app_data_dir="$(xcrun simctl get_app_container "$simulator_id" "$bundle_id" data)"
photo_path="$app_data_dir/Library/Caches/synthetic-photo.jpg"
# Require this build to regenerate the fixture; a stale file must not hide a failure.
mkdir -p "$(dirname "$photo_path")"
rm -f "$photo_path"

fixture_running=false
cleanup_fixture() {
    if [[ "$fixture_running" == true ]]; then
        xcrun simctl terminate "$simulator_id" "$bundle_id" >/dev/null 2>&1 || true
    fi
}
trap cleanup_fixture EXIT
xcrun simctl launch --terminate-running-process "$simulator_id" "$bundle_id" \
    --synthetic-preview --synthetic-rich
fixture_running=true
for ((attempt = 0; attempt < 100; attempt++)); do
    if [[ -s "$photo_path" ]]; then
        break
    fi
    sleep 0.2
done
if [[ ! -s "$photo_path" ]]; then
    echo "The offline preview did not export its PhotosPicker fixture within 20 seconds: $photo_path" >&2
    exit 1
fi
xcrun simctl terminate "$simulator_id" "$bundle_id"
fixture_running=false
xcrun simctl addmedia "$simulator_id" "$photo_path"

# Keep the same simulator so the seeded Photos library is used by the UI tests.
# The optional result bundle contains the tests and their coverage, not the build step.
xcodebuild test-without-building "${build_arguments[@]}" ${result_arguments[@]+"${result_arguments[@]}"}
