# PR638 fixture readiness repair

This repair replaces the test-time AVAssetWriter/AVAssetExportSession generators with private copies
of the three real MOVs already committed at `f9c7aed270e7d4a399d487d5081345907933a2ad`.
Only `SemanticVideoFrameTests.swift` changes among the 2417 frozen source/tool/resource inputs.
Production source, all 1117 production objects, four compiler/LLVM tools and the original
production coverage evidence remain unchanged. The existing PR is updated; no next slice starts.

## Fixture origin

These are the original synthetic AVFoundation JPEG MOVs generated for this PR on the recorded
Apple M4 / Debug coverage environment. They are real container/codec inputs, not simulated decode.
The short/static scenes are 64x64, six seconds at 10 fps; the short scene has a 0.7-second blue
slide and a green final frame. The static scene alternates red by 1/255. The third MOV was exported
from that six-second video plus eight seconds of PCM audio and retains distinct track bounds.

| Fixture in the parent evidence directory | SHA-256 |
| --- | --- |
| short-scene.mov | `7db4b38eca51b68f458481fee84c1aa5a3e119e5e29d9faf166a035bbd99ddd2` |
| static-scene.mov | `263f17d7cdaae6f671ded7c07a83ca22429151f5f0a1f05414fa4bdbbf31093e` |
| longer-audio.mov | `902e4d62bc5f6b745963c89766e680b917a8cd1104c9ef733f698b31d73195ec` |

Tests resolve fixtures relative to their compiled source path, require the expected digest before
copying into each test's disposable directory, and propagate missing/corrupt/copy failures through
Swift Testing. There is no encoder polling, sleep, append to an unready writer or retry-to-green
loop. Running the test binary requires its corresponding source checkout and these tracked files.

## Focus and self-review

All five method bodies retain their production assertions: real short-scene/tail decode and actual
time -> persisted SQLite -> query, near-duplicate progress and no further decode at EOF, real IPC
resume after cancellation and document preemption (both arguments), video-vs-audio track bounds,
video-only recipe migration, stale-generation rejection and transaction rollback. Only generation
and evidence copies of already frozen MOVs were removed. Fixed vectors still prove frame identity
and search plumbing, not real-model quality. The prior 15 passing related methods are not repeated.

Reviewed entry-to-query flow, hash/missing-file failure paths, temp cleanup, cancellation/preemption,
generation/rollback, concurrency isolation, source-relative fixture resolution and consistency of
the old evidence. There is no new asynchronous writer/exporter lifecycle. Paths are selected only
from the fixed digest map. Scope/privacy checks and all production code remain unchanged.

## Evidence and commands

The original two independent fixture SIGABRTs (11.70485 s and 2.40457 s, zero builds) are preserved
under `original-arch/`. They happened before production decode and establish no production failure.

The first repair validation exposed an incorrect digest display comparison: CryptoKit's
`description` includes a prefix. Four methods stopped before decode; migration/rollback passed.
Its 93.02461 s command (54.24 s build), full log, failed test source and raw profiles are preserved
in the parent `fixture-repair-validation.*` and `hash-format-failure/`. The comparison now uses
standard lowercase hexadecimal. The retry selects only the four failed methods:

```sh
python3 docs/validation/gul-383/optimization/video-frames/run-coverage.py \
  --filter SemanticVideoFrameTests --name fixture-repair-validation
python3 docs/validation/gul-383/optimization/video-frames/run-coverage.py \
  --filter 'SemanticVideoFrameTests/.*(short scene|cancel or document|static and near|video track stops).*' \
  --name fixture-repair-retry
python3 docs/validation/gul-383/optimization/video-frames/fixture-repair/collect.py
swiftlint lint --strict Tests/TypefluxTests/SemanticVideoFrameTests.swift
git diff --check
```

`collect.py` verifies the original production objects/tools/fixtures, freezes the new binary and
2417 inputs, validates and compresses raw counters, and exports current-binary LCOV/profdata.
The original production coverage remains applicable: application 62/62 (100%), filesystem helper
73/74 (98.65%), media runtime 0/0 N/A. The single uncovered helper closing brace at
`SemanticVideoFrames.swift:92` needs no further test under the >=70% acceptance threshold.

All previous evidence stays in the parent directory; the new manifests in this directory describe
the repaired test source and binary. Final head and artifact hashes are supplied in the handoff
archive, outside the commit to avoid a self-referential commit hash.

## Final results

The four failed methods passed on the single minimal retry, including both recovery arguments.
The unchanged migration/rollback method passed in the first run; `final-match.json` records its
unchanged body hash. Thus all five methods have passing executions; this is not reported as a
single final-binary 5/5 run. No other previously passed methods were rerun.

| Invocation | Complete command wall time | Build time | Result |
| --- | ---: | ---: | --- |
| fixture-repair-validation | 93.02461 s | 54.24 s | 1 pass, 4 fixture digest-display failures |
| fixture-repair-retry | 148.94113 s | 62.20 s | 4/4 pass, including 2 recovery arguments |

Total new coverage-command wall time is **241.96573 s**, including preparation, discovery,
incremental test builds, execution and coverage rendering. The passing method execution takes
4.635 s (runner execution 13.06 s); these are not substituted for command wall time. Build logs
compile the changed test object and relink tests; every production object is byte-identical.

The repaired fixture's changed executable test lines are **16/16**. The four-method retry alone
covers application 61/62 and filesystem helper 73/74 production changed lines. The omitted
application guard (`SemanticFileStore+VideoProgress.swift:24`) is exercised by the unchanged
migration/rollback method and covered by the preserved original 62/62 profile. Original profiles
are reused with their original binary/object hashes; they are not merged with the repaired test
binary's counters. The original accepted production coverage remains application **62/62**,
filesystem helper **73/74**, media runtime **0/0 N/A**, all satisfying the applicable >=70% gate.

`results/` captures the new real-decode records: short-scene query time 1.5 s, actual retained times
0/1.5/2/5.9 s; near-static 13 samples/1 retained frame; completed resume zero decodes; both
cancel/preemption paths persist next=1 and resume via IPC without repeating the first embedding.
The frozen longer-audio MOV remains eight seconds with a six-second video track.

All 2417 input fingerprints are frozen (one test file changed), 1117 production objects and four
tools match, all three original MOV hashes match, and two new raw profiles validate and export
against the new instrumented binary. The discovery-created root `default.profraw` is retained
separately as unattributed and excluded from export. Strict lint of the repaired test file passes
with zero violations; the earlier type-length warning disappears after removing the generators.
Existing synchronous AVFoundation and SwiftPM build-system deprecation warnings remain in logs.
Python compilation and `git diff --check` pass. Full logs are gzip compressed without truncation.

No merge, GUL-406 start, real-model acceptance, new UI/player integration, Release performance or
long stability claim is made. GUL-405 remains in progress. Embedded audio overlap/silence recovery,
media time opening/fallback, per-item partial/failure retry, Range/ETag/checksum recovery and the
necessary real-model/native-input checks remain for subsequent authorized slices.
