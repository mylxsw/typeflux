# Semantic indexing progress delivery (GUL-399)

## Delivery and dependency

This increment is stacked on open draft #578 (`b2b5c454f82a01ef80c401c82bee05f39fecb6e5`), whose base remains #577. It does not merge any PR. Main was inspected at `ceeaaef5bf4f2e5625a0654d6f3d31702821f174`; no semantic-directory changes exist on main since the common ancestor. Main's storage-only automatic quarantine reset and chat/background-task changes remain outside this feature tree and must be preserved when landing the chain.

## Behavior

`SemanticIndexProgressDelivery` gives each service one short-locked mailbox containing at most one cumulative Summary, one current path (including explicit nil), and one absolute media-download fraction (including explicit nil). Producers replace these fields without awaiting the main actor, creating a task per event, or capturing a queue of paths/summaries. One delivery is scheduled; offers during delivery can schedule one successor after the current synchronous sink returns. Replacement attempts share the scheduled slot, even while delivery is held. This is bounded pending work, not a fixed frame-rate throttle or a guarantee against main-actor stalls.

Summary fields are cumulative/absolute snapshots, not deltas. The indexer's throughput, durable queue, trace, foreground priority, partial commits, inference and media-transfer code are unchanged. Watcher events and document-work queues do not enter this replaceable mailbox.

`SemanticFileSearchService.beginIndexing` binds all three callbacks to the original lifecycle token and attempt identity. Consumer delivery also checks the current settings fingerprint. Replacing/stopping/clearing the scope invalidates the mailbox. A paused attempt retains totals and nil resets without publishing a new non-nil path or changing its phase. Completion and failure synchronously collect and seal pending progress before terminal publication, and clear the transient path/media fraction; queued callbacks cannot resurrect them. Successful completion still obtains authoritative final database counts.

Progress-driven count refreshes retain the actual in-flight task through cancellation, with one latest pending request. Priority-update changes received during a read are retained. Each request carries its original database, token and attempt; cancellation is checked before entering the read and after returning. A cancelled detached read already inside SQLite is not rolled back. Replacement refreshes wait for that physical read, and clear joins it. The initial preparation count and final authoritative read remain separate existing lifecycle reads; this is not a global SQLite reader pool or hard deadline. The read-only count closure and delivery scheduler are narrow constructor dependencies for deterministic private fixtures; production defaults call the same database count operation and MainActor delivery.

There is no callback-driven model preparation, download, inference, scan, write retry, or health recovery. No health schema, diagnostics, native helper ABI, packaging, permission grant, source consent or model mutation admission changed. No new packaging probe was warranted. File names, document text and queries are not added to persisted health or diagnostics.

## Focused validation

Implementation and self-review preceded functional tests. Native build commands used `scripts/test_runtime.child_environment` and:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '<explicit inventory below>'
```

Both final test and app executables contain `__llvm_covmap` and `__llvm_prf_cnts`. Inventory used prebuilt `native_environment`, `native_tools` and `swiftpm-testing-helper`, not xctest as a program. Exactly **50 methods in 12 Swift Testing suites passed**, first functional pass, with no failing-method retry. Argument cases remain part of those methods.

Mapping:

| Scope | Methods | Reason |
| --- | ---: | --- |
| SemanticIndexProgressDeliveryTests | 4 | 100,000-update producer flood; held actor delivery; absolute totals/fractions and nil; 1,000 source replacements share one slot; stale/final rejection; offer during a sink; successor delivery |
| SemanticIndexProgressServiceTests | 6 | Actual service final/error consumer; paused totals; queued replacement/clear; blocked in-flight count returning into a replacement (including no transient zero publication); settings edits before notification |
| SemanticFileServiceTests (safe methods) | 8 | Start/settings, fake downloads, cancellation, rebuild/removal, targeted reconciliation |
| SemanticRealtimeSearchTests (synthetic methods) | 8 | Lexical fallback, permission withdrawal, scope cancellation, independent query behavior |
| SemanticHybridSearchTests | 9 | Filename fallback, selection and independent launcher/plugin consumers |
| SemanticMediaServiceTests | 4 | Documents during media idle wait; failure; release; priority document arrival |
| SemanticIndexFairnessServiceTests | 1 | New small document searchable while an existing document remains partially committed |
| SemanticFileIndexerTests | 4 | Cumulative run/reconcile semantics, unchanged files/deletion/cancellation/skips |
| SemanticIndexFairnessTests | 3 | Live cumulative priority updates and partial committed batches |
| SemanticIndexPriorityTests | 1 | Foreground pause/yield/resume without restarting producers |
| SemanticDiscoveryPauseTests | 1 | Discovery retains frames across pause |
| SemanticPreparationServiceTests | 1 | Cancellation of original detached preparation |

The held delivery scheduler deliberately leaves the production mailbox undrained while background producers run; it does not assert that a stalled UI can render. The in-flight count fixture captures a real private database count, blocks its return, replaces the lifecycle, observes the new committed index, then releases the old read and checks every published file count. Utility assertions cover late media-fraction offers; independent text-model download attempts are explicitly outside this increment.

Only synthetic documents, placeholder models, vectors, private filesystem stores and injected encoders/readers/transfers/sinks were used. Existing private-corpus file-reader tests use the existing helper. No real weights/CoreML, live model download, provider/network access, user directories/network mounts, TCC interactions, capture, microphone/audio output, user clipboard/paste/wheel, external app control, full-suite execution, signing or hardware validation. Real-model event/realtime/media tests and native settings-window tests were excluded. Presentation did not change, so no screenshot was produced.

## Coverage and provenance

Changed executable lines against #578: **141/141 (100%)**, comprising service **87/87** and mailbox **54/54**. This is added/modified executable-line coverage, not all-branch, race, device, permission or real-quit proof. The adjacent JSON lists per-file attribution.

Only **two fresh HOST profiles** from this one final build were individually validated with `llvm-profdata show`, merged without warnings, and extracted with the matching app object. They are SwiftPM's XCTest discovery and Swift Testing host profiles; the scope contains no XCTest test methods. No child-worker coverage claim is made. Prior-stage profiles and root discovery `default.profraw` were excluded. New Sources were included using `git add -N`. LLVM export with the matching app object produced empty stderr. Swift function hashes do not establish compatibility across layouts; no cross-build/layout profiles were mixed.

Final local archive: `.build/semantic-index-progress-validation/final`. Archived and current hashes matched for all **1,123 Swift source files**, **802 Swift test files**, and both executables after extraction. No source/test input changed after the final build. Executable SHA-256:

- Tests: `83f5188d80b887da83b075dc3a24ad7817a8b01492e98926d425a2695cd3187e`
- App: `4482bc0a456be0b7c9b0892420e74d0d454b8a1fc27a2588c496096124be5435`

First build passed in **225.81 s**, with new method-reference Sendable warnings in the fixtures. These were corrected with explicit Sendable closures before any functional test; the second/final build passed in **49.46 s**, with no warnings in changed files. Unchanged files still emit existing compiler warnings, and the toolchain deprecates the requested native build-system option. Pre-test additions in the second build also covered blocked count completion and settings-fingerprint fencing. Inventory **5.704 s**; focused test command **51.87 s** (Swift Testing execution **23.110 s**). Tracked build/inventory/test command wall total **332.844 s**, including preparation and runner startup; archive/extraction, read-only audits and platform delivery are outside that measured total. All build, test, archive and extraction commands were collected to completion.

## Remaining work

The independent `downloadModel` fetch callback still creates one MainActor task per progress event and needs original-attempt cancellation/final-completion ownership. Broader watcher/rescan/start/permission callback ownership also remains; do not drop watcher events as though they were replaceable UI snapshots. This prerequisite increment does not claim the whole semantic progress/lifecycle task is complete. Next continuation must audit/fix the independent download path without redoing model health or replaying old producer work.

Other feature/condition lifecycle integration and native/media audit remain, followed by audio/TCC/signing/performance validation before microphone capture ownership. Real CoreML/model performance, full Xcode/Developer ID/notarization, macOS 13 Intel and actual quit while recording are unverified. Capture/live meter and OS QuickLook remain separate. Host filesystem/JSON/raw memory/SQLite/UI/AppKit/GPU/system memory boundaries remain; no arbitrary host crash, system-wide OOM or power-loss immunity is promised. GUL-399 remains in_progress.

## Exact method inventory

```text
TypefluxTests.SemanticDiscoveryPauseTests/`pause stops a directory stream between frames and resumes without losing files`()
TypefluxTests.SemanticFileIndexerTests/`changes deletion failures and cancellation`()
TypefluxTests.SemanticFileIndexerTests/changedFileReconcilesWithoutCrawlingOrReembeddingItsNeighbors()
TypefluxTests.SemanticFileIndexerTests/emptyOrScannedContentIsSkippedWithoutLoadingModel()
TypefluxTests.SemanticFileIndexerTests/unsupportedFilesDoNotConsumeTheSemanticFileLimit()
TypefluxTests.SemanticFileServiceTests/`default off and unsupported cannot be enabled`()
TypefluxTests.SemanticFileServiceTests/`download cancellation corruption and disabling`()
TypefluxTests.SemanticFileServiceTests/`model download retry search rebuild and removal`()
TypefluxTests.SemanticFileServiceTests/automaticSettingsWatcherAndPowerChangesKeepLifecycleCoherent()
TypefluxTests.SemanticFileServiceTests/corruptIndexCanBeClearedWithoutRemovingVerifiedModel()
TypefluxTests.SemanticFileServiceTests/downloadFailuresAndEarlyCancellationReleaseSession()
TypefluxTests.SemanticFileServiceTests/foldersEditedDuringRebuildAreNotRestored()
TypefluxTests.SemanticFileServiceTests/irrelevantEventsDoNotRescanAndChangedFilesUseTargetedReconciliation()
TypefluxTests.SemanticHybridSearchTests/`content matches get a taller row with their passage`()
TypefluxTests.SemanticHybridSearchTests/`file plugin publishes names then content with actions`()
TypefluxTests.SemanticHybridSearchTests/`fusion deduplicates and preserves original name score`()
TypefluxTests.SemanticHybridSearchTests/`long natural query and late cancellation`()
TypefluxTests.SemanticHybridSearchTests/`names publish first and keep choice when content arrives`()
TypefluxTests.SemanticHybridSearchTests/chosenFolderSurvivesTheSeparateFolderDisplayLimit()
TypefluxTests.SemanticHybridSearchTests/disabledFeatureKeepsLegacyLongQueryAndPluginBehavior()
TypefluxTests.SemanticHybridSearchTests/filenameResultsRemainAvailableBeforeAndDuringPausedIndexing()
TypefluxTests.SemanticHybridSearchTests/validatedContentBypassesSlowNamesWithoutChangingReturn(requireApps:)
TypefluxTests.SemanticIndexFairnessServiceTests/`ready service publishes new small document while changed long document is partial`()
TypefluxTests.SemanticIndexFairnessTests/`cancellation inside live document drain keeps committed batches for replay`()
TypefluxTests.SemanticIndexFairnessTests/`continuous events do not drain one long document before the next`(targeted:)
TypefluxTests.SemanticIndexFairnessTests/`media preemption also accepts events between long document batches`(targeted:)
TypefluxTests.SemanticIndexPriorityTests/documentEncodingYieldsAfterTheCurrentBatchAndResumesWithoutRestarting()
TypefluxTests.SemanticIndexProgressDeliveryTests/finalSnapshotIsCollectedBeforeTerminalStateAndIdleMailboxCanRestart()
TypefluxTests.SemanticIndexProgressDeliveryTests/offerDuringDeliverySchedulesOnlyOneFollowupAndCanBeSealedInsideSink()
TypefluxTests.SemanticIndexProgressDeliveryTests/producerFloodKeepsOneDeliveryAndLatestAbsoluteSnapshotsIncludingNil()
TypefluxTests.SemanticIndexProgressDeliveryTests/replacementAndFinishShareTheExistingQueuedSlotAndRejectLateSources()
TypefluxTests.SemanticIndexProgressServiceTests/completedIndexerCollectsHeldProgressAndQueuedDeliveryCannotResurrectIt()
TypefluxTests.SemanticIndexProgressServiceTests/failedAttemptSealsPendingSnapshotsAndPreservesFailure()
TypefluxTests.SemanticIndexProgressServiceTests/oldInFlightCountReadRetainsItsHandleUntilRetirementAndCannotPublishIntoReplacement()
TypefluxTests.SemanticIndexProgressServiceTests/pausedScopeReceivesTotalsWithoutChangingPhaseOrPublishingNewPath()
TypefluxTests.SemanticIndexProgressServiceTests/replacementAndClearDiscardOldCallbacksAndCountsButKeepNewCommittedIndex()
TypefluxTests.SemanticIndexProgressServiceTests/settingsEditBeforeNotificationDeliveryRejectsQueuedSourceProgress()
TypefluxTests.SemanticMediaServiceTests/`changed document preempts media without restarting the home scan`()
TypefluxTests.SemanticMediaServiceTests/documentsStaySearchableWhileMediaWaitsForIdle()
TypefluxTests.SemanticMediaServiceTests/idleWaitingDoesNotRetainADiscardedService()
TypefluxTests.SemanticMediaServiceTests/mediaFailureDoesNotInvalidateTheTextModelOrDocumentIndex()
TypefluxTests.SemanticPreparationServiceTests/`closing search and foreground voice cancel detached permission preparation`()
TypefluxTests.SemanticRealtimeSearchTests/`both entrypoints publish lexical while semantic is pending and keep selection`()
TypefluxTests.SemanticRealtimeSearchTests/`existing lexical index works without model or helper`()
TypefluxTests.SemanticRealtimeSearchTests/`lexical publishes before slow model and timeout does not disable next query`()
TypefluxTests.SemanticRealtimeSearchTests/`pause keeps searching and voice or thermal pressure keeps only lexical`()
TypefluxTests.SemanticRealtimeSearchTests/`permission withdrawal revalidates early hits and preserves permitted files`()
TypefluxTests.SemanticRealtimeSearchTests/`scope change clear and cancellation reject late results`()
TypefluxTests.SemanticRealtimeSearchTests/`semantic keyword publishes lexical while encoding is pending and keeps safe file selection`()
TypefluxTests.SemanticRealtimeSearchTests/fileModeLexicalDoesNotWaitForASlowFilenameProvider()
```
