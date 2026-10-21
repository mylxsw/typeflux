## iOS connection notices and model presentation

The conversation's connection banner can be dismissed for 24 hours, including
across app launches. Its expiry schedules a single UI refresh. The sidebar no
longer repeats the banner. Send failures still explain the failure and keep the
draft. Private models show “Not supported” for reasoning effort, and their
composer button no longer includes a lock.

Provider editing puts the saved-key explanation below the secure input and gives
model visibility and image support separate native Form rows. These rows have
independent hit targets. The model registry evaluation is in
`docs/design/model-capability-registry.md`; a registry/update service is not part
of this implementation.

## Validation

All test commands used `xcodebuild test -project Apps/iOS/TypefluxIOS.xcodeproj
-scheme TypefluxIOS -destination 'platform=iOS Simulator,id=1415C442-DE9B-4F38-823D-1CAF69BB9926'
-derivedDataPath .xcode-ios-derived -enableCodeCoverage YES -parallel-testing-enabled NO`
with the scopes below. Retries also used `-collect-test-diagnostics never`.

| Scope (`-only-testing:`) | Result | Total command wall time |
| --- | --- | --- |
| `TypefluxIOSTests/ChatOfflineTests`, `TypefluxIOSTests/ChatVisualComponentsTests`, `TypefluxIOSUITests/ChatFlowTests/testUnifiedModelEffortPickerAndModelCapabilities` | 37 unit tests and 1 UI test passed, including initial compilation. | Approximately 48 s, from command-log creation to completion. |
| `TypefluxIOSTests/ChatOfflineTests`, `TypefluxIOSUITests/ChatPolishTests/testConnectionDismissalAndProviderLayout` | 22 unit tests passed; UI test exposed insufficient switch spacing. | 27.94 s |
| `TypefluxIOSUITests/ChatPolishTests/testConnectionDismissalAndProviderLayout` | Spacing passed; independent switch interaction failed with nested toggles. | 20.85 s |
| Same UI method | Separate Form rows fixed interaction layout; test incorrectly demanded an 8 pt gap between whole-row accessibility frames. | 24.57 s |
| Same UI method | Passed in English and Chinese, including dismissal, absent sidebar banner, private-model effort text, key help placement, nonoverlapping rows and independent image toggle interaction. | 49.48 s |

All 39 distinct selected tests passed across these runs. The unit tests cover
24-hour boundary/expiry, persistence, backward clock changes, authentication,
reconnection, synthetic preference isolation and preserving send errors. Existing
offline suites cover drafts, provider storage and failure handling; visual and
picker tests cover their directly affected callers. No full macOS/iOS suite ran.

Changed executable-line coverage is **71/77 (92.2%)**, recorded in `coverage.json`.
The dismissal logic is **12/12 (100%)**. Coverage uses the final UI archive for
view files and the 22-test unit archive for unchanged store sources. These are
changed-line figures, not project-wide coverage. The six uncovered lines are the
existing retry/progress branches moved into the banner helper.

`git diff --check` and `plutil -lint` for both localizations passed. Focused
`swiftlint lint --strict --quiet` exits 2 on existing violations: the offline
test suite exceeds the configured type length, alongside pre-existing warnings.
Comparing the same files from HEAD with the final versions found no increased
counts for any lint rule. The store's intentionally large type now has a scoped
type-length suppression. No unrelated lint cleanup was performed.

## Self-review

Reviewed dismissal through persistence and scheduled expiry, authentication and
network transitions, request failures, private-model request capability, secure
field behavior, localization, independent switch bindings, and async retry
lifetime. The UI checks caught the nested-toggle layout/hit-target problem;
separate native Form rows fixed it. Tests use isolated preferences for writes;
synthetic UI launches neither read nor write the real dismissal preference.
No credentials are included in logs or screenshots. No new network requests,
background loops, handles or authorization paths were introduced.

Visually inspected the six accompanying simulator screenshots in both languages.
Physical-device, signed Release and large Dynamic Type validation were not run.
