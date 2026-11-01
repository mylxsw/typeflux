# Unrelated failures from the single full run

The full run completed 5,013 XCTest methods (18 skipped); 19 methods failed with 27 failed assertions. It stopped before the serial Swift Testing phase. This is a record of that run, not a claim that the full repository passes.

Per the parent owner’s scope clarification, unrelated Ask, clipboard, media, screenshot and icon fixtures were restored unchanged; no feature changes were made for them. These failures are outside Onboarding. Only the category assertion below was reproduced in pristine main; other entries were observed in the original full run and were not independently reproduced on a clean baseline.

## 既有失败，与本任务无关（基线抽查）

`ClipboardContentClassifierTests.testKindCategoriesAndTextuality`: the original assertion expects `["all", "snippet"]`, but pristine main already contains `voice`. `baseline-spotcheck.json` records a standalone Swift comparison with the original category assertion’s inputs against the unmodified component in a detached main worktree. Both source and fixture match the delivery branch byte for byte. This is a component reproducer, not the full XCTest method or a full baseline application build.

## Full-run failure names

| Suite | Method |
| --- | --- |
| `AgentSettingsRedesignTests` | `testEveryPaneRendersInBothAppearances` |
| `AskCodeSandboxTests` | `testPythonImageAndOutputLimit` |
| `AskLocalBudgetTests` | `testContextBudgetStopsBeforeInferenceAndUsesModelWindow` |
| `AskRemoteImageTests` | `testOutputGroupBoundsPreviewAttemptsAndRetainsAllAssetReferences` |
| `AskRemoteImageTests` | `testRealHelperDetectsOriginalTypeAndRejectsMalformedBytes` |
| `ClipboardAudioPlaybackTests` | `testPanelHideSelectionDeletionAndAccountStopActualOwners` |
| `ClipboardContentClassifierTests` | `testKindCategoriesAndTextuality` |
| `ClipboardVideoPlaybackTests` | `testActualPanelHideSelectionDeletionAndAccountClearVideo` |
| `ClipboardVideoPlaybackTests` | `testPixelBudgetDeniesBeforeFactoryAndCancelledUncooperativeReplyKeepsLease` |
| `ClipboardVideoPlaybackTests` | `testRealHelperRotatedVideoFramesSeekVolumeEndAndExplicitRestartWithoutAudioTrack` |
| `NativeIconIsolationTests` | `testHomePrefetchCoversGridViewportBeforeAnyImageViewExists` |
| `RecordingPreviewIsolationTests` | `testRealRecordingHelperStopsAtTrimEndAndPausedSeekNeverResumes` |
| `ScreenshotBeautificationTests` | `testBeautificationPreviewsTheFinishedCutoutAndWaitsForProcessing` |
| `ScreenshotBeautificationTests` | `testOverlayAndLongImageControllerForwardSettingsAndDismissSheets` |
| `ScreenshotBeautificationTests` | `testPanelCancelApplyAndReopenKeepDraftsIsolated` |
| `ScreenshotOverlayTests` | `testChromeDrawsEveryPart` |
| `SmallIconIsolationTests` | `testEditorLocalIconScopeLoadsAndCancelsOnRemoval` |
| `TypefluxOfficialASRGatewayFixtureTests` | `testLLMErrorAfterOutputDoesNotReplayOnAnotherGateway` |
| `TypefluxOfficialASRGatewayFixtureTests` | `testPartialThenServerErrorDoesNotReplayOnAnotherGateway` |

The diagnostic runs of wider, previously unexecuted Swift suites were incomplete and encountered further unrelated fixture failures. Temporary repairs to those suites were withdrawn. Final affected-scope validation is recorded separately in `validation-ledger.json`; it does not replace the full-run result.

## Script checks — 既有失败，与本任务无关

`make test-scripts`: 176 tests in 75.959 s, 3 failures. All three reproduce in the pristine main worktree:

- `FocusedCoverageTests.test_focused_coverage_builds_and_executes_only_its_scope`
- `FocusedCoverageTests.test_test_failure_is_not_masked_by_report_generation`
- `NativeDeviceSelectionTests.test_http_exception_is_only_in_debug_plist`

See `baseline-script-tests.json` and `baseline-ios-script.json`. The changed test runner’s own 23 tests pass.
