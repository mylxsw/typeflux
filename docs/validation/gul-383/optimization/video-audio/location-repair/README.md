# PR642 media-location repair

Both failed methods from `5eb07cae46f27498ec007af8c1db039f75addae3` pass after this repair.
This updates the same draft PR642. GUL-405 and its parent remain in progress; no merge or
GUL-406 start is part of this handoff. The attached handoff manifest records the final head.

The plugin fixture now waits for the current plan, selected hit and completed output's
View Match action together. Its ownership, stale-action, permission-revocation and close
assertions remain. No production plugin timing or waiting budget changed.

The isolated `MediaAVDecoder` checks the video track range before generating a raster.
It requests zero time tolerance and validates the generator's actual time against the track
and requested time (within the existing 1/600-second request resolution). A rejected match
uses the existing host retry at zero, which performs another real decode. Protocol identity,
host isolation, cancellation handlers and version/permission checks remain in the path.
No new player, external seek protocol or metadata-only start-time substitution was added.

The existing eight-second MOV has six seconds of video. The repaired integration method checks:

- Audio-window time 7 retains its waveform and start=7.
- Video-frame time 7 falls back to start=0, with pixels identical to a separately decoded start frame.
- Valid time 1.5 retains its distinct frame and time.
- Time 1.55, between actual frames, rejects a nearby frame and shows the real beginning instead.

The production helper strips profiling environment variables. `verify-helper.py` therefore
checks only the new helper contract directly, using the same frozen MOV: time 1.5 returns a
raster; times 7 and 1.55 return `unreadable` without a raster. It separately captures the
helper's counters. The host bridge and user-visible fallback are covered by the two Swift methods.

## Verification

```sh
python3 docs/validation/gul-383/optimization/video-audio/location-repair/run-coverage.py --name coverage-repair
python3 docs/validation/gul-383/optimization/video-audio/location-repair/verify-helper.py
python3 docs/validation/gul-383/optimization/video-audio/location-repair/run-coverage.py --name coverage-final
python3 docs/validation/gul-383/optimization/video-audio/location-repair/collect.py
```

The runner defaults to the two previously failed methods only:
`AskMediaLocationTests/(audioPreviewAndBothActionRoutesKeepTimeAndRevokeOwnership|embeddedAudioMatchBeyondVideoTrackUsesExistingAudioPreview)`.
Both coverage runs selected and passed exactly two methods. Complete command walls were
125.63086 s and 72.40227 s (198.03314 s total), including build/discovery/runner/HTML export.
Build phases were 65.83 s and 28.66 s. The second run follows resolution of five localization
append conflicts: this slice's new strings moved before the existing PDF block. Parsed key/value
maps are identical in all five locales (`localization-order-only.json`). No main-only feature
was integrated and no test scope was expanded. The direct helper command passed 3/3 cases in
0.27444 s of recorded script wall time, without another build.

Strict SwiftLint passes for `MediaAVDecoder.swift` and `AskMediaLocationTests.swift`.
The initial function-length diagnostic is retained in `lint.log.gz`; extracting the native
video operation into a private method fixed it before the first test. Python compilation,
localization parsing/equality and `git diff --check` pass. No new test failure occurred.

Changed executable lines against the original PR baseline `9021ea52fc2696965e0c8a18cbe678f766038f3f`:

| Component | Covered / executable | Percent |
| --- | ---: | ---: |
| Application | 81 / 83 | 97.59% |
| Filesystem helper | 20 / 21 | 95.24% |
| Native media runtime | 26 / 26 | 100% |

This is LLVM line coverage, not branch coverage. Uncovered lines are
`AskComposerViews.swift:969`, `AskQuickActions.swift:124` and `SemanticMediaExtractor.swift:171`.
No tests were added for closing braces or to raise coverage beyond the 70% threshold.

`application-profiles` contains only the final run; `first-pass-application-profiles` keeps
the earlier successful run separate. `native-helper` profiles belong to the independently
fingerprinted actual helper binary. The collector rejects source drift during testing and
helper-binary drift since contract capture. For unchanged application/filesystem-helper files,
older counters are admitted only when both source SHA-256 and production-object SHA-256 match;
`coverage-reuse.json` lists every decision. Old media-runtime counters are not reused.

`inputs-final.json` freezes source/package/tool inputs; `objects-final.json` includes every
target's production objects. `binaries-final.json` records the actual application, test,
media-helper and inference-helper executables. Tool binaries, validation scripts, six MOVs,
environment and raw/profile hashes have separate manifests. Raw profiles, LCOV and merged
profiles are retained compressed. Original failures and command records remain in the parent
evidence directory; its 29/31 historical passing executions are still cross-run records,
not a claimed final-binary 31-method run.

The final freeze contains 2,418 source/package/tool inputs and 2,300 object files. Application,
test and helper executable hashes are unchanged by the localization reordering
(`final-verification.json`). `inputs-before.json` is an intermediate pre-lint snapshot;
`inputs-first-pass.json` describes the first successful pass, and `inputs-tested.json` matches
the final tested resources exactly.

## Self-review and remaining scope

Reviewed request → private copy → track validation → actual frame → protocol validation →
host fallback → displayed time, plus plugin current-plan/action ownership. Checked non-finite
evidence, track end versus asset duration, unchanged longer-audio waveform, cancellation,
generator/reader cleanup, private-file cleanup, stale/version/permission protection and locale
consistency. The existing host version/cache checks and audio path need no production changes.
The repair closes the two known failures. Native keyboard and light/dark evidence from the
checkpoint remain applicable to unchanged production routes/text; no new visible message was added.

Per-item partial/failure retry, Range/ETag/checksum download recovery and necessary real-model/
native-input short acceptance remain later GUL-405 slices. This repair used fixed vectors and
synthetic media, loaded no model weights, and adds no performance or sustained-stability claim.
External file opens still do not promise a seek. Rollback: revert the repair commit, or revert
the full PR to restore the preceding video/audio recipe behavior.
