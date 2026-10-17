# Bounded realtime audio handoff and transport

Baseline: `46b60c0031582f182a417460dbdf8811fb78a1d1` (includes #633 PDF location work; not functionally tested here). Member acceptance threshold is now 70% changed executable coverage. This increment fixes two demonstrated unbounded AsyncStreams as an audio resource prerequisite; it does not migrate capture or claim the signed-device stage is accepted.

## Production behavior

The raw PCM pump has at most 256 queued snapshots, each at most 256 KiB, plus an in-flight buffer and the producer's bounded snapshot. Queue limits can be reduced per instance; they cannot exceed the production maximum. The byte check occurs before copying. Producer admission is serialized with close/cancel; closed producers do not copy. A dropped buffer permanently fails this pump, closes its input, and cancels the downstream session after entered append work actually returns. No task is spawned per callback. `finishInput` joins actual completion and throws instead of permitting a transcript derived from missing audio.

The encoded PCM transport similarly has at most 512 fixed-size chunks plus an in-flight chunk. Each encoded input is at most 1 MiB, and the chunker remainder is less than a chunk. The existing one connection task, one writer and one failure observer remain; finish now collects the writer and observer even after failure. A full queue, including a final partial-chunk overflow, cancels the stream and preserves the first error. Entered writes cannot be rolled back; no successful stop/short transcript is emitted after overflow. Shared actors keep their current source ownership and single ordered writer.

Conversion target capacity is checked for finite, positive rates and a bounded result BEFORE floating-point-to-frame-count conversion, converter construction or target allocation. No valid conversion is executed by the selected tests. The production encoded-input handoff is shared with the actual encoder; tests feed handcrafted PCM Data to this exact transport boundary, not a substitute network queue.

The composer places pump completion inside its existing transcription error/cancellation policy. The regular workflow carries an already-observed pump error through a fixed failed-input session into its EXISTING error/fallback routing; it does not silently switch to a different success/optimization path. The original recorded file remains available. There is no new provider retry policy, health replay, automatic recording, microphone owner, worker, helper ABI, pool, permission grant or global scheduler hook.

## Focused scope and limits

New `RealtimeAudioBoundsTests` cover held raw append, canceled and invalid/oversized input, exact byte bounds and immutable producer snapshots, held connection/write overflow, final flush overflow, healthy order/remainder, encoded input limits, actual collection, numeric allocation safety and the failed-input adapter. All continuations release and Tasks/transport writers are joined. The slow fake deliberately does not release entered work on cancel.

Reviewed existing selection: five raw-memory snapshot methods (all except the 10,000-iteration concurrency method), one raw-memory pump ordering method, two pure chunker methods and one diagnostics method. Remaining realtime ordering/session tests perform AVAudioConverter work and are excluded. No whole suite, recorder/CoreAudio input constructor, real codec/converter/encoding, microphone, output audio, network, provider, paid request, window/clipboard/ConversationModel, home, TCC, signing or device access occurs. WorkflowController/composer objects are not instantiated; their bridges are compiled and audited, not object-level integration proof.

The fixed queue counts bound these retained buffers, not total process memory, scheduling delay or arbitrary callbacks. An entered uncooperative append can still delay collection; the code does not free it early or start a replacement. The startup prefix relay, file-write coordinator and other consumers retain separate queue/resource contracts and are not falsely covered by these caps. Audio engine Objective-C exceptions, capture/TCC/signing, actual device switch/sleep/quit and performance remain the finite [stage 4 gates](stage-4-prerequisites.md). No arbitrary crash/OOM/power-loss recovery is implied.

## Fault found during functional validation

The initial mapped scope had 9/9 XCTest methods pass, followed by four new Swift Testing methods (including the two invalid-input cases). On the next connection-overflow method the test helper exited with signal 5. It was NOT an assertion failure or a successful complete suite. The other new methods had not executed.

The isolated diagnostic reproduced the fault. A Swift backtrace environment attempt could not backtrace the privileged helper and stalled in its spawned backtracer. Attaching LLDB to ONLY that owned child, without user init scripts, identified:

```text
Foundation __DataStorage.ensureUniqueBufferReference / Data.InlineSlice.replaceSubrange
PCM16FrameChunker.reset
BufferedRealtimeTranscriptionSession.cancel / fail / enqueue
```

The pre-existing chunker repeatedly removed consumed prefixes and later cleared the resulting nonzero-index Data slice while preserving capacity. The capacity-failure cancellation exposed its Foundation assertion. The production fix replaces reset storage and drains using explicit owned zero-based chunk/remainder copies, without mutating consumed slices. This also removes repeated shifting of the entire prefix. A new heap-sized/sliced Data regression covers reset, flush, exact boundaries, remainder and the unframed legacy mode. No exception swallowing, timeout relaxation or fixture assertion correction hides the fault.

The diagnostic backtracer was terminated by its exact verified child PID and the stopped owned helper resumed to exit; debugger, helper and parent command were collected before edits. Initial and diagnostic archives are separate from the final binary/profiles. The final retry is limited to the containing new suite plus the directly affected two chunker and one pump regression. Six earlier passing snapshot/diagnostics methods are not rerun, and are not counted as final-profile coverage.

## Results and coverage

**22 distinct methods have passing results across runs, not one unchanged 22/22 run.** After the production Data fix, final affected scope **16/16 passed**: 3 XCTest methods (0.028 s suite wall) and 13 Swift Testing methods/14 parameter cases (0.024 s). Six initial passing snapshot/diagnostics methods were not repeated. All final gates and callers were released/joined; initial aborted children were physically collected. No timeout relaxation or fixture assertion correction was used.

Final changed executable coverage is **132/140 =94.29%** versus the actual baseline: snapshot19/19, realtime113/115, composer0/2 and workflow bridge0/4. Unhit realtime231/401 enter the actual converter, and six caller bridge lines require forbidden object-level fixtures. These remain in the denominator. The requested 70% threshold is met; no additional run pursued a higher percentage. Coverage uses ONLY the final binary and three final profiles, not the initial or diagnostic data. This is not branch/race/device coverage or a full workflow/DI proof.

## Timing and provenance

| Foreground command | Total wall seconds | Result |
| --- | ---: | --- |
| First build | 310.68 | Two old test callers lacked try after the throwing API change; corrected before functional tests |
| Second build | 159.50 | Passed after caller migration and allocation preflight refinement |
| Collection refinement build | 121.34 | Passed; writer cancellation now joins actual I/O |
| Initial inventory | 4.964 | 21 methods |
| Initial focused execution | 23.54 | 9 XCTest and four new methods passed, then signal5 |
| Initial archive | 4.394 | Separate two profiles/old binary |
| Single-method diagnostic | 230.53 | Reproduced fault; runtime backtracer stalled, owned-child LLDB stack obtained; child collected |
| Diagnostic archive | 3.329 | Separate one discovery profile/old binary |
| Data ownership fix build | 117.42 | Passed |
| Final inventory | 25.739 | 16 affected methods |
| Final focused execution | 18.42 | 16/16 passed |
| Final archive | 13.984 | Three final HOST profiles |

Audit, extraction and platform/Git operations are additional; diagnostic duration includes the live backtrace/collection interval, not extra test body time. Final build retains one new redundant Void-result `_ =` style warning in ownedCopy, plus unrelated/pre-existing diagnostics and native-build deprecation. It is recorded rather than forcing another build for a style-only edit. No Source/Test input changed after the final Data-fix build.

All **1154 Source +873 Test =2027 Swift inputs** match FINAL PREBUILD/live/archive after extraction. Live/archived app/test binaries and each original/copied raw hash match; every raw validates; sparse merge and independent remerge are warning-free and byte-identical. Matching app-object show/export and all-functions stderr are empty; both binaries contain both LLVM coverage sections. All 368 reported Swift function hashes are zero, which is NOT counter-layout proof. Old/live/root-default/initial/diagnostic profiles are excluded; the newly generated inventory root profile predates final test start and is separately excluded. No mixed layouts or child coverage are claimed.

Final SHA-256:

- Test: `d5e54720e7db7f27144dad686478ae941e997fbb57e583995a4fdce8d5cce8b0`
- App: `7f8d4445ec105d02f152d3ba42b278b66559308b247fb7fd5abca2bc2b7e1fd0`

Private reproducibility archive `.build/realtime-audio-bounds-validation/final`; exact inventories and raw hashes are in the repository method JSON. Every build/inventory/test/archive/extraction job was collected before dependent reads/edits. This archive is local evidence, not a delivered binary or a crash-containment guarantee.
