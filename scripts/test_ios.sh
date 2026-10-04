#!/usr/bin/env bash
set -euo pipefail

repository_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
destination="${TYPEFLUX_IOS_TEST_DESTINATION:-}"

if [[ -z "$destination" ]]; then
    simulator_id="$(xcrun simctl list devices available --json | python3 -c '
import json
import sys

devices = json.load(sys.stdin)["devices"]
phones = [device for runtime, group in devices.items() if "iOS" in runtime
          for device in group if device.get("isAvailable", False)
          and device["name"].startswith("iPhone")]
if not phones:
    sys.exit("No available iPhone simulator. Install an iOS runtime in Xcode Settings.")
phones.sort(key=lambda device: device.get("state") != "Booted")
print(phones[0]["udid"])
')"
    destination="platform=iOS Simulator,id=$simulator_id"
fi

xcodebuild test \
    -project "$repository_dir/Apps/iOS/TypefluxIOS.xcodeproj" \
    -scheme TypefluxIOS \
    -destination "$destination" \
    -derivedDataPath "$repository_dir/.xcode-ios-derived" \
  -enableCodeCoverage YES \
  -parallel-testing-enabled NO
