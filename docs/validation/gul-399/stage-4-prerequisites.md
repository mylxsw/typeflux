# Stage 4 prerequisite decision and manual acceptance record

This report is a read-only prerequisite decision, not evidence of signed-device testing. No recording, model preparation/download, provider request, permission prompt, hardware operation, system icon lookup or signing command was executed. Stage 4 remains unaccepted. It is a separate gate from the completed media/consumer ownership work.

## Current source boundaries

- `Audio/AVFoundationAudioRecorder.swift` still owns AVAudioEngine in the host. `installInputTap` uses `TFInstallAudioTapSafely`; `removeInputTapIfInstalled` calls `removeTap` directly. `TypefluxAudioSafety.m` catches NSException only around the synchronous `installTapOnBus` call. It does not catch later audio callbacks, arbitrary engine operations or process-wide faults. Do not describe this as a recover for the recording subsystem.
- `Ask/QuickResults/Plugins/Translation/AskTranslationEngines.swift` still constructs `TranslationSession(installedSource:target:)` and awaits translation in the host on supported systems. The installed-language availability check does not establish a process-isolation boundary. Moving it requires an OS/version/packaging compatibility decision, not another image-worker wrapper.
- WhisperKit has an existing inference helper and protocol/retirement evidence. That does not establish real model memory/latency or system Translation behavior. The previous [inference report](local-inference.md) retains the exact unverified release/device limitations.
- Existing media helpers protect their own native operations. Hotkey/event taps, permission UI, explicit Quick Look panel, synchronization and other AppKit callbacks remain host entry points. A worker restart is never authorization to repeat a keystroke, sync mutation, paid request or recording.

## Resource prerequisite delivered separately

The subsequent [realtime audio bounds](realtime-audio-bounds.md) increment bounds the PCM handoff and encoded transport queues, rejects incomplete realtime results and checks conversion allocation sizes. Its tests use raw PCM/private Data and fake transports, not recording hardware or an audio codec. This is a concrete resource fix under the audio prerequisite; it does not pass any signed-device gate below or change microphone ownership. The separate [recording queue bounds](recording-queue-bounds.md) increment now caps the pre-activation relay and audio-file writer, reserves before preparation and preserves original partial-file errors. Neither synthetic resource result passes a device/signing gate or changes microphone ownership.

## Decision

Keep existing capture ownership until the signed audio/TCC and performance gate below passes. Do not add a second concurrent microphone owner, move recording into an unsigned test child or use successful synthetic media tests as permission evidence. No full application crash-recovery claim is possible while arbitrary UI, filesystem and native callbacks remain in-process.

A subsequent migration must use the already-approved stage 4 architecture, with one explicit recording/session owner, original account/permission epoch, bounded PCM transport/backpressure, actual child retirement, truthful partial-recording output and no recording replay. This document does not select a new helper ABI or implement that migration before its prerequisites.

## Read-only package receipt

The [package preflight](stage4-package-preflight.md) provides a reproducible structural check and member-hash receipt before a designated signed package enters this checklist. It never launches/signs code or marks a manual gate passed. Its synthetic tests validate the tool only; a real signed package has not been supplied/verified by that result.

## Finite manual gate (not executed)

Use a designated test Mac and private disposable data. Record the signed app commit, OS/architecture, signing/notarization identity class, TCC permission owner, device and before/after measurements. Never include tokens, audio content, clipboard contents or model paths in the public record.

| Gate | Procedure / acceptance requirement | Current result |
| --- | --- | --- |
| Packaging and identity | Verify nested helpers, resources, Developer ID/notarization and supported macOS/architecture launch; permission prompts remain attributable to the intended owner | Not executed |
| Microphone permission | Allow, deny and revoke through user-driven settings; refusal ends the current attempt once and causes no prompt/retry loop; a later explicit attempt behaves truthfully | Not executed |
| Device lifecycle | During one explicit private recording, switch/unplug input, sleep/wake, then stop; release old owner and preserve usable partial output or explicit failure; next explicit recording works | Not executed |
| Quit and actual collection | Quit while capture/transcription is active; record host/child retirement and absence of a second microphone session; do not infer collection from a canceled UI task | Not executed |
| Audio performance | Measure startup/stop latency, callback drops, bounded transport, CPU/RSS and idle power against the same signed baseline/workload; agree thresholds before migration | Not executed; no numerical pass threshold invented |
| Local inference / translation | With explicitly prepared test resources, measure cold/warm latency, memory and cancellation; verify installed/unavailable language behavior and version fallback; no automatic downloads or provider fallback replay | Not executed |
| Hotkey / capture / sync entry points | Private signed-app smoke pass: repeated enable/disable, window close, account switch and shutdown; no duplicated event tap, replayed capture or sync mutation, cross-account result or retained observer | Not executed |

Record pass/fail and evidence for these seven rows once. A failure becomes a concrete defect; an unrelated neighboring consumer does not automatically become another blocking PR. No full suite or real device action is implied or authorized by publishing this checklist. Explicitly accepted deferral must be recorded if the four-stage issue is narrowed; absence of evidence is not a pass.
