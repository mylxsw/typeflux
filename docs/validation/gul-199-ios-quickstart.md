# GUL-199 iOS command validation

Validated on 2026-10-05 with Xcode 27.0 and an iPhone 17 Pro simulator running
iOS 26.5. This change adds local development commands and documentation;
application Swift sources and existing Swift tests are unchanged.

| Check | Result |
| --- | --- |
| `make ios-test-scripts` | 48 tests passed |
| New `scripts/ios.py` executable line coverage, Python stdlib `trace` | 99.6% (230/231); direct `__main__` exit is the uncovered line |
| `make ios-doctor` | SDK, Xcode, and simulator checks passed |
| `make ios-devices` | Simulator, CoreDevice, and physical UDID listings succeeded |
| `make ios-preview` | Built, installed, and launched the offline preview |
| `make ios-run` | Built, installed, and launched the normal sign-in screen |
| Invalid API URL, missing signing parameters, Release preview | Rejected before building |
| Make help, documentation links, `git diff --check` | Passed |

The simulator smoke check found that this host's selected developer directory
did not expose `Applications/Simulator.app`, although Xcode builds worked.
The launcher now prefers the selected Xcode's app when present and otherwise
uses the registered Simulator app, with a visible notice. Both paths have
unit coverage; the fallback was verified by the successful normal launch.

## Full macOS regression run

`swift test` initially reported 20 Swift Testing issues while simulator smoke
checks were also running. After those checks finished, `swift test --skip-build`
was run without concurrent simulator operations against the unchanged binary:

- XCTest: 2,825 tests, 6 skipped, 0 failures.
- Swift Testing: 897 tests in 119 suites; 5 test functions failed with 10 issues.
- Remaining failures: `shortModelNameHugsItsText`,
  `supportedNarrowAndShortViewportsRemainAtTheRequestedSize`,
  `composeButtonStartsANewChatInBothSidebarStates`,
  `narrowQueuedEditKeepsVoiceSaveAndCancelReachable`, and
  `windowMouseEventsHoldRecordAndReleaseTranscribeInBothComposers`.

These failures concern existing macOS layout and interaction tests. Their root
cause was not established in this change; the full Swift suite is not green.
The new command tests are included in the existing opt-in PR test workflow.

## Not exercised

Physical-device signing, device registration, installation, and Release archives
were tested with mocked command execution, not an Apple developer account or
connected iPhone. Live authentication and model requests were not exercised.
No app was uploaded to TestFlight or the App Store. See the
[quickstart](../IOS_QUICKSTART.zh-CN.md) for the required device and signing setup.
