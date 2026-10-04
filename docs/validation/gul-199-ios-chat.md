# GUL-199: iOS Ask validation

Validated on 2026-10-04 with Xcode 27.0 / Swift 6.4 and an iPhone 17 Pro simulator
running iOS 26.5. The iOS deployment target remains 17.0. These checks do not
establish behavior on physical devices or with a production account.

For the subsequent screenshot-driven optimization pass, see the
[review, implementation plan, and current results](gul-199-ios-polish.md).
The measurements below remain the pre-optimization baseline.

## Initial implementation baseline

These results were recorded before the v3 UI revision. Current revision results
are listed in the next section.

| Check | Result |
| --- | --- |
| Shared package tests, complete concurrency checking | 23 tests passed |
| Shared package production line coverage | 98.15% |
| `scripts/test_ios.sh` | 37 unit tests and 3 UI flows passed |
| iOS production line coverage, excluding DEBUG synthetic fixture | 93.40% (1556/1666 lines) |
| iOS Xcode app target coverage, including synthetic fixture | 93.60% |
| iOS chat state coverage | 97.37% |
| iOS Release simulator build | Passed |
| Initial implementation Mac focused regression | 68 tests passed (33 XCTest + 35 Swift Testing) |
| Project plist, shared scheme XML, CI YAML, shell syntax, diff whitespace | Passed |

The unit tests exercise account isolation, concurrent 401 refresh, refresh-token
rotation after caller cancellation, stable UUID device identity, actual Keychain
round trips, images, message-size/model validation, send reconciliation, model
changes after failure, stale responses, normal stream EOF, and bounded network
failure recovery. Real UUID request paths and server pricing metadata have
separate wire-contract tests.

UI tests use `--synthetic-preview` and an in-memory service. They verify reading
and continuing a conversation, switching models, creating a conversation,
sign-out/sign-in validation, returning from the background, and viewing/stopping
a desktop-tool run. Screenshots in `docs/images/ios` use these synthetic fixtures.

## Mac-aligned UI implementation

The approved v3 design is implemented in SwiftUI, using the current Mac Ask
components at `2336355e` as the visual and interaction reference:

- The 88-point colour drop uses the Mac's 48-point closed curve, eight-second
  gradient flow, subtle breathing, and matching-colour glow. Reduce Motion
  renders a still frame.
- One composer model entry opens the 272-point reasoning card. Its subtitle
  opens the 330-point cloud model list; selection returns to the reasoning card.
  Auto uses a dashed knob without fill, reset restores Auto, and the highest
  supported level is purple. A change in available levels picks the nearest
  supported one and explains the adjustment.
- Model rows show the leading selection check, vision support, context/output
  capacity, and validated credit multiplier. Current or historical photos
  prevent switching to a text-only model. Busy runs disable model changes.
- User bubbles, plain assistant replies, collapsible reasoning, grouped tool
  steps, neutral stop, single-line history, date groups, and the account footer
  follow the Mac hierarchy. Tool execution remains on the originating device.
- iOS keeps native navigation and popover presentation, 44-point composer/action
  targets, keyboard avoidance, light/dark appearance, and English/Chinese text.
  In short viewports, the entire selector scrolls so its last model stays
  reachable. Markdown tables and code scroll horizontally.

Coverage below is for the complete iOS production target, excluding only the
DEBUG synthetic service; it is not branch coverage or a per-file minimum.
The shared package measurement excludes its test sources. UI tests use the
network-free synthetic service and do not prove live model integration.

| Earlier v3 check | Result |
| --- | --- |
| Shared package tests | 33 passed |
| Shared production line coverage | 97.91% (374/382 lines) |
| iOS unit tests | 82 passed |
| iOS UI flows, portrait and landscape | 6 passed |
| iOS production line coverage, excluding DEBUG synthetic fixture | 92.62% (4140/4470 lines) |
| iOS target coverage, including fixture | 92.74% (4269/4603 lines) |
| iOS chat state coverage | 98.18% (538/548 lines) |
| iOS Release simulator build | Passed |
| Mac shared compatibility, Ask HTTP/SSE and auth regression | 58 passed (32 XCTest + 26 Swift Testing) |
| iOS SwiftFormat and strict SwiftLint | Passed |
| Project/localization plists and diff whitespace | Passed |

Commands: `swift test --package-path Packages/TypefluxChat --enable-code-coverage`;
`xcodebuild test -project Apps/iOS/TypefluxIOS.xcodeproj -scheme TypefluxIOS
-destination 'platform=iOS Simulator,id=<UDID>' -enableCodeCoverage YES
-parallel-testing-enabled NO`; `xcodebuild build -configuration Release
-project Apps/iOS/TypefluxIOS.xcodeproj -scheme TypefluxIOS
-destination 'generic/platform=iOS Simulator'`; `swift test --filter
'SharedChatCompatibilityTests|AskAPIClientTests|AskStreamTests|AuthModelsTests'`.
Coverage is from the shared LLVM JSON report and `xccov` for the final iOS test
result. The full Mac suite was not repeated for the UI revision; the known
baseline failures below remain unresolved.

The new regression cases cover model capability decoding, omitted Auto request
parameters, nearest supported levels, pending-request identity after an effort
change, historical-photo restrictions, initial conversation load failure,
background refresh, date/search boundaries, tool-call/result grouping, and
Markdown parsing. UI flows exercise quote-and-send, model/effort/Auto changes,
non-reasoning models, search/date-group expansion, login validation, foreground
recovery, cancellation, Chinese dark appearance, and reaching the last model
with the keyboard open in landscape. Rendering tests cover reduced motion and
transparency, slider geometry, theme contrast hierarchy, and constrained cards.

## Chat, settings, and account verification

The follow-up audit exercises the actual shipped views and `ChatStore` with a
DEBUG-only in-memory service. Shared HTTP/SSE contract tests use URLProtocol.
These are client and protocol checks, not live backend/model validation.

The audit found and fixed four functional issues:

- Current Mac photos are carried in `attachments[].image`; the mobile projection
  previously read only legacy `message.image`. Both shapes now render and keep
  text-only models disabled when photos exist.
- Late successful sends or reconciliation responses could clear a newer draft
  or image. Only the submitted values are cleared now; account/conversation
  isolation still rejects stale responses.
- Switching appearance could trap when UIKit resolved dynamic colors on a
  background queue. All custom providers are explicitly Sendable, with a test
  resolving all 12 colors off the main actor in both appearances.
- Scrolling the long rich-message fixture could saturate the main thread in
  SwiftUI lazy placement/scroll-offset updates. Exact `VStack` layout of the
  loaded snapshot removes that loop. This trades lazy per-message layout for
  stable scrolling; very large conversation rendering has not been benchmarked.
  Long streamed output still follows the latest text and reaches the final actions.

Settings now includes a persistent System/Light/Dark preference, the system
language-settings entry, version, and the existing privacy-policy link. Account
shows the current email and signed-in state, with explicit cancel/confirm
sign-out. Registration, password reset, subscription controls, and account
removal are not implemented. No profile data or balance is fabricated.

Visual corrections also cover a continuous background beneath the composer and
bottom safe area, and a visible selected appearance in dark mode.

| Flow | Client checks |
| --- | --- |
| Conversation lifecycle | New chat, loaded history, date groups, pagination, search and follow-up |
| Sending and streaming | Text, successive stream stages, output longer than the viewport, completion and another turn |
| Failure and cancellation | Error remains readable, follow-up clears the old run, stop preserves partial output |
| Rich responses | Headings, lists, quotes, complete table and horizontal scroll, code copy, folded reasoning, quote into draft |
| Tools | Folded activity, result/argument switching, waiting for the Mac, cancellation |
| Images | Native PhotosPicker, preview, remove, reselect, send, Mac attachment display, model capability restriction |
| Models | Unified model/effort card, Auto/reset, supported level adjustment, no-reasoning models, keyboard and landscape |
| Settings and account | Light/dark persistence across relaunch, return to System, email/status, cancel/confirm sign-out, login validation |

Screenshots are exported unchanged from Xcode UI-test attachments. The final
screenshot index is in `docs/images/ios/verification/README.md`; a self-contained
HTML gallery is attached to GUL-199. All account, model, tool, and response
contents in these screenshots are explicitly synthetic fixtures.

| Final follow-up check | Result |
| --- | --- |
| Shared package tests / production line coverage | 35 passed / 97.95% (383/391) |
| iOS unit tests | 103 passed |
| iOS UI flows, including portrait and landscape | 15 passed |
| iOS production line coverage, excluding DEBUG fixture | 97.68% (5020/5139) |
| iOS complete target line coverage | 97.73% (5375/5500) |
| ChatStore line coverage | 98.92% (552/558) |
| iOS Release simulator build | Passed |
| Mac shared compatibility, Ask HTTP/SSE and auth regression | 58 passed (32 XCTest + 26 Swift Testing) |
| SwiftFormat, strict SwiftLint, project/localization plists, scheme XML, shell syntax, diff whitespace | Passed |
| Native screenshots from the final passing run | 39 |

The complete final iOS run used `scripts/test_ios.sh` with
`TYPEFLUX_IOS_TEST_RESULT_BUNDLE_PATH` set. Coverage comes from `xccov` across
that combined unit/UI run, excluding only `SyntheticPreview.swift`; it is not
branch coverage, pure-unit-only coverage, or a per-file minimum. Screenshots
were exported with `xcrun xcresulttool export attachments`. Shared coverage uses
the package's LLVM coverage report. The earlier failing attempts led to the
fixes above; the final run has no skipped or failing iOS tests.

A real account, production model responses, physical devices, the minimum iOS
17 runtime, and very large-history performance have not been validated. The
full Mac suite was not repeated; its previously documented failures remain.

## Existing macOS full-suite failures

`make coverage` ran 2816 XCTest cases and 870 Swift Testing cases, but did not
pass. Its reporting script stops before generating the HTML report when tests
fail. This is not reported as a green full Mac regression run.

An isolated, unchanged checkout of `origin/main` at
`2336355eac0e77aa5027c2eef28602587735f9b5`, with the same dependency lockfile,
reproduced these failures in a focused run:

- `AskArtifactToolTests.testNativePreviewsHandleTruncationBinaryUnsupportedMimeAndBoundedImages`
- `WorkflowControllerProcessingTests.testOpeningPersonaPickerDoesNotPlayCue`
- `WorkflowControllerProcessingTests.testOpeningPersonaPickerDoesNotPlayCueWhenSoundEffectsAreDisabled`
- `AskConversationWindowSizingTests.supportedNarrowAndShortViewportsRemainAtTheRequestedSize`
- `AskCappedWidthTests.shortModelNameHugsItsText`
- `AskComposerResponsiveTests.narrowQueuedEditKeepsVoiceSaveAndCancelReachable`
- `AskComposerInteractionTests.windowMouseEventsHoldRecordAndReleaseTranscribeInBothComposers`

The artifact preview assertion compared backing pixels with layout points. This
change makes that test compare the bitmap with `convertToBacking(view.bounds)`
on both Retina and non-Retina displays. Other unrelated Mac interaction/layout
failures remain outside this implementation.

Three additional full-run failures (`accountNameClickTogglesTheAccountCard`,
`composeButtonStartsANewChatInBothSidebarStates`, and the completed-conversation
recovery render) passed both the isolated baseline check and the final current
branch rerun. Their full-suite instability remains unexplained. That
68-test run also passed the fixed artifact preview, shared/Mac wire compatibility,
Ask HTTP/SSE, authentication decoding, endpoint resolution, and recovery rendering.

## Backend validation and rollout

The companion API PR is [typeflux-api#108](https://github.com/mylxsw/typeflux-api/pull/108).
Its full Go tests with PostgreSQL and all 40 required PostgreSQL race-gate cases
passed without skips. Ask coverage is 94.9%, changed executable blocks 100%, and
repository coverage 85.2%. The approved repository floor is 80%; the strict 90%
repository target is still unmet.

Deploy the backend platform/tool contract before enabling cross-device
regeneration. This initial iOS client only sends new turns and does not expose
regeneration or retry. Live account/model integration, physical-device checks,
distribution signing, and App Store release have not been performed.
