# Process consolidation regression review — 2026-10-24

## Confirmed source defects and corrections

1. **Clipboard self-forwarding.** `WorkflowController+History` still compared the physical role with the removed `clipboard` process. A host-owned clipboard request therefore queued the same logical command back into the host indefinitely. Replace the old role test with the shared ownership relation. This loop explains both missing presentation and repeated events under very few trace IDs; it also consumes CPU independently of diagnostic recording.
2. **Host-owned recording self-routing.** The supervisor forwarded a host-owned recording hotkey through its own host-routing branch again. Deliver host events directly, preserve the original trace on child forwarding, and discard stale editor-session events instead of bouncing them back to voice.
3. **Capture cold startup.** Screenshot was only launched on demand and inherited both host and child module-startup barriers. Prewarm it after essential startup and a two-second delay; screenshot bootstrap/presentation no longer waits for unrelated storage/media modules. Actual capture permission and fresh screen acquisition still occur only after user action. Idle retirement and protected pins/recording remain unchanged.
4. **Diagnostic amplification and misleading export scope.** The report limited the number of samples but not events inside a sample. Pretty-printed JSON amplified repeated routing events, and exporting ignored UI filters. Bound ordinary writer events to 256 per trace per process, with eight reserved terminal events; bound retained reports to 200 samples, 128 events per sample and 2,048 total events. Preserve the beginning and tail, count omitted events, export the visible selection and current process snapshots with compact JSON and a 2 MiB ceiling. Rotation targets 16 files of 256 KiB; simultaneous writers can transiently exceed the file-count target. Existing oversized log history is bounded when parsed, without needing to delete it manually.
5. **Unrelated preferences restarted content indexing.** Every preferences broadcast forced a new semantic lifecycle, cancelling helpers/current progress even when index configuration was unchanged. Use the service's existing configuration fingerprint to avoid unnecessary restart; explicit rebuild/recovery commands retain their force behavior. A regression observes progress-reset publication and verifies actual index configuration changes still invalidate the lifecycle.
6. **Service-health ownership.** Settings still selected aggregate health only for the removed `settings` process. Select it for the actual settings owner so the page includes and recovers child-owned services.

The screenshot supplied by the user shows one Typeflux process using 175.4% CPU. The self-forwarding loop is a confirmed CPU-consuming defect, but the image does not identify its business role or establish that all observed CPU came from that loop. No claim of a measured post-fix CPU/latency result is made. The 27.3 MB exported JSON was described but was not attached in this turn; the amplification mechanism above is confirmed from source and synthetic runaway-trace tests.

## Validation scope and results

The primary focused command covers ownership/RPC forwarding, input delivery, clipboard presentation, voice gestures, screenshot state transitions, service-health UI and diagnostics schema/rendering/export:

```bash
make coverage SUITE="FeatureProcessConsolidationTests FeatureShortcutOwnerTests FeatureModuleHealthTests ModuleHealthSettingsTests ClipboardPanelSnapshotTests ShortcutLatencyTests ShortcutLatencyUITests ScreenshotCoordinatorTests AskVoiceInputTests FeatureVoiceRecordingTests" FILTER='WorkflowControllerProcessingTests/testHistory(Picker|Panel)'
```

Result: **130 tests passed** (59 XCTest + 71 Swift Testing). Complete command wall time, including build/discovery, execution and coverage export: **225.90 seconds**. Discovery/build took 208.40 seconds. App and test code compiled and linked; this was not an application launch. The initial changed-line coverage was 52/78 = 66.67%.

The subsequently identified index-preference restart and lighter UI row filtering are checked with the smallest affected scope:

```bash
make coverage SUITE="FeatureBackgroundRuntimeTests SemanticFileServiceTests SemanticPreparationServiceTests ShortcutLatencyTests ShortcutLatencyUITests"
```

Result: **37 tests passed**, including the new unrelated-preference regression. Complete command wall time was **101.56 seconds**, including 84.58 seconds of build/discovery. Both focused commands passed without failed-test retries; their 167 executions include intentionally repeated diagnostic tests.

Final changed executable-line coverage is **56/82 = 68.29%**, above the current 60% target. Coverage was exported from each pass's matching binary/profile. Counts from unchanged files are combined; `FeatureBackgroundRuntime`, `ShortcutLatencyReport` and `ShortcutLatencySettingsView`, which changed before the supplemental pass, use only final-source counts. This is changed-code coverage, not whole-project coverage. Native AppCoordinator entry points remain unverified by runtime tests, as required by the remote-host restriction.

Tests use synthetic captures, temporary stores, injected APIs/recorders and an in-process bootstrap gate. No development app, packaged feature children, real screen capture, microphone or global-input interaction was launched on this remote machine. Native permissions, physical shortcut delivery, post-idle screenshot latency and measured CPU/memory remain local acceptance boundaries.

## Local acceptance

- Open and close clipboard history repeatedly with its shortcut and the menu; verify normal CPU afterward.
- Trigger screenshots after startup, repeatedly, and again after the 180-second idle retirement. Verify capture, cancel, OCR/translation follow-ups and pins.
- Record in launcher/chat, stop/release while closing an editor, then record again; verify there is no repeated routing or loss of stop gestures.
- Change ordinary UI/diagnostic preferences while indexing; confirm progress continues. Change the index scope/enable state; confirm it applies.
- Inspect the service-health page, filter shortcut diagnostics, and export. Exported samples must match the filter; current process snapshots remain included. Check the dropped-event counter when inspecting old runaway logs.
