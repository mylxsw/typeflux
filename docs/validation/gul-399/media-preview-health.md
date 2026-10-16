# GUL-399: media preview lifecycle and persistent health

This increment depends on #559 (`c0b9510f5338c703836b99f28704c9ec00a8949c`). #559 remains an open draft against main. The new PR is stacked on its media-health branch, preserving its base. Main's concurrent semantic-indexing and menu-bar changes at `a9582e17` were inspected; the parent merges cleanly by `git merge-tree`, and this increment does not change their paths or behavior. No PR was merged or CI awaited.

## Behavior and boundaries

`MediaWorker.previews` now requires lifecycle binding and readiness. DI retains a second `MediaExtractionModule`, registered as `mediaPreviews` with independent `mediaPreviews.json`; attachment extraction retains `mediaExtraction.json`. The adapter's closed domain enum supplies only these two IDs. The existing three storage registrations and behavior remain unchanged.

The same typed preview pool still owns at most two children with the existing three-second child deadline. Startup checks executable availability, not native format/signing correctness. Recovery reserves persistent budget once per factory generation, never per request. Existing 4 KiB health records contain only version/budget/quarantine metadata, not paths, media, text, credentials or child diagnostics. Corruption is preserved until explicit reset. File I/O remains off the UI factory path but can be uncooperative and retains lifecycle capacity.

The adapter reuses the existing coalesced activity/fault stream, immediate generation gate, failure classification, backoff, and host-plus-child retirement barrier. Disable, cleanup and quit fence results; no pool replacement expands capacity while work remains. Input refusals, saturation, cancellation and ordinary source failures do not consume crash budget; child/transport/protocol faults do. No previous request is stored or replayed when readiness returns.

Audited callers: bitmap/PDF/AV display, native Finder/type/application icons, custom file icons/favicon decoding, original-context Quick Look, context/remote/artifact images, tool-image normalization, generated-image validation, workflow inspection/display and PNG/TIFF clipboard preparation. These all use `perform`; no custom `owned` producer is newly bound. Caller authority, task/selection/account/window scopes, pixel budgets, source checks, retained producer output and single pasteboard/publication commits remain in place. Recovery does not run workflows, paid generation, clipboard writes or other producers.

Standalone fixtures now explicitly inject workers/normalizers. PDF and file-preview facades, workflow preview/editor, small-icon environment and system clipboard conversion expose narrow injection seams; production defaults still use the managed preview pool. No full DI initialization, global mutable test bypass, helper/protocol/packaging changes, cache or extra task queue was added. A default-path test verifies pre-DI refusal while text preview still works.

Other media pools (clipboard thumbnails, registration, OCR/geometry, metadata/timeline and recording encoding), native/inference/playback and remaining feature adapters are not integrated by this PR. Account/source permission remains feature-owned; readiness is not a permission grant. Custom recording encoding has separate fault/retention semantics and must not be blindly bound. Capture/live audio meter, user-requested OS Quick Look, host filesystem/raw raster/pasteboard/SQLite/UI/AppKit/GPU/system memory remain boundaries. Real CoreML, full Xcode, Developer ID/notarization, Intel/macOS 13 hardware, real quit/recording and audio/TCC/performance verification remain required. No arbitrary host crash, system-wide OOM or power-loss guarantee; GUL-399 stays in progress.

## Validation

Implementation and self-review preceded functional tests. Direct sanitized SwiftPM commands used `scripts/test_runtime.child_environment`:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '<explicit scope below>'
python3 -m unittest scripts.tests.test_media_packaging
```

No discovery rebuild: prebuilt inventory used `native_tools` / `native_environment` and SwiftPM testing helpers. `__llvm_covmap` and `__llvm_prf_cnts` were verified before execution. App and media-helper build versions both declare macOS 13; the existing XCTest toolchain runtime reports macOS 14, not macOS 13/Intel hardware validation. Screenshot flags `TYPEFLUX_ASK_SNAPSHOTS` and `TYPEFLUX_GUL303_SNAPSHOTS` enabled actual component fixtures.

111 distinct methods completed (59 XCTest, 52 Swift Testing; Finder scale method has two argument cases). Initial scope: 108/110 passed. One existing real-file-preview metadata call timed out after 3.084 seconds; it passed on the focused retry with unchanged production deadlines and only fixture-kind diagnostics added. Its underlying timing cause was not established. The other failure was a multiline workflow fixture call missed during dependency injection; it hit the intentionally unbound pool instead of returning malformed-image classification. Only the fixture was corrected.

The two failed methods plus a new default-bridge/fallback test passed 3/3. A one-method icon-component supplement passed to cover the injection setter in the same final binary. It was needed to meet the changed-code coverage target without mixing test counter layouts. Core lifecycle tests passed initially, including cancellation, uncooperative host/child retirement, corruption/quarantine, simulated clocks, disabled/quit, late results and no replay. New tests exercise independent budgets, corruption isolation, expected refusal versus malformed raw output, actual managed typed consumers and the settings recovery button without decoding an attachment. Existing permission/selection/window, copy and producer-retention tests were included.

2/2 packaging tests passed. The real managed helper decoded synthetic images and performed harmless native icon/Quick Look calls; the helper/protocol/package did not change, so no new copied-helper probe was run. Temporary workflow scripts and HTTP/provider/pasteboard fixtures remained private/injected. No real user clipboard, paste/wheel, capture/TCC, audio output, network/provider, application launch, full suite or signed/hardware run. The actual 640×190 unavailable/recovery settings component screenshot was inspected (`media-preview-health.png`).

Preparation builds: 71.33 s failed on the default renderer function-reference arity after adding the worker parameter; fixed with an explicit forwarding closure before tests. Subsequent builds 234.77 / 46.80 / 40.44 / 31.37 s passed. Last two were test-only. Test commands: 86.17 / 29.57 / 9.13 s. Build/test total 549.58 s; prebuilt inventory 4.137 s; packaging reported 0.157 s. Tracked total 553.874 s excludes interpreter startup for packaging, audit, archive, coverage and screenshot review. No inputs edited during builds/tests, no simultaneous own SwiftPM/UI jobs.

Evidence housekeeping: one archive invocation used the wrong working directory and failed before copying, then was rerun correctly. One coverage merge/extraction was started before supplemental archival finished and failed on the missing metadata/profile; after collecting archival, the merge/extraction succeeded. No profile was dropped or passing result reused to conceal those tooling failures.

## Coverage attribution

Changed executable lines: **33/36 = 91.67%** against `c0b9510f`. The three uncovered lines are DI construction/retention/registry composition (162–164); no full DI startup was performed incidentally. Line hits do not prove all branches, native allocations, hardware behavior or real quit correctness.

All production source hashes are identical between the initial and final test builds. Coverage is attributed per file using matching saved binaries, never merged across changed test counter layouts:

- Initial production-final build: 19 fresh individually validated profiles; used for all production files except the three bridge files below.
- Final test-only build: 3 profiles from the correction/default-bridge run plus 3 from the icon supplement, identical binary SHA, merged warning-free. Used for `AskSmallIcon.swift`, `AskWorkflowImageView.swift`, `AskFilePreviewLoader.swift`.
- Both exports include `TypefluxMediaHelper` via `llvm-cov --object`; no changed helper code coverage is claimed. Inventory-only `default.profraw` was excluded and archived separately.

Matching evidence folders: `.build/preview-health-validation/{initial,final,integration}`; `integration` here is only the supplemental same-binary profile archive, not a main merge. Raw profiles were individually checked; merges completed warning-free before successful extraction. Machine-readable per-file attribution is `media-preview-health-coverage.json`.

Initial XCTest SHA: `2f0befee4df14aaa3464ab1d181da45a09b3d202a5788e5b7e1b36e4794fc233`.

Final XCTest SHA: `518cb582f66a1dd6de52c6d822c7677d141f2840726648498a42bf80e90eb73b`.

Unchanged helper SHA: `25072bcc62620da339441bbbf1c05d19f20e5c0fbb641b95eafc70fe5e1f09d2`.

## Exact first-pass scope

```text
^Typeflux(?:Focused)?Tests[./](?:MediaPreviewModuleTests[./]|MediaPreviewHealthViewTests[./]|MediaExtractionModuleTests[./]|ModuleRegistryTests[./]|ModuleSupervisorTests[./]|ModuleHealthStoreTests[./]|StorageModuleRegistryTests[./]|MediaWorkerTests[./]|AskAPIClientTests[./]typedResultUsesTrustedOptInAndRetainsLegacyReceipt(?:\(|$)|AskArtifactToolTests[./]testNativePreviewsHandleTruncationBinaryUnsupportedMimeAndBoundedImages(?:\(|$)|AskContentPreviewTests[./]mediaPreviewStartsAtTheMatchedSegment(?:\(|$)|AskContentPreviewTests[./]pdfMatchUsesTheActualPageAndDrawsHighlights(?:\(|$)|AskContextImageTests[./]testAuthorizationIsRecheckedAfterAwaitAndOnEveryProjection(?:\(|$)|AskContextImageTests[./]testDecoderAdmissionAndCancellationReachOwnedWorkers(?:\(|$)|AskContextImageTests[./]testFailureDoesNotRetryFromGettersAndInvalidRastersFailClosed(?:\(|$)|AskContextImageTests[./]testOldResultAndOldDeniedAccessCannotOverwriteNewSelection(?:\(|$)|AskFilePreviewVisualTests[./]`cancelled\ renderers\ do\ not\ publish\ content`(?:\(|$)|AskFilePreviewVisualTests[./]`real\ text\ PDF\ image\ and\ audio\ renderers`(?:\(|$)|AskFilePreviewVisualTests[./]`video\ frame\ and\ invalid\ media`(?:\(|$)|AskHarnessUITests[./]artifactsCopyAsImagesAndEncodeAsPNG(?:\(|$)|AskImageGenerationTests[./]testAllProvidersDecodeImagesAndPreserveOriginalBytes(?:\(|$)|AskImageGenerationTests[./]testDownloadRetriesOnlyTransientReadFailuresOnce(?:\(|$)|AskImageGenerationTests[./]testFailureNeverRetriesPaidGeneration(?:\(|$)|AskImageGenerationTests[./]testGenerationAndDownloadShareRemainingTaskDeadline(?:\(|$)|AskImageGenerationTests[./]testLocalImageDataCoexistsWithPersistedConversationImage(?:\(|$)|AskImageToolTests[./]testUnknownPaidOutcomeHasPrivateIdentityAndNeverRetries(?:\(|$)|AskLauncherHeaderVisualTests[./]renderLauncherHeaderStates(?:\(|$)|AskLocalEngineTests[./]testTypedResultThroughLocalRunAndReopen(?:\(|$)|AskPluginListViewTests[./]`icons\ come\ from\ symbols\ files\ and\ types`(?:\(|$)|AskResultImageCacheTests[./]aCancelledApplicationIconLoadDoesNotPublishAnImage(?:\(|$)|AskResultImageCacheTests[./]finderIconsRasterizeOnlyTheDisplaySize(?:\(|$)|AskResultImageCacheTests[./]ordinaryFileIconsUseTheFinderImagePath(?:\(|$)|AskToolImageIsolationTests[./]testHistoryPreparationWindowAndOlderContentRemainAvailable(?:\(|$)|AskToolImageIsolationTests[./]testNoSerializedProofOrUntrustedMarkerCanEnableProjection(?:\(|$)|AskTypedContentIntegrationTests[./]testActivityUsesModernOutcomeAndShowsEveryImage(?:\(|$)|AskTypedContentIntegrationTests[./]testProviderSchemaAndMultipleImagesRetainP07Limits(?:\(|$)|AskTypedContentIntegrationTests[./]testSQLiteJournalAndCacheReopen(?:\(|$)|AskTypedContentTests[./]testAllBlocksSurviveAndUnsupportedIsVisible(?:\(|$)|AskTypedContentTests[./]testLegacyProjectionRejectsInconsistentSuccessAndKeepsSimpleImages(?:\(|$)|AskTypedContentTests[./]testOpaqueMCPAndStructuredOnlyRoundTrip(?:\(|$)|AskWorkflowAuthoringTests[./]realRunsKeepPreviewAssetsAndNeverPublishTestWrites(?:\(|$)|AskWorkflowDeveloperToolsTests[./]`qr\ result\ is\ displayed\ as\ an\ image\ and\ decodes\ to\ the\ original\ text`(?:\(|$)|AskWorkflowImageTests[./]`copying\ an\ image\ puts\ the\ image\ and\ the\ file\ on\ the\ pasteboard`(?:\(|$)|AskWorkflowImageTests[./]`data\ UR\ ls\ are\ saved\ once\ to\ the\ cache`(?:\(|$)|AskWorkflowImageTests[./]`paths\ are\ read\ from\ the\ folder\ home\ or\ anywhere`(?:\(|$)|ClipboardCopyIsolationTests[./]testMalformedOversizedAndSymlinkInputsLeavePrivatePasteboardUntouched(?:\(|$)|ClipboardCopyIsolationTests[./]testOriginalPNGSurvivesChildConversionAndChangedSourceCannotCommit(?:\(|$)|ClipboardCopyIsolationTests[./]testOversizedOrRemovedFileListsNeverClearPasteboard(?:\(|$)|LocalizationResourceTests[./]testLocalizedStringTablesParseForAllSupportedLanguages(?:\(|$)|ModuleHealthSettingsTests[./]unavailableObservationFailsClosedAndStateCopyIsLocalized(?:\(|$)|NativeIconIsolationTests[./]testAllowlistAndBoundsRejectBeforeDispatch(?:\(|$)|QuickLookIsolationTests[./]testRealHelperAndDocumentRendererReturnOnlyOwnedPixels(?:\(|$)|SmallIconIsolationTests[./]testFileAndFaviconViewsShowPixelsRefreshIdentityAndClearPrivateDisplay(?:\(|$)|SystemClipboardContentActionsTests[./]testWritesStoredImagesAsPNGAndTIFF(?:\(|$)|WorkflowImageIsolationTests[./]testCacheIsBoundedPrivateAndCannotOverwriteCorruptExistingOutput(?:\(|$)|WorkflowImageIsolationTests[./]testCopyNormalizesOrientationAndCacheQuotaNeverEvictsOutputs(?:\(|$)|WorkflowImageIsolationTests[./]testEditorPreparationOwnsItsViewAndLeavesOriginalRunOutput(?:\(|$)|WorkflowImageIsolationTests[./]testWorkflowViewShowsRawPixelsAndClearsOnScopeInvalidation(?:\(|$))
```

Correction/new-coverage scope:

```text
^TypefluxTests[./](?:MediaPreviewHealthViewTests[./]defaultViewsFailClosedBeforeBindingAndTextStillLoads|AskFilePreviewVisualTests[./]`real text PDF image and audio renderers`|AskWorkflowImageTests[./]`paths are read from the folder home or anywhere`)
```

Final same-binary supplement:

```text
^TypefluxTests[./]SmallIconIsolationTests[./]testFileAndFaviconViewsShowPixelsRefreshIdentityAndClearPrivateDisplay
```
