# Screenshot visual/OCR corroboration

This slice continues draft PR648 from `6123227a25a9d0843bfdde02ba175fe835017630`. The fixed screenshot query now returns the **image** segment through production Store search, database reopen and service publication. The original error code still selects **image-ocr**. PR648 remains draft and unmerged; GUL-405/GUL-383 remain in progress. Actual 30/25-second audio-boundary and short-video scene/time retrieval are still required before full acceptance. GUL-406 was not read or started.

## Change and bounds

The reader reuses compatible persisted vectors in the same SQLite read snapshot. Among the existing bounded image candidates, it retains one best visual vector and one best OCR vector per versioned file. Each source must independently clear the existing 0.45 candidate floor. Their equal-weight unit-vector sum must clear the existing 0.70 absolute gate; the original scalar confidence remains available for single-modality files. No model, prompt, recipe, sampling, persistence or scalar threshold changed.

A pair grants confidence only to its own file. Duplicate OCR, repeated visual chunks and other files do not provide additional votes. Unversioned files, incompatible provenance/segment kinds, invalid norms and excluded paths cannot supply a pair. Number and quoted queries bypass corroboration and retain their exact lexical checks. Current metadata permission/version checks still run in the service before publication.

The additional scan is linear in the immutable pages and retains at most two 768-float vectors per ranking candidate (at most 100 candidates, about 600 KiB of vector values). It does not query the database once per reference or perform pairwise corpus comparisons. This is a query candidate budget, not an indexing/content quota. Single-file and repeated-chunk cases are explicit tests. No scale or resource matrix was rerun, so this slice makes no new latency or long-term resource claim.

For an image with no lexical evidence, script calibration no longer adds a text bonus to OCR. The stronger actual segment wins; exact OCR evidence keeps its existing priority. Text/audio ranking was retained and covered by the focused regressions.

## Frozen inputs and results

All vectors come from the prior real-model captures. There was **no new inference, screenshot encoding, native UI run or model loading**. The service test injects the retained real query vector and controlled current metadata; it exercises actual service/Store publication and version/access rejection. It is not live-model/UI evidence.

The unchanged query is `black text on a white background`. Production Float16 raw cosines remain image **0.693842411**, OCR **0.649659693**. Recomputing the product pair formula from those same compact values gives **0.706737557** (Float32 preflight 0.706735910), clearing the existing 0.70 gate. Store and reopened Store select chunk **1**, `image`, score **0.381613326**. The error code and matching quote return OCR; the wrong code and missing quote return nothing.

Preflight ran before production edits, using the original fixed vectors/labels. All **12** existing matching/nonmatching color pairs retain their single-modality outcomes, including the wrong blue-square/red-query cosine 0.698181987. They remain diagnostics, outside the no-answer denominator.

The final mixed Store contains the retained screenshot, all 75 original text sources and all 27 existing media sources. Every original **200** and existing media **106** query row is retained in `mixed-oracle.json`. Original no-answer **0/25** plus media no-answer **0/25** gives **0/50**. Supported Recall@5 is lexical 25/25, identifier 25/25, Chinese 25/25, cross-language 24/25, long-tail 25/25, image 6/6, audio topic 23/25, audio paraphrase 24/25, audio cross-language 25/25. The fixed screenshot also returns its image segment in that mixed Store.

The original 25 scanned-PDF and 25 media-timestamp labels remain in all 306 raw rows; those sources are absent from this historical fixed-vector corpus and remain known failures there. They are not silently counted as supported recall or removed from the original denominator. This replay does not replace the already accepted native document evidence or establish new live audio/video acceptance. The 50 negatives are also separately replayed on the original single-screenshot Store.

## Verification and timings

Final source/binary: **31 methods in five suites passed**. Command wall **6.458 s**, test execution **4.150 s**. The scope is the two new corroboration suites plus `SemanticSearchRankingTests`, `SemanticScoreCalibrationTests` and `SemanticLexicalSearchTests`: they cover the new rule, its actual service caller, exact rejection, language/audio ordering, committed-page invalidation, malformed data and WAL reader behavior.

```sh
python3 docs/validation/gul-383/optimization/visual-corroboration/evaluate.py
python3 scripts/test_groups.py --suite SemanticImageCorroborationTests --suite SemanticImageCorroborationServiceTests --skip-build
python3 docs/validation/gul-383/optimization/visual-corroboration/build_focused.py --cache-checkout <accepted-cache>
GUL405_VALIDATION_LABEL=final python3 docs/validation/gul-383/optimization/visual-corroboration/run_focused.py
python3 docs/validation/gul-383/optimization/visual-corroboration/coverage.py
swiftlint lint --strict --quiet Sources/Typeflux/Ask/QuickResults/Semantic/SemanticVectorReader.swift Tests/TypefluxTests/SemanticImageCorroborationTests.swift
git diff --check
```

The normal runner had no matching verified build (0.52 s); it executed no tests. To respect the no-rebuild constraint for accepted helpers, the focused builder compiled only the changed production primary and new tests, then linked the accepted remaining Debug objects. It never modified the accepted checkout. It uses the accepted declaration closure rather than rebuilding the app/helper or re-enumerating the old 2448-input inventory. Direct relevant source identities are checked separately.

All compile/link commands, return codes and subprocess durations are in `build.json`: the initial frontend attempt failed because the macro plugin path was absent (5.980 s); adding the toolchain plugin path fixed it. That first stderr file was overwritten by the successful retry; its command, exit code and duration remain in the phase record. The first test compile exposed a missing inner `try` (0.946 s), then passed. Subsequent builds followed additional test completion and lint fixes. Total recorded compile/link subprocess time is **39.682 s**; wrapper startup/metadata overhead for those build invocations was not separately timed. No phase duration is described as full build-command wall time.

The first helper-based execution selected 31 methods but its legacy module filter actually ran only the existing 21 (command 5.180 s). Checking the log exposed the omission; `run_focused_initial.py` preserves that runner and the current runner uses exact module-aware method filters. The separately executed 10 new methods took 1.269 s and found one fixture failure: writing NULL version violated the fixture's database contracts. Using the supported empty-version representation fixed it; only the failed parameterized method was rerun (1.732 s). Strict lint then found short names, a nested DTO, forced test casts and long lines; these were corrected without changing the rule. The final primary/test rebuild and corrected complete **31-method** run passed. Earlier failures, commands and logs remain available; the final coverage uses **only final-run process profiles**.

Changed application executable-line coverage is **56/58 (96.55%)** against the incoming head, intersecting changed lines with LLVM LCOV `DA` records. The two uncovered lines remove the weakest file when the candidate set exceeds its existing budget; no tests were added merely to raise this percentage. Native inference helper/file helper/media runtime are **0/0 N/A** in this slice. Earlier PR648 application 3/3 and native helper 4/4 evidence remain referenced in the preceding slice; they are not relabelled as measurements from this run. Strict lint and `git diff --check` pass; exact command durations are in `final-static-checks.json`.

## Self-review and retention

Reviewed the complete query-to-Store-to-service-publication path, the same-file/version identity, single modality and repeated chunks across page boundaries, normalization, provenance, exact number/quote gates, scope exclusion, stale version, revoked metadata access, cancellation, read transaction/statement cleanup and unchanged priority/resume behavior. Self-review added the nonempty-version requirement and finalized the test metadata statement before asynchronous service work. No worker, model, lifecycle, download or sampling code changed.

The prior diagnosis and failed fixed capture are preserved in `media-isolation/visual-diagnosis/`. This directory retains preflight and final raw rows, test/build/lint failures and successes, actual final-binary hash, final profiles/LCOV and a local relevant-source/tool/artifact manifest. The binary is delivered as a separate attachment, rather than checked into Git. Only synthetic content and fixed synthetic oracle inputs are used. All run-owned subprocesses were collected; the service test clears its state and uses an inert watcher. No agent or service was started in the background.

Rollback is to revert the reader change; existing compatible vectors remain usable because no persistent recipe or schema changed. The earlier CPU/QoS helper corrections in PR648 can remain independently.
