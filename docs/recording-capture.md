# Low-latency microphone capture

Ordinary recording uses `CoreAudioRecorder` through `SwitchableAudioRecorder`.
The optional Instant Voice Input setting still uses `AVFoundationAudioRecorder`
and its existing warm-window/pre-roll behavior. Set `TYPEFLUX_AUDIO_CAPTURE=legacy`
when launching the app to force the compatible capture path for diagnosis.

## Lifecycle

- In the workflow, request capture before resolving application metadata,
  reporting analytics, or constructing the recording UI. Application icons are
  not loaded for recording hints. These tasks must not delay microphone startup.
- Show the existing recording controls after startup succeeds and a nonempty
  audio buffer arrives, including silence. Do not add a waiting capsule or delay
  the interface until a nonzero sample arrives. Signal onset remains diagnostic.
  Buffer audio independently while realtime recognition setup is pending.
- Readiness belongs to one recording. Cancellation invalidates it, so late audio
  cannot make a later session appear ready. A cancelled in-flight hardware start
  retains ownership until its result is stopped; new presses cannot reuse it.
- After microphone permission has been granted, prepare an input-only AUHAL and
  bounded memory buffers on the recorder queue. Do not call `AudioOutputUnitStart`
  while idle. Rebuild preparation after device changes and sleep/wake.
- On activation, start hardware on the recorder queue, outside the workflow/UI
  executor. A five-second startup timeout abandons late attempts; a late driver
  completion stops its input instead of publishing it to another recording.
- The HAL callback renders into a preallocated single-producer/single-consumer
  ring. It does not allocate, lock, write files, convert audio, or call Swift/UI
  code. Ring overflow and render errors are reported, not silently accepted.
- A recorder-queue consumer drains packets every four milliseconds, writes mono
  WAV data, and forwards audio to the existing transcription buffer relay. It
  preserves packets received before session/file setup completes.
- Stop hardware first, drain the remaining accepted packets, close the file,
  restore muted output, and prepare a stopped input for the next recording.
- Silence is valid input. Device notifications and missing callbacks are distinct
  from low signal level; quiet audio does not trigger a microphone rebuild.

The input uses the device's native sample rate. It reads the actual device buffer
size and does not change the shared hardware buffer setting, which can affect
other applications. Format conversion happens outside the real-time callback.

## Reproduce measurements

Use the signed, microphone-authorized development app. An unbundled SwiftPM
executable is not a valid microphone-permission or packaged-app test.

```sh
"$HOME/Applications/Typeflux Dev.app/Contents/MacOS/Typeflux" audio-capture-check compare 10
"$HOME/Applications/Typeflux Dev.app/Contents/MacOS/Typeflux" audio-capture-check pipeline 3
```

These commands are available only in debug builds. `compare` alternates an
AVAudioEngine tap and direct HAL capture using one resolved device ID. It discards
audio and emits timing/frame counters. `pipeline` verifies the new recorder's WAV
output in a temporary directory and removes it afterward. Neither command sends
audio to a transcription provider.

Measure both callback arrival and the first packet's sampling host time. Delayed
packet delivery alone does not prove missing audio. A negative relative sampling
time can occur when the device is already running; it is not an unsigned overflow.
The device-wide running flag includes other clients/output. On macOS 14.2+, use
`processInputPrepared` and `processInputStopped` to verify this process releases
microphone input, even when another application keeps the hardware running.

`[Recording Startup]` traces distinguish `workflow.audio_start_enter`,
`workflow.context_begin` / `workflow.context_end`, `audio.first_buffer`, and
`workflow.recording_ready`. A second summary is emitted when the UI becomes ready.
Compare the whole hotkey-to-audio path, not just the hardware start call. The
ready signal confirms buffer delivery; it does not prove that speech began
after the microphone started or that recognition preserved every word. Raw probes
also report `leadingZeroMs` and `firstNonzeroCallbackMs`: a fast callback can still
contain hundreds of milliseconds of driver-supplied zeros. See the
[full startup investigation](recording-startup-investigation.md) for the controlled
Bluetooth reproduction and the ordered network-writer repair.

Historical callback-only measurements (not signal-readiness measurements):
observed on one selected microphone on 2026-09-07 (five alternating runs per path):

| Metric | AVAudioEngine tap | Direct HAL |
| --- | --- | --- |
| First callback after start request | 116.1–151.1 ms | 29.7–32.2 ms |
| First packet | 4,800 frames at 48 kHz | 320 frames at 16 kHz |
| Input running during preparation / after stop, per process | 0 / 0 | 0 / 0 |
| Maximum packet timestamp discontinuity | 0 ms | 0 ms |

The formats differ because the legacy engine delivers converted audio while the
HAL path uses the input format. This is a complete capture-path comparison, not
an isolated buffer-size experiment. Some runs had other hardware activity; do
not generalize these numbers to every microphone or to cold device startup.
Three complete new-recorder checks produced valid mono files with first callbacks
around 31–32 ms. These checks do not prove real spoken-prefix accuracy, Bluetooth
reconnection, or behavior on untested hardware.

After moving workflow setup behind capture, two observed starts in the signed
development app on the same date reached `workflow.audio_start_enter` in 0.3 and
1.0 ms from the hotkey trace. First buffers were consumed at 36.7 and 47.8 ms;
recording-ready presentation was requested at 38.5 and 101.3 ms respectively.
The slower first presentation did not delay capture. These are individual local
observations, not a hardware-independent latency guarantee. A separate packaged
recorder check produced a valid 10,240-frame mono WAV (0.64 seconds), and no
process was using microphone input after the check ended.

## Regression checks

`CoreAudioRecorderTests`, `CoreAudioRingTests`, and `SwitchableAudioRecorderTests`
cover prefix/order preservation, tail draining, bounded overflow, short recording,
silence, failure cleanup, device replacement, late startup cancellation, backend
selection and compatible startup fallback. Run `make coverage` for the full suite.

`RecordingAudioReadinessTests` and `WorkflowControllerProcessingTests` also cover
audio-before-setup, setup-before-audio, empty/quiet buffers, quick release,
cancelled startup ownership, stale callbacks, and ordered delivery of the audio
prefix when realtime session setup is delayed.

Run `bash scripts/check_audio_ring.sh` for 100,000 concurrent stereo packets with
AddressSanitizer/UndefinedBehaviorSanitizer and ThreadSanitizer. This check uses
only synthetic samples and never opens a microphone.
