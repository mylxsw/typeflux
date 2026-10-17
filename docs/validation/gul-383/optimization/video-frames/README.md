# GUL-405 video sampling and durable duplicate progress

Baseline: PR636 merge `67da58f9d03826d26095cf635f8e1d35dcc57006`.
This slice changes video frames only. Remaining GUL-405 work includes time-aware media opening,
embedded audio overlap, per-item retry/status, resumable verified downloads and real-model/native-input acceptance.

The current PR also contains a test-only fixture repair. See `fixture-repair/README.md` for the
independent writer-readiness failure, frozen MOV hashes, minimal revalidation and current-binary
fingerprints. Results below describe the original production slice and remain preserved.

## Implementation and limits

- Disposable filesystem worker samples from the video track start at 0.5-second steps, plus one request at
  `max(videoStart, videoEnd - 1/600)` to inspect the tail. Two requests per second plus one per asset;
  no duration/frame quota and no sequential full-video decode. AVFoundation may internally
  decode a GOP to satisfy a sample request. Requests use timescale 600 and zero seek tolerance;
  Video bounds use the video track, even when audio/the asset timeline is longer.
  Stored hit times use the actual returned `CMTime.seconds`, at the source frame precision.
- A 16 x 16 RGBA thumbnail (1024 bytes, RGB compared) represents the last **retained** frame.
  Skip only when mean absolute RGB difference is <= 2/255 and peak difference <= 12/255.
  Comparing against the retained frame prevents gradual drift being discarded indefinitely.
  The snapshot and thumbnail remain private and local. Raw sampled frames are released each iteration.
- This density captures the declared 0.7-second slide and explicitly checks the final frame;
  it does not guarantee arbitrary short moments. Changes smaller than the thumbnail/threshold
  can be merged. This is a conservative thumbnail distance, not a semantic scene classifier.
- `video_progress` stores next requested grid time, actual last decode time, bounded reference and
  tail-complete flag. It is separate from contiguous encoded segment ordinals. Duplicate-only
  progress is saved without JPEG output/inference. Retained vector and progress share one transaction.
  Stale generations cannot advance; regressing progress is rejected. Complete video resumes directly
  at the existing audio stage. File version or video recipe changes replace incompatible private jobs.
- Only video jobs are queued by the new recipe migration. Standalone PR636 audio and compatible
  image/PDF inputs keep their recipes. Video-frame vectors carry the new video recipe; embedded
  audio retains its existing provenance and extraction logic. Search checks the corresponding kind.
  New visual sampling does not claim to upgrade embedded audio overlap or player integration.

## Verification scope

`python3 docs/validation/gul-383/optimization/video-frames/run-coverage.py --name coverage-run`
invokes `make coverage` with explicit FILTER:

```
SemanticVideoFrameTests|SemanticMediaExtractorTests|SemanticMediaIndexTests|SemanticAudioWindowTests/audioRecipeMigration|SemanticIndexDiagnosticsTests
```

`SemanticVideoFrameTests` covers real synthetic MOV decode -> fixed image-identity vectors ->
SQLite publication/reopen -> `SemanticVectorReader` query, duplicate runs and EOF, IPC cancel/restart,
document preemption, video-only migration, stale generation and transactional rollback.
Extractor tests cover the directly called snapshot/security and real IPC paths; media index tests
cover shared publication and document/image/audio/video priority callers; audio recipe migration
checks the standalone audio contract; diagnostics checks shared job visibility.
No unfiltered or duplicate plain test pass, old-format matrix or long benchmark is requested.

The source closure is inherited from the accepted audio slice and adds this test file; all production
sources are built unchanged by the runner. A private APFS clone of that slice's build cache took
19.60 seconds. It reuses dependencies/objects, never cached passing results. The runner verifies coverage
instrumentation before discovery. Old copied raw profiles were removed before this run.

## Self-review

Checked extraction -> private staging -> atomic progress/vector save -> final version validation ->
publication -> query provenance/time; EOF/duplicate-only progress; cancellation and document interruption;
recipe/version/generation replacement; SQL parameter binding, scope/owner/private snapshot checks;
AV generator cancellation, scratch cleanup, bounded thumbnails and pressure/priority checkpoints.
Added monotonic checkpoint validation and limited requests to the video track range during review. Existing descriptor, ownership, permission,
model/tool and budget protections remain in the direct call chain. New pixels are only decoded by
that existing filesystem worker in production. No UI changes in this slice.

Coverage, timing, fingerprints and limitations are finalized after the focused run. Fixed vectors
verify identity/routing/persistence only; no real embedding quality, transcription, Release latency,
UI screenshot, long thermal stability or external time-opening result is claimed.

Rollback: revert the slice commit. The additive nullable column is harmless. The old recipe check
will cause affected videos to rebuild rather than mix incompatible vectors; compatible other media
need no reset.

## Results

The initial focused execution ran 20 methods in five suites: 19 passed, and the added
composition-only range fixture failed because its empty edit belongs to the video track and its
rendered timestamps are not source-sample timestamps. The fixture was replaced with an exported
MOV containing 6 seconds of video and 8 seconds of PCM audio. Only that failed method was retried:
1/1 passed. No production source changed during these test retries.

SwiftPM clears its codecov directory for a subsequent run, so the initial 19 passing methods lost
their raw counters before export. The small method retry's raw profiles were preserved; the smallest
containing `SemanticVideoFrameTests` suite was then run for coverage recovery: **5/5 methods passed**
(including both cancellation/preemption arguments). The initial other 15 passing methods were not
repeated. `final-match.json` confirms all **1117 production object hashes identical across retries**,
**2417 final source/tool/resource fingerprints match**, and the saved query MOV has the exact
recorded fixture hash. The earlier fixture result, failed logs, profiles and 0%-application partial
export are preserved in `before-suite-retry/`; the unattributed root profile is retained separately
and excluded from coverage.

Final changed executable line coverage against the declared baseline:

| Group | Covered / executable | Result |
| --- | ---: | ---: |
| Application | 62 / 62 | 100% |
| Filesystem helper | 73 / 74 | 98.65% |
| Independent media runtime | 0 / 0 | N/A, unchanged |

The single uncovered helper record is `SemanticVideoFrames.swift:92`, the function closing brace
following an infinite loop whose paths return or throw. No additional tests were added for it.
Coverage is line coverage from LLVM DA records intersected with Git added/modified source lines,
including new Swift files, not branch coverage. `application.lcov.gz`, `application.profdata.gz`,
raw profile archives, input checks and binary/object hashes provide the denominator and evidence.
Raw artifacts are gzip compressed for storage; decompress before feeding them to LLVM tools.

The 6-second MOV makes 13 sample attempts and retains frames at **0, 1.5, 2, 5.9 seconds**.
A query with a fixed blue-frame vector returns the persisted video hit at **1.5 seconds** after
reopening SQLite. The final request is 5.998333... seconds; the returned source frame time is 5.9.
The near-static variant alternates red values by 1/255, makes 13 attempts and retains **one** frame;
a completed cursor performs **zero** additional decodes. Cancel/document preemption after a
skipped duplicate persists next=1 and one encoded ordinal, then real IPC resume encodes only the
remaining distinct frames. The exported longer-audio MOV stops video at 6 seconds although the
asset duration is 8 seconds. These are real AVFoundation decode/IPC/SQLite results with synthetic
fixtures and fixed vectors, not a real-model quality claim.

Complete coverage-command wall times, including preparation/discovery/build/execution:

| Invocation | Seconds | Outcome |
| --- | ---: | --- |
| coverage-run | 129.79 | Copied Clang module cache had the old absolute path; no tests |
| cache-path-retry | 53.95 | Precisely interrupted build to finish video-track bounds review; no tests |
| final-coverage | 385.24 | Build 336.59 s; 19/20 methods, one fixture failure |
| track-range-retry | 138.43 | Build 83.37 s; failed method 1/1 passed |
| profile-recovery | 72.26 | Build 31.88 s; smallest suite 5/5 passed |

Total commands **779.67 s**, plus private cache clone **19.60 s** (799.27 s combined).
No cached passing result was used. The normal focused runner and explicit FILTER were used for
every invocation. No whole-project execution, Release/thermal benchmark or CI wait was performed.

New production files pass strict SwiftLint; new test file has one type-length diagnostic (263 lines,
limit 250). Existing changed production files retain six strict diagnostics versus six on baseline
(including the existing publication-method length, now 58 versus 56 lines). Compiler deprecation
warnings for synchronous AVFoundation APIs and existing weak-variable warnings remain visible in
logs. Python tool compilation and `git diff --check` pass. These are reported rather than called a
green lint/build-warning result.

Main advanced concurrently via unrelated PR637, merged at 01:51:03 UTC. This slice retains the
01:39 start baseline containing PR636 and reports its own exact reviewed/tested head through the PR
and handoff manifest; it does not claim the concurrent realtime-audio changes were tested here.
