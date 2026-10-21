## iOS app icon switching

Settings → General → App icon offers the existing iOS default plus all 11 macOS styles. The primary iOS icon differs from macOS's frosted glass artwork, so both are separate choices. iOS owns the selection and its persistence; no account setting or extra UserDefaults value is written.

The controller serializes changes, ignores unsupported or redundant requests, reads the actual system state after completion, and reports failures without selecting an icon prematurely. The selector has English/Chinese labels, selection accessibility traits, progress feedback and a failure alert. Asset generation is reproducible with `swift scripts/generate_ios_app_icons.swift`; the script reuses desktop artwork and creates opaque square assets and matching previews.

## Focused validation

Environment: Xcode's iPhone 17 Pro simulator, iOS 26.5. Commands below used `-project Apps/iOS/TypefluxIOS.xcodeproj -scheme TypefluxIOS -derivedDataPath .xcode-ios-derived`. Test commands used Debug, `-enableCodeCoverage YES -parallel-testing-enabled NO` and `-destination 'platform=iOS Simulator,id=1415C442-DE9B-4F38-823D-1CAF69BB9926'`. Subsequent commands also used `-collect-test-diagnostics never`.

| Run | Scope | Result | Total wall time |
| --- | --- | --- | --- |
| Initial build and coverage | `ChatAppIconTests`, `ChatPreferencesTests`, `ChatPolishTests/testAppIconSettingsShowAllStylesInBothLanguages`, `ChatPolishTests/testEnglishSettingsAndAccountHaveCompactRows` | Settings preferences (7) and both UI tests passed; icon catalog test failed on an obsolete requirement for loose `CFBundleIconFiles`. Four controller tests passed. | 208.88 s |
| Icon catalog and new UI coverage | `ChatAppIconTests`, both new icon UI methods | Bilingual 12-choice layout passed. Catalog test needed raw plist access for device-qualified keys; native test needed to acknowledge SpringBoard's confirmation. | 85.41 s |
| Smallest affected suite and native UI retry | `ChatAppIconTests`, `ChatPolishTests/testAppIconChangeUsesSystemResult` | All 5 icon unit tests passed. Native change and relaunch persistence passed; the restoration assertion ran before the asynchronous completion and failed. | 40.18 s |
| Native UI retry | `ChatPolishTests/testAppIconChangeUsesSystemResult` | Passed, including real system change, confirmation, persistence after relaunch, and restoration. | 36.66 s |
| Device Release build | `xcodebuild build -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO` | Passed. | 24.16 s |

The initial failure triggered slow simulator diagnostic collection; only that run's `simctl diagnose` child was stopped after the tests finished. Test results and coverage were preserved. Test fixes added raw plist inspection, support for asset-name declarations and explicit waits for native confirmation/completion. Production behavior did not require a workaround.

All 15 distinct selected tests passed across the focused runs. No full test suite was run. `ChatAppIconTests` covers state transitions, default restoration, persistence, unsupported devices, duplicate requests, failures/retries, concurrent requests and all bundled previews/declarations. `ChatPreferencesTests` and the existing settings UI method cover the directly affected settings flow. The two new UI methods cover language/layout and the actual system API flow.

Merged `xccov` coverage for the unchanged production files in the last unit/native runs is recorded in `coverage.json`: `ChatAppIcon.swift` 55/55 executable lines (100%); `ChatAppIconView.swift` 150/162 (92.6%). Combined new production-file coverage is 205/217 (94.5%); these are changed-file figures, not project-wide coverage. The native adapter was exercised successfully. The unsupported-device/error UI branches are covered at the controller level with a fake application.

Additional checks passed: focused `swiftlint lint --strict --quiet`, `git diff --check`, `plutil -lint` for the project/localizations, and raw built plist plus `assetutil --info` checks in both Debug simulator and Release device products. Both iPhone and iPad dictionaries declare the exact 11 alternate names, and all 11 exist in each compiled asset catalog. All alternate source PNGs are opaque 1024×1024 images.

## Self-review

Reviewed the settings entry through the native callback, restore-default behavior, unknown/system selections, asynchronous failures, repeated taps, foreground refresh, actor isolation, account independence, asset/preview correspondence, both build configurations and translations. Fixed the default-versus-frosted-glass distinction found during visual review. No new network access, credentials, persistent tasks, handles or authorization boundaries are introduced.

Screenshots were visually checked in English/light, Chinese/light and English/dark; the system confirmation also shows the actual home-screen result. Physical-device interaction and signed App Store archive validation were not run; Release compilation and packaging were checked without signing.
