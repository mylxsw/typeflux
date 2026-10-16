# GUL-399: current media chain main integration

This is a direct-main landing entry for the reviewed #536–#542 increments and the independently reviewable shared OCR increment #543. It does not merge GitHub PRs. #543 remains the focused OCR review; it does not need a separate merge before this integration PR.

## Actual landing state and preservation

At this run's start #542 was open against clipboard-copy. Before delivery it had been merged at 834d7e04 into source-app-icons (its actual base had changed), and #541 was also merged into source-app-icons. #540 and #538 had merged into their respective older intermediate bases. Main was c90e3822 after #535 and the concurrent #539 background-activity feature, but did not contain 561f9694 (#542). The source-app-icons landing tree was byte-for-byte identical to #542's tree. This is a new landing check; the older #534 closure audit remains complete and unchanged.

The integration merges feature commit d1ca216ccc0efaec5d0c54c6226741ab4b1ddf5d into main c90e3822a38d558d00bd7fe602bd92f3509e7c46, with common base 967c5718. All original commits below are ancestors of the feature parent:

| PR | Commit | Behavior |
| --- | --- | --- |
| #535 | 967c5718 | Context native icons (already main) |
| #536 | 791278af | Quick Look isolation |
| #537 | 2d8d8e67 | Clipboard thumbnails |
| #538 | 70c5587f | Clipboard metadata/waveforms |
| #540 | f6d1a788 | Source application icons |
| #541 | 03f6750d | Clipboard copy preparation/commit |
| #542 | 561f9694 | Clipboard OCR |
| #543 | d1ca216c | Shared screenshot OCR and exact sensitive geometry |

Tree audit (`media-integration-tree-audit.json`): all 24 main-only paths and all 99 stability-only paths match their respective parent byte-for-byte. The seven shared paths are AppCoordinator, DIContainer and five localizations. The two Swift files automatically merged and were self-reviewed in both directions: background-activity registration/routes remain alongside the independent workers and quit fences. Five append-only localization conflicts were resolved preserving every current-main key/value and every feature-added key/value. Main's intentional removal of obsolete download-menu labels remains; an initial overly broad assertion requiring all legacy feature-parent keys correctly exposed those removals and was refined to compare feature changes against the common base. No new merge-resolution business behavior was added.

## Fresh integration validation

After resolution and self-review:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
# Verified __llvm_covmap / __llvm_prf_cnts in both final binaries.
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '<scope below>'
```

Commands used `scripts/test_runtime.child_environment()`. No discovery rebuild, full suite, external CI wait or parallel local SwiftPM/UI run. Build passed in 305.32 s; **64/64 focused methods passed** (55 XCTest + 9 Swift Testing) in 19.70 s. Total integration command wall time 325.02 s, excluding tree audit/profile processing. No compilation/test failures or retries.

Scope is the complete 54-method shared OCR map plus ten integration checks: background source aggregation/routes, conversation activity and Ollama progress, existing menu grouping/download behavior, clipboard OCR revocation and copy/paste ownership. All inputs/sinks are synthetic or injected; no real download, capture, TCC, user clipboard write or paste event was requested. Exact filter:

```text
'^Typeflux(?:Focused)?Tests[./](?:SharedOCRIsolationTests[./]|ImageTextRecognizerTests[./]|ScreenshotSensitiveInfoTests[./]|ScreenshotRedactionSuggestionsTests[./](?:testThePanelShowsOnlyFinishedVisibleFindingsUntilClosed|testTheControllerScansOnceAndEditsTheDocumentThroughItsHost|testAControllerWithoutAScannerOrCancelledFindsNothing|testTheVisionScannerReadsThenDetects)|ImageTilingTests[./](?:testTheTiledRecognizer|testExactBoundsFollowTheLineOntoTheWholeImage|testLinesInTheOverlapAreKeptOnceAndPlacedOnTheWholeImage)|AskTranslationPanelCoordinatorTests[./]`(?:screenshots recognize locally then translate or show recoverable errors|pending selection and OCR do not overwrite A newer entry or user edits)`|AskScreenshotFollowUpTests[./](?:recognizedTextOpensInTheLauncherAfterItsContext|aStaleLauncherOpeningDoesNothing|translatingRunsTheTranslationKeywordOnTheText|nothingToTranslateLeavesTheEmptyCard|theWaitingScreenshotsTextIsTheResultWithItsKeys|aRunForAnotherScreenshotStops|noTextShowsTheEmptyStateWithItsWaysOn)|MediaWorkerTests[./](?:testRealHelperImagePDFMalformedAndCrashHangFixtures|testShutdownCancelsRunningChildAndRejectsNewWork)|MediaProtocolTests[./](?:testInvalidIdentityVersionAndAmbiguousResponsesFailClosed|testJPEGEnvelopeRejectsMixedWrongTypeBrokenBase64AndPageOrdering)|BackgroundActivityCenterTests[./](?:testCenterMergesSourcesInOrderAndSortsByRank|testCenterOpensRoutesWithoutAskingTheSource)|BackgroundActivitySourceTests[./](?:testConversationModelReportsNoRunsWhileIdleAndForwardsChanges|testAgentRunsMapApprovalPlanAndCurrentStep|testOllamaPullReportsProgressCompletionAndCancel)|StatusBarMenuSupportTests[./](?:testSpeechModelDownloadIsNoLongerListedInTheVoiceInputMenu|testStatusBarMenuGroupsFeaturesBeforeSettingsAndSeparatesHelpFromQuit)|ClipboardOCRIsolationTests[./](?:testExplicitCopyCommitsOnceAndEmptyDiffersFromFailure|testRevocationDeletionHideSourceMutationAndShutdownFenceCopy)|ClipboardCopyIsolationTests[./]testIntentionalDismissalAllowsOnePasteButChangedClipboardOrAccountStopsIt)'
```

Eight fresh profiles (three host, five directly invoked helper) from this integration binary were individually validated and merged without warnings. No #543 profiles or older layout were reused. Matching evidence: `.build/media-integration-validation`. SHA-256:

- XCTest: `e3694b3076c8423e545000986a9aecd5723db7b0d67ec88bcb463109cc92ecaa`
- Helper: `59c301b00b5d0aa3f07b785a790fc35b2b7fce705cd8602adebf35c7c95a6745`

This merge adds no executable behavior beyond already documented increments, so it asserts no additional changed-line percentage. #543's 97.67% is explicitly its own matching-binary result, documented in `shared-ocr.md`; it is not reused as evidence for this merge. The OCR increment's packaging/probe and screenshot evidence remain in that document. No new packaging target was introduced here.

## Continuing work

GUL-399 remains in progress. Next is the still-synchronous Vision text-rectangle/mosaic sizing path, with coherent async preparation and safe whole-mask fallback. Vision scroll registration, playback/native boundaries, stage-2 health/lifecycle wiring, and audio/TCC/signing/performance work remain. Real CoreML/performance, full Xcode build, Developer ID/notarization, macOS 13/Intel hardware and actual quit/recording are unverified. No arbitrary host crash, system-wide OOM or power-loss guarantee is claimed.
