# Process consolidation validation — 2026-10-24

The macOS client now routes logical features to five business owners: host, voice, chat, screenshot and background. The host reuses launcher/clipboard/ring/translation/settings windows; index state and ordinary media helper execution move behind the background service. Speech recording and editor transcription share the voice owner, with selected-model reuse preserved.

Architecture, enforced limits, recovery rules and the local acceptance checklist are in [process-consolidation.md](../design/process-consolidation.md).

## Review findings resolved

- Preserve logical destinations in shortcut traces while selecting children by actual owner. Reject obsolete standalone presentation roles at installation.
- Prevent presentation containers from opening a microphone/audio engine. Session-scoped editor commands, physical hotkeys and selection-Ask fallback all reach the voice owner.
- Do not idle-retire the voice owner or unload its selected speech model under the semantic model's 60-second policy.
- Bypass full application DI for the backend and the speech workflow for capture startup; scope capability startup to the actual owner.
- Propagate timeout budgets across both IPC hops instead of silently replacing long transcription/media budgets with ten seconds.
- Wait for native collection before releasing media/helper capacity. Bound the retained queue, cancel abandoned owner work and clean only disposable operation directories.
- Keep recording export on its established streaming/recovery path, and send screenshot follow-ups through private files instead of large base64 RPC payloads.
- Track foreground activity by source, so one producer finishing cannot resume indexing while another is still busy.
- Drain UI producers before stopping the backend. A failed draft save or active voice operation refuses quit instead of silently forcing termination. Retire MCP connections without deleting saved configuration.
- Preserve existing module quarantine/recovery restrictions when ownership changes. The one-time migration marker protects later explicit recovery from stale re-imports.
- Drain the event tap on a dedicated run loop with serialized gesture state. Refresh bindings only when their configuration changes; ordinary settings updates must not reset held gestures.
- Remove the obsolete shortcut-child watchdog and keep the backend prohibited from Dock/UI activation.

This was a manual source/contract/lifetime review. No development application was launched on the remote host.

## Focused test results

| Pass | Scope | Result | Runner wall time |
| --- | --- | --- | --- |
| Main impact scope | Process/RPC/auth-cache handoff, voice/editor gestures, index/search lifecycle, decoder ownership, health, termination, shortcut diagnostics and localization | 163 XCTest + 162 Swift Testing tests passed | 298.06 s |
| Additional lifetime cases and affected callers | New backend startup/stop, queue/cancellation/reaping, input owner, synthetic diagnostics rendering, routed deadlines, voice/RPC/handoffs | 53 tests passed | 117.85 s |
| Binding-refresh fix | Input-owner tests and directly affected activation/auxiliary/ring/screenshot hotkey suites | 74 XCTest + 2 Swift Testing tests passed | 88.60 s |
| Resource-only export | Diagnostics schema and synthetic rendering; process metrics remain exportable before any shortcut sample exists | 14 tests passed | 87.01 s (complete command: 92.03 s) |
| Media backpressure | Busy admission does not quarantine a healthy decoder | 20 tests passed | 193.26 s (complete command: 196.39 s) |
| Queue deadlines | Queue expiry, cancellation and decoder recovery budget | 13 tests passed | 96.64 s (complete command: 106.52 s) |
| Backend drain | Wait for actual collection; cancelled work does not consume fault recovery | 17 tests passed | 88.77 s (complete command: 91.69 s) |
| Priority and image delivery | Monotonic busy-source state, recognition priority and original-image fallback | 14 tests passed | 55.94 s (complete command: 60.41 s) |
| Audio readiness | Hardware start timestamp precedes ASR connection; editor gesture and routing regressions | 33 tests passed | 99.37 s (complete command: 103.84 s) |
| Input callback isolation | Recording predicate works outside the UI actor | 3 tests passed | 87.28 s (complete command: 92.21 s) |

The standalone `swift build` also passed (complete command wall time: **47.14 s**). The subsequent focused validations rebuilt and linked the application and test bundle after the final audio-readiness and input-callback fixes.

There were **568 successful test executions in all-passing runs**, including intentional affected-scope repeats; **344 distinct tests** passed. The runner wall times include build preparation, discovery and execution. Coverage export/HTML generation ran afterward and was not separately timed. Earlier discovery-only attempts found and corrected a Swift Testing macro limitation around a mutating fixture; they did not execute tests or launch the app.

Changed executable-line coverage is **875 / 1401 = 62.46%**, above the current 60% target. This is changed-code coverage, not whole-project coverage. Focused suite coverage must not be represented as full application coverage.

Each retained coverage pass preserved its matching instrumented test binary, profile and LCOV export. Aggregation uses the maximum hit count for unchanged source lines; files edited between passes use only exports from their matching final source version. The single activity-payload edit in the semantic-service file is checked against the earlier source snapshot and uses only its final-version count; unchanged lines retain their matching prior counts. Untracked new Swift files are included. Generated profiles, binaries and HTML are not committed.

### Reproduction scopes

```bash
make coverage SUITE="FeatureProcessConsolidationTests FeatureHelperBudgetTests FeatureVoiceRecordingTests FeatureBackgroundRuntimeTests FeatureImageTransferTests FeatureRPCTests FeatureAskAdapterTests FeatureHandoffTests FeatureTranslationTests FeatureModuleHealthTests FeatureActivityMirrorTests AskVoiceInputTests RecordingGestureDecisionTests HotkeyGestureArbiterTests AuxiliaryHotkeyTests RingHotkeyTests ScreenshotHotkeyTests AskFileIndexStateTests AskFileIndexServiceTests AskFileSnapshotTests SemanticFileServiceTests SemanticPreparationServiceTests SemanticEmbeddingServiceOwnershipTests SemanticIndexProgressServiceTests SemanticMediaServiceTests SemanticWorkBudgetTests SemanticFileStoreTests SemanticFileIndexerTests MediaWorkerTests WhisperWorkerTests WhisperInferenceModuleTests AskFileReaderRetirementTests ModuleHealthStoreTests AppTerminationBarrierTests ClipboardPanelSnapshotTests AskResultImageCacheTests ShortcutLatencyTests ShortcutLatencyDetailTests ShortcutLatencyUITests LocalizationResourceTests MCPRegistryRecoveryTests"

make coverage SUITE="FeatureProcessConsolidationTests FeatureMediaJobsTests FeatureShortcutOwnerTests FeatureBackgroundRuntimeTests ShortcutLatencyUITests FeatureVoiceRecordingTests FeatureHelperBudgetTests FeatureImageTransferTests AppTerminationBarrierTests FeatureRPCTests FeatureAskAdapterTests FeatureHandoffTests FeatureTranslationTests"

make coverage SUITE="FeatureShortcutOwnerTests HotkeyGestureArbiterTests AuxiliaryHotkeyTests RingHotkeyTests ScreenshotHotkeyTests"

make coverage SUITE="ShortcutLatencyTests ShortcutLatencyUITests"
```

Tests use isolated defaults, temporary directories, synthetic images/views and injected decoders/recorders where applicable. The opt-in feature-freeze fixture was updated to the new independent owners but **was not run**, because it launches packaged application children.

## Failures corrected during validation

One supplemental 17-test priority run found a busy-payload decoder still expecting the earlier Boolean shape. The receiver was corrected to accept the timestamped activity payload and ignore stale epochs; the affected backend suite passed in the subsequent priority/image-delivery run. The other 16 tests in that failed run are not included in the successful-run execution total above.

A supplemental image-delivery test initially failed to compile because the assertion macro hid the throwing read from closure inference. The read was moved before the assertion and the same focused command passed on retry. No full test suite or application launch was used to repair either issue.

The final additional regression scopes were:

```bash
make coverage SUITE="FeatureMediaJobsTests MediaWorkerTests FeatureProcessConsolidationTests"
make coverage SUITE="FeatureMediaJobsTests MediaWorkerTests"
make coverage SUITE="FeatureMediaJobsTests MediaWorkerTests FeatureBackgroundRuntimeTests"
make coverage SUITE="FeatureVoiceRecordingTests FeatureBackgroundRuntimeTests FeatureImageTransferTests FeatureImageDeliveryTests"
make coverage SUITE="FeatureVoiceRecordingTests AskVoiceInputTests FeatureBackgroundRuntimeTests FeatureProcessConsolidationTests"
make coverage SUITE="FeatureShortcutOwnerTests"
```

## Remaining local acceptance boundary

The build and tests establish compilation, internal contracts and tested cancellation/ownership behavior. They do not establish microphone permissions, Accessibility/global shortcut delivery, physical screen capture, selected-model cold/warm latency, native window interactions or actual idle/peak footprint and CPU on the user's Mac.

Use the architecture document's acceptance checklist and export the built-in diagnostics after local use. OS helper counts and measured memory/CPU must be reported separately from the five business owners. Existing specialized semantic query/index workers, cheap I/O helpers, recording export and external MCP services retain their documented separate lifetimes; no hard whole-product RSS/core-count guarantee is claimed.
