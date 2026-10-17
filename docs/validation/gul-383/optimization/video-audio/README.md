# Embedded video audio and media location actions (GUL-405 slice 15)

Baseline: `9021ea52fc2696965e0c8a18cbe678f766038f3f` (PR638 merged main).
**Partial checkpoint: embedded-audio verification passes; two media-location methods still fail.**
This is a draft for continuation, not an accepted or complete slice.

This slice reuses PR636 audio windows, PR638 frame checkpoints, and PR633 location actions.
It does not complete GUL-405 or start GUL-406.

## Behavior

Video audio uses the same 30-second windows / 25-second stride and conservative near-digital
silence filter as standalone audio. Audio progress advances independently of frame ordinals;
non-silent window vectors and progress commit in one existing transaction. The audio track's
start/end, rather than the video or whole asset duration, bound its timeline. Completed frame
progress bypasses image generation on audio retries, including after cancellation, document
preemption and reopening SQLite. EOF cancellation leaves private progress unpublished.

Only the video's combined job recipe changes. Its existing frame-vector recipe stays compatible;
new embedded audio uses the standalone overlapping-audio vector recipe. The query reader's
existing modality/provenance filter excludes legacy non-overlapping embedded audio. Same-version
published frames are copied inside the job transaction and marked complete. Partial legacy video
jobs retain frame segments/checkpoints, drop old audio, reset audio progress and change generation
to reject late old-generation writes. Standalone audio, document and screenshot recipes stay intact.

Both launcher entries retain the hit's stored time/version/chunk and offer View Match Location.
Default/specified-app opens and Quick Look use the original file and explain that external seek
is unverified. In-app preview reuses the existing start option, validates time, kind and version,
and falls back to the beginning for obsolete/non-finite evidence. The track-bound exception below remains unresolved. Audio-window matches inside videos
use the existing waveform preview, including audio extending beyond the video track. The existing
settings/scope/permission/current-selection checks and preview cancellation/version rechecks remain
in the path. Listing an invalid timestamp cannot trap during integer conversion. All five existing
locales include the capability text. No player or external URL protocol is introduced.

## Focused verification

The single requested coverage scope is:

```sh
python3 docs/validation/gul-383/optimization/video-audio/run-coverage.py
```

This invokes `make coverage` with the explicit FILTER:
`SemanticVideoAudioTests|SemanticAudioWindowTests|SemanticMediaIndexTests|AskMediaLocationTests|AskFilePreviewLoaderTests`.
The new suite covers real track decode, boundary/silence/EOF, real IPC cancellation/preemption,
reopen/query, migration and generation invalidation. Direct callers include standalone audio
(shared extractor), media publication/query (shared store), both launcher action routes, and
preview cache/cancellation/version ownership. Native key events exercise both launcher entries;
light/dark images are rendered from the actual shared preview and OCR-check the capability text.

The three new MOVs are frozen copies of PR638's JPEG video stream, muxed once with synthetic
16 kHz float PCM; tests verify hashes and copy bytes, without writers, exporters or retries.
`generate-fixtures.py` and `fixture-manifest.json` record generation and identity. The delayed audio
starts at 7.5 s and ends at 38.5 s. AVFoundation includes the leading empty edit in the track range; extraction now starts at the first non-empty target segment. Boundary audio spans 29–31 s; silent-prefix audio spans 52–54 s.
Fixed vectors establish identity/routing/persistence only, not embedding or transcription quality.

The first command failed before tests because an APFS copy of the previous build included
Clang modules bound to the old checkout path. Its complete log and 85.18-second command record
are retained. The copied module cache was moved aside locally; the same FILTER is used for the
build retry. No sibling checkout or prior evidence was modified. Final command results, changed
executable line coverage, binary/profile/input fingerprints and full logs accompany this report.
Strict lint passes on the new tests, new migration helper and core location/preview files. The
file plugin retains three pre-existing strict-lint diagnostics on unchanged lines 67/73/157;
`lint-preexisting.json` confirms these lines match the baseline. Python compilation and diff checks pass.

## Self-review and limits

Reviewed extraction → private vector/progress transaction → metadata validation → publication →
query → two action entries → current-version preview. Checked silent windows without ordinals,
EOF, delayed track start, frame/audio stage independence, cancel/preemption, old generation rejection,
version changes, invalid timestamp formatting, permission/current-selection revocation, snapshots,
descriptor/reader cleanup and localization. During review, corrected the missing audio cursor,
stale generation reuse, unvalidated preview time and invalid timestamp integer conversion.

The supplied native tests intercept NSWorkspace/Quick Look dispatch and verify the original URL,
notice and retained hit. They do not prove that an external application displayed a given time.
No real model, Release performance, sustained stability, new format matrix or full test run is
claimed. Prior accepted evidence is not rerun as a broad gate. Per-item partial/failure retry,
Range/ETag/checksum download recovery and necessary real-model/native-input short acceptance
remain in GUL-405 for subsequent authorized slices.

Rollback: revert this slice. The prior job recipe queues affected videos again; generation and
provenance checks prevent treating incompatible audio as current. Private caches may be discarded.

## Final checkpoint results (not acceptance)

Across executions, **29 of the 31 selected methods have passing executions; two remain failed**.
This is not a single final-binary 29/31 run. The last four-method retry passed the full real-track
method (all three arguments, including delayed audio) and the native preview/version/fallback
method (light and dark); the two methods below still fail. Existing real IPC cancellation and
document-preemption cases, silent progress, EOF cancellation, recipe migration/stale generation,
media index and preview loader methods have passing executions retained in the earlier logs.

| Command record | Complete wall seconds | Outcome |
| --- | ---: | --- |
| coverage-run | 85.17828 | copied Clang module-cache path error; no tests |
| coverage-build-retry | 487.51127 | initial 9 methods passed; OCR assertion failed; bad metadata force-unwrap aborted remaining execution |
| coverage-method-retry | 150.21559 | 18/22 passed; 4 methods failed |
| coverage-final-retry | 151.77454 | 2/4 passed; 2 still fail |

Complete coverage-command wall time is **874.67968 s**, including preparation/discovery,
builds and all failures/retries. Build phases recorded 393.35/63.67/88.80 seconds after the first
cache failure. No plain duplicate pass or full suite was run. The last two retries use explicit
minimal FILTERs in their JSON command records. Current profiles are exported with their matching
binary. Counters from `before-final-fixes` are reused only for files whose source SHA and production
object SHA both still match; changed extractor and renderer counters come only from the final run.
`coverage-reuse.json` documents this boundary. Source/tools/models/fixtures/profiles and current
executable hashes are retained; weights were never loaded.

Unresolved:

1. `audioPreviewAndBothActionRoutesKeepTimeAndRevokeOwnership`: waveform, original-URL opens,
   notices and preview assertions pass, then the fixture sees a current selected hit while
   `plugins.output` is still nil. The test must await the completed output before reading actions.
   No fix has been applied or claimed validated for this final failure.
2. `embeddedAudioMatchBeyondVideoTrackUsesExistingAudioPreview`: the real audio-window match at
   seven seconds correctly returns waveform/start=7 in the original eight-second MOV with six-second
   video. A deliberately invalid video-frame time=7 does not return start=0: the existing decoder
   can return an earlier frame with the requested time label. The new thrown-error fallback is
   insufficient for this non-throwing path. Fix/verify the bounded preview-time contract without
   adding a player or guessing external URL schemes. This is an unresolved product limitation.

The initial screenshot failure was a wrapped OCR phrase; both original images visibly showed
its text. The second exact OCR phrase was also brittle; the final test checks the visible single-line
“match location” phrase in both appearances, with manual image verification of the full capability
text. Audio preview tests originally used a lifecycle-owned default worker without a running app;
explicit disposable workers now exercise the actual helper. These fixture/oracle failures and the
original sources are retained, rather than presented as product decoder failures.

Self-review therefore found and fixed embedded-cursor/timeline/generation issues and invalid numeric
formatting, but **does not conclude that the media-location action slice is complete**. GUL-405 and
its parent remain in progress; no merge or GUL-406 start. The draft PR, full failed results and this
save point are the handoff required by the approximately 30-minute limit.

Changed executable line coverage (not functional acceptance): application **78/83 (93.98%)**, filesystem helper **20/21 (95.24%)**, native media runtime **0/0 N/A**. Uncovered line numbers are in `changed-coverage.json`; threshold >=70% is met, but the two red methods prevent acceptance.
