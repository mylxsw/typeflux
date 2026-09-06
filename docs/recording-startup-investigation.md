# Recording prefix investigation — 2026-09-07

## Finding and limits

On the currently selected DJI Mic Mini 2 Bluetooth input, a fast audio callback is
not evidence that the microphone is delivering sound. Recent saved recordings
begin with 582–702 ms of exact digital zero despite first callbacks near 30–36 ms.
A signed, raw HAL diagnostic reproduced an 802.56 ms zero prefix and received its
first nonzero packet 830.27 ms after requesting capture. This diagnostic has no
recording overlay, file conversion, output muting, network, or transcription.
The delay therefore exists in the Bluetooth/device/OS input path before those
application stages. The experiment does not isolate the transmitter firmware
from the Bluetooth driver, nor prove every reported missing word has this cause.

An independent client defect was also reproduced: live audio could overtake the
buffered prefix while a network write was suspended. That defect is repaired.

When the microphone is stopped between uses, software cannot reconstruct speech
that the input device never delivered. A waiting indicator does not shorten the hardware's zero prefix. The separate
waiting capsule was removed after user feedback: normal recording controls now
appear on the first nonempty buffer, while signal-onset measurement stays diagnostic.
Instant Voice Input remains optional and disabled in these experiments.

## Complete path and potential delays

| Stage | Observation / risk | Treatment |
| --- | --- | --- |
| Physical shortcut → event tap | Event tap runs on the main run loop; busy UI can delay handling. Previous traces began after this delay. | Use physical event uptime for trace and history timestamps. Moving the tap itself off the main run loop remains a possible follow-up if measured event dispatch latency warrants it. |
| Gesture arbitration | Tap/hold/double tap decisions can defer recognition setup. | Begin provisional capture immediately; preserve the complete prefix while deciding the gesture. Existing 450 ms / 1 s semantics remain unchanged. |
| Workflow → hardware request | Application context, analytics and overlay work formerly preceded capture. | Capture is requested first on its own queue. Previously verified in commit 9301885. |
| Overlay construction / presentation | Main-thread layout and animation can delay feedback and future shortcut handling. Meter updates are limited to about 33 Hz and enqueue UI work without blocking capture. A UI request timestamp is not a painted frame timestamp. | Prepare the hidden HUD in advance, skip initial recording-state SwiftUI animations, and show the existing controls on the first nonempty buffer without a separate waiting state. |
| AUHAL preparation → start | Permission, device configuration and driver startup can block. | Prepare a stopped input, never start idle capture, start off the UI executor, retain timeout/cancellation ownership. |
| Driver → first callback | Direct HAL reduced measured callback wait to about 30 ms. | Keep preallocated real-time capture ring and native device format. Do not equate callback arrival with signal arrival. |
| Callback → actual signal | Cold Bluetooth input delivers hundreds of milliseconds of exact zeros. This also occurs in the raw diagnostic. | Measure raw zero prefix and first nonzero packet. Keep signal measurement independent of UI presentation. No VAD threshold; tiny finite samples count. |
| Ring → conversion / WAV | Serial consumer runs every 4 ms; file work can cause backpressure. | Preserve every accepted packet, including zeros. Ring overflow is an error, never silent prefix overwrite. Stop drains the final packets. |
| Relay → PCM conversion / chunks | Recognition may not yet exist when first audio arrives. | Keep prefix buffering and a single buffer pump. Regression tests cover delayed setup and early stop. |
| Buffered prefix → network writes | Actor reentrancy allowed a new live chunk to run during an awaited prefix send. Reproduced A,C,B instead of A,B,C. Stop could also overtake pending writes. | One writer task owns all chunks and finalization. Connection setup, prefix, live audio and stop follow one ordered stream. Cancellation closes the stream and prevents successful finalization. |
| WebSocket gateway → provider | Authentication, connection, provider readiness and queues delay recognition. | Inspected client, realtime-asr and compatibility gateway. Wire format remains PCM16 mono 16 kHz; no protocol or server edits. Focused gateway tests pass. No evidence these stages created zeros already present in the local WAV. |
| ASR → postprocessing → insertion | Recognition can omit speech; optional rewriting and insertion can change visible text. | Keep these separate from capture. An exact failing utterance and original playback are still required to attribute any additional text omission. No claim that queue repair proves every first-word omission fixed. |

## Controlled measurements

The only enumerated input during this investigation was the DJI Bluetooth device.
Ordinary capture was selected; output muting was enabled in user settings, but the
raw diagnostic does not mute output. Sound effects are disabled in current code.

| Probe | First callback | Raw zero prefix | First nonzero callback |
| --- | ---: | ---: | ---: |
| Direct HAL after idle | 30.34 ms | 802.56 ms | 830.27 ms |
| Direct HAL immediate repeat | 29.28 ms | 0 ms | 29.28 ms |
| Direct HAL next immediate repeat | 28.99 ms | 0 ms | 28.99 ms |
| Legacy engine cold comparison | 176.68 ms | 936.35 ms | 1083.34 ms |

Each probe observed process input usage 0 before/prepared/after stop and 1 during
capture. Measured packet timestamp discontinuity was zero. Warm repeat results
must not be advertised as cold-start performance: the device route can stay warm
briefly even when this process has released input.

A separate read-only review of 12 recent saved WAV prefixes found many 582–702 ms
zero runs, two at least one second, and others around 723–863 ms. Only timing and
energy were inspected for this comparison; no private speech or transcript is
included in this document. A raw zero run alone cannot establish exactly when a
person spoke; its reproducibility on cold starts is the relevant device evidence.

## Instrumentation and behavior

- Record physical press, handler arrival, hardware request, first callback, first
  raw nonzero packet, workflow readiness and overlay ordering separately.
- `firstAudioSignalAt` is receipt time of the first raw packet with any finite
  nonzero sample. It is not a speech detector or exact acoustic onset timestamp.
- `leadingZeroDuration` counts sample duration before the first nonzero sample.
  It does not discard silence, gate recording or modify the waveform.
- History distinguishes callback latency, signal latency and digital-zero prefix.
  Its startup lane ends at signal receipt when this measurement is available.
  Old records without these optional fields retain the prior display behavior.
- Recording remains cancellable and late callbacks are generation checked.
  All-zero input is recordable and shows the normal recording controls; no separate
  waiting animation or speech-dependent UI gate is presented.
- Idle preparation and hidden UI preparation do not acquire microphone input.

## Reproduction and acceptance

Use the signed development app, not the raw SwiftPM executable:

```sh
TYPEFLUX_API_URL=http://127.0.0.1:8080 make run
"$HOME/Applications/Typeflux Dev.app/Contents/MacOS/Typeflux" audio-capture-check coreaudio 3
"$HOME/Applications/Typeflux Dev.app/Contents/MacOS/Typeflux" audio-capture-check compare 4
```

The raw probes discard samples and send no audio to ASR. Allow the Bluetooth
route to become idle before the first run and compare it with immediate repeats.
Monitor `firstCallbackMs`, `leadingZeroMs`, `firstNonzeroCallbackMs` and process
input usage. Do not replace the signal metric with the smaller callback number.

For hardware comparison, attach the DJI receiver to the computer via its supported
USB connection and select that input; do not assume connecting a transmitter
charging dock supplies USB audio. DJI documents the receiver-to-computer path:
<https://repair.dji.com/help/content?customId=en-us03400011680&documentType=artical&lang=en&paperDocType=paper&re=US&spaceId=34>.
Repeat cold-start probes and approved spoken-prefix trials. No USB receiver or
alternate input was available during the initial investigation, so a latency
improvement for that configuration has not been measured.

Automated checks cover sample preservation (including zero prefixes), all common
PCM formats, physical event timing, delayed readiness, stale/cancelled starts,
ordered network writes, stop-after-drain, cancellation, and history compatibility.
Run `make coverage` for the full client suite. Gateway checks used:
`go test ./internal/ws ./internal/asr/doubao/...` in realtime-asr and
`go test ./internal/transport/ws` in typeflux-api. Both passed. Neither constitutes
a live provider transcription trial, and neither service was changed or deployed.

## Validation results

The full client `make coverage` run passed 2,566 XCTest cases and 69 Swift Testing
cases (2,635 total). The first full run exposed a pre-existing 10 ms scheduling
assumption in the late-hardware-start test; its dispatch allowance was increased
while retaining a deliberately longer simulated hardware delay and all cleanup
assertions. Production timeout behavior was not changed.

All five localization files passed `plutil -lint`; new keys occur once in each
locale. `git diff --check` passed. The two gateway repositories remained clean.

The final development app was packaged and launched with `make run`; strict
code-signature verification passed. Two signed-app `pipeline` probes each produced
a valid 10,240-frame, mono WAV (0.64 s) and cleaned it up. Callback times were
36.44 and 31.46 ms. These are functional checks, not new cold-start evidence: a
separate input method had acquired microphone input during the final checks.
Typeflux itself had released input afterward.

Final visual/shortcut acceptance remains unverified: the UI automation bridge
repeatedly timed out selecting the newly launched development app. A process
sample showed its main thread idle in the normal AppKit event loop, rather than
blocked in overlay preparation. Automated recording-presentation/readiness/cancellation tests
passed, but do not replace a successful packaged UI trial. No claim of complete
spoken-prefix recovery is made without the receiver comparison and a matching
original-audio/recognized-text example.

A final raw probe using the rebuilt app, after input became idle again, confirmed
that the device delay remains: first callback 43.64 ms, zero prefix 842.06 ms,
first nonzero callback 883.63 ms, and zero packet timestamp discontinuity. Both
hardware-wide and per-process input flags were 0 before preparation/after stop
and 1 during capture. This isolates the remaining delay from the preceding
input-method activity and explicitly demonstrates that the software repair did
not eliminate the Bluetooth cold-start zero prefix.
