# GUL-199: screenshot review and optimization

The review uses the 39 simulator screenshots captured at `dce6d743` as its
baseline. The changes retain the Mac Ask colour drop, model/effort flow, message
hierarchy, and iOS navigation. Screenshot contents are offline fixtures.

## Findings and implementation plan

| Priority | Evidence | Problem | Change and acceptance criterion |
| --- | --- | --- | --- |
| P1 | `qa-stream-progress`, `qa-markdown-table` | Scrolled text shows through behind the conversation title and status. | Give the navigation bar an opaque theme background; verify long replies in both appearances. |
| P1 | `qa-stream-stopped` | A deliberate stop appears as a red failure, with English text in Chinese UI. | Present cancellation as localized neutral status, keep the partial answer, and reserve error styling for failures. |
| P1 | `qa-history-search` plus history collapse code | Collapsed date groups can hide search matches. | Reveal matching groups during a query without changing the user's saved collapse state; verify clear-search restores the prior grouping. |
| P1 | `v3-zh-keyboard-models` | The full welcome screen is bottom anchored into a short keyboard viewport; its orb and heading collide with the navigation area. | Hide the welcome content while composing or in a short landscape viewport; keep composer and model controls reachable. |
| P1 | `v3-landscape-keyboard-last-model` | The app-window screenshot has a rotated/cropped canvas with black space. | Capture the simulator screen and assert its displayed orientation matches the UI; retake the actual landscape layout. |
| P2 | `qa-stream-completed`, `qa-history-photo-dark` | Enabled copy/quote icons look disabled. | Increase action contrast, distinguish copy success, and retain real disabled semantics. |
| P2 | `qa-markdown-table`, `qa-markdown-code` | Wide content is clipped without a visible indication that more exists horizontally. | Add localized horizontal-scroll hints only when content overflows. |
| P2 | `qa-photo-model-restriction`, `v3-reasoning` | Incompatible-model text is faded twice; the effort heading is slightly off-centre. | Keep the unselectable model and its reason readable; use symmetric header controls. |
| P2 | `qa-login` | Placeholder-only inputs lose their labels once filled; Return does not advance or sign in. | Keep field labels visible and implement Email Next → Password Go, with input protected while signing in. |
| P2 | `qa-history-groups`, `qa-history-search` | Only the small gear opens settings, and search has no explicit keyboard submission behavior. | Make the whole account footer a settings target; dismiss search keyboard on submit or scrolling. |

Implementation is grouped into chat reading/status, model/keyboard layout, and
history/login tasks. Verification follows integration: focused behavior tests,
the complete iOS unit/UI suite, Release build, formatting/lint, and visual review
of fresh screenshots. No backend contract or account-management capability is
expanded in this pass.

## Validation results

Validated on 2026-10-04 with Xcode 27 / Swift 6.4 and an iPhone 17 Pro simulator
running iOS 26.5. The deployment target remains iOS 17.

| Check | Result |
| --- | --- |
| Complete iOS unit suite | 107 passed |
| Complete iOS UI suite | 17 flows passed, no failures or skips |
| Historical-photo framing follow-up | The affected flow passed again after adding full-image viewport assertions |
| iOS production line coverage | 97.81% (5313/5432), excluding only the DEBUG fixture |
| Complete app target line coverage | 97.84% (5668/5793), including the DEBUG fixture |
| Release simulator build | Passed |
| SwiftFormat, strict SwiftLint, localization plists, diff whitespace | Passed |
| Updated screenshots | 42 unchanged native PNGs; 8 before/after pairs in the issue attachment |

Coverage is from `xccov` on the final complete unit/UI run, not pure-unit-only
or branch coverage. The production sources did not change after that run.
The photo test subsequently gained stricter framing assertions and passed a
focused rerun. No shared-package, macOS, backend, or project build-setting code
changed in this pass; their previous results are recorded in the baseline report.

The added tests verify neutral cancellation versus actionable failures, width
overflow including rotation/initial geometry, and disabled model text retaining
its color in light/dark appearances. UI regressions verify searching collapsed
groups without losing the user's grouping preference, full-footer settings
access, persistent login labels, and Next/Go keyboard actions.

Visual review confirmed a clear navigation title, visible horizontal-scroll
hints, readable model restriction reasons, neutral localized stop text, and
correct landscape framing without the old black/cropped canvas. The old app
window capture was replaced by `XCUIScreen.main.screenshot()` with an orientation
assertion. The history-photo capture also now checks the entire image lies
between the navigation bar and composer; `isHittable` alone did not prove that.

The [screenshot index](../images/ios/verification/README.md) records each source
test and attachment export. Forty images come from `ios-polish-final.xcresult`;
the two historical-photo/model-restriction captures come from the passing
`ios-polish-photo.xcresult` follow-up. The issue includes a self-contained gallery
and a before/after comparison using original PNG bytes.

Reproduction: run `scripts/test_ios.sh` with a concrete simulator destination
and `TYPEFLUX_IOS_TEST_RESULT_BUNDLE_PATH`; export using `xcrun xcresulttool export
attachments`. Release uses `xcodebuild build -configuration Release -project
Apps/iOS/TypefluxIOS.xcodeproj -scheme TypefluxIOS -destination 'generic/platform=iOS
Simulator'`. The focused recapture selects
`TypefluxIOSUITests/ChatVerificationTests/testHistoricalPhotoRendersAndPreventsTextOnlyModel`.

## Deferred improvements

Image zoom and a structured quote preview could improve long-image inspection
and long quotations. They require additional interaction design beyond these
specific fixes. Very large transcript layout performance, real accounts/models,
physical devices, and the minimum iOS 17 runtime remain separate validation gaps.
