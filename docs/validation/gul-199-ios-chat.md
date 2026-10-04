# GUL-199: initial iOS Ask implementation

Validated on 2026-10-04 with Xcode 27.0 / Swift 6.4 and an iPhone 17 Pro simulator
running iOS 26.5. The iOS deployment target remains 17.0. These checks do not
establish behavior on physical devices or with a production account.

| Check | Result |
| --- | --- |
| Shared package tests, complete concurrency checking | 23 tests passed |
| Shared package production line coverage | 98.15% |
| `scripts/test_ios.sh` | 37 unit tests and 3 UI flows passed |
| iOS production line coverage, excluding DEBUG synthetic fixture | 93.40% (1556/1666 lines) |
| iOS Xcode app target coverage, including synthetic fixture | 93.60% |
| iOS chat state coverage | 97.37% |
| iOS Release simulator build | Passed |
| Final Mac focused regression | 68 tests passed (33 XCTest + 35 Swift Testing) |
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
branch rerun. Their full-suite instability remains unexplained. The final
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
