# GUL-405: offline HTML body slice

Based on main `3d29741d9352c047f5fdb06507187b1becd16626`, including merged PRs #595 and #598. This is a partial delivery of GUL-405. RTF remains the next short document slice; GUL-406 remains parked.

HTML/HTM now enter the existing disposable content reader and durable index. The scanner reads at most 8 KiB of source at a time, keeps a bounded tag/entity state, and returns at most 32 KiB of UTF-8 logical body text with the existing overlap cursor. It shares the existing offline entity decoder and excluded-tag rules. It handles headings, paragraphs, lists, tables, quoted attributes, comments, Unicode and common numeric/named entities. Scripts/styles are skipped as raw text; metadata, navigation, templates, frames and objects are omitted. No browser, rich-text importer, URL/resource loader, script executor or embedded-object opener is used.

Offsets describe UTF-8 bytes in normalized extracted text; no page number is invented. Existing file identity/version, scope, cancellation, worker deadline and resource ownership checks remain authoritative. New jobs record a separate HTML recipe. Because supported formats already participate in both discovery keys, an upgrade revisits completed folders and admits HTML without invalidating compatible text/PDF/DOCX vectors. Long bodies remain partial until their final source read. Restart replays the source prefix to the logical cursor, but never re-encodes committed chunks. Memory is bounded by the source/output buffers, rather than total source size. Prefix replay can still hit the existing worker deadline on very large files.

This is a common-body tokenizer, not a full HTML5 layout/CSS parser. It does not evaluate CSS visibility, perform browser error recovery, derive rendered geometry or supply external-reader positioning. It accepts UTF-8 (including BOM); UTF-16/32 BOMs retain `unsupported-document`, while invalid body UTF-8/control bytes retain `unreadable-content`. It does not apply legacy charset declarations. Entities reuse the existing finite offline decoder; unknown names remain literal. HTML remains in its existing file-type classification; content search is available in All, while the existing Code mode does not run semantic body queries. Native preview/open integration remains a later GUL-405 slice.

## Validation

The reviewed fixture closure and existing Swift 6.4 coverage shim are included. The normal focused runner is used with explicit suites; coverage replaces a plain test pass.

```bash
mkdir -p .build/gul405-html-bin
cp docs/validation/gul-383/optimization/html-body-slice/coverage-swift.sh .build/gul405-html-bin/swift
chmod +x .build/gul405-html-bin/swift
PATH="$PWD/.build/gul405-html-bin:$PATH" \
TYPEFLUX_GUL405_TEST_FILES="$PWD/docs/validation/gul-383/optimization/html-body-slice/test-files.json" \
TYPEFLUX_GUL405_HTML_EVIDENCE="$PWD/docs/validation/gul-383/optimization/html-body-slice" \
TYPEFLUX_COVERAGE_SCRATCH="$PWD/.build" \
make coverage SUITE="SemanticHTMLTextTests SemanticWordTextTests SemanticPDFOCRTests SemanticFilePolicyTests SemanticFileStoreTests SemanticFileContentTests SemanticFileIndexerTests SemanticIndexDiagnosticsTests SemanticReaderOwnershipTests SemanticScanAdmissionTests SemanticDiscoveryPauseTests"
```

The new suite covers real disposable-worker reads, long Unicode continuation, store/worker restart, durable index-to-body-query evidence, old completed discovery, compatible-vector retention, cancellation, version replacement, permission revocation, persistent failures/retry, invalid cursors, empty bodies, malformed entities/tags and source-buffer boundaries. It also exercises the existing offline HTML caller after sharing the entity rules. Word/PDF suites guard the shared dispatch, and the policy/store/index/diagnostic/discovery/ownership suites cover directly affected callers. Embeddings in these functional tests are deterministic. No new real-model Recall/MRR, native UI, input-to-result latency or long-term thermal claim is made.

All **48 selected methods passed**: nine XCTest methods and 39 Swift Testing methods across eleven suites. The first instrumented build took **279.22 s**, build/discovery **325.09 s**, and the focused runner's complete preparation-through-test command **344.73 s**. Including final LLVM/HTML report generation, the redirected output spans **352.22 s** from log creation to its last line; shell spawn overhead was not separately timed. There were no failed builds or test retries. Final formatting and the literal-less-than self-review fix were saved during dependency preparation, before product compilation. Product hashes match the frozen manifest.

Changed executable lines: **application-only 4/4 (100%)**, **shared content reader/offline rules 179/184 (97.28%)**, combined **183/188 (97.34%)**. The denominator intersects added/modified lines with LLVM LCOV executable line mappings, rather than whole-project or branch coverage; constants without a DA mapping are exercised by behavioral assertions but add no executable line. Native media/inference helper source has zero changed lines. Five uncovered reader lines are heading emission, raw-end-tag whitespace/near-match handling, and the entity-at-EOF fallback. The first three behaviors are exercised in the real native-worker fixture, whose child-process counters are not included in the test binary's LCOV export; these remain correctly marked uncovered. See `changed-coverage.json`, `changed-source.lcov` and `coverage-provenance.json` for exact paths and hashes. No coverage-driven re-run was performed.

Strict lint passed for the new helper/parser/test and all other touched semantic/test files. Whole-file lint on the existing `AskLocalWebTools.swift` retains **28 pre-existing violations**; the two changed executable lines have none. `git diff --check` passed. The host is arm64 Mac16,10 with 16 GiB RAM, Apple Swift 6.4; binaries are instrumented Debug. No full historical matrix or external CI polling was run.

The foreground reader probe completed **300.09 s**, **2711 requests**, with **zero missing identifiers**, worker exit 0. Request p50/p95/p99 were **1.14/1.58/2.21 ms**, peak worker RSS **56.97 MiB**. It repeatedly reads one small synthetic HTML file, sequentially at nice 10 with 100 ms pauses; OS/parser caches can be warm. No test/build ran concurrently in this task, although the host and its running applications were not reserved. This measures only bounded reader requests, not indexing throughput, model quality, UI/search latency, GPU contention or long-term thermal stability. Raw samples are in `html-resources.json.gz`; the summary and script are included.

```bash
LLVM_PROFILE_FILE="$PWD/.build/html-resource-%p.profraw" \
python3 docs/validation/gul-383/optimization/html-body-slice/html_resource_probe.py \
  --binary .build/arm64-apple-macosx/debug/Typeflux \
  --fixture docs/validation/gul-383/optimization/html-body-slice/synthetic-body.html \
  --seconds 300 \
  --output docs/validation/gul-383/optimization/html-body-slice/html-resources.json
```

## Self-review and remaining work

Self-review traced reader → logical batches → durable FTS/checkpoint → vectors → body-query evidence. It checked scope/version revalidation, cancellation before publication, retry after failure, additive discovery migration, bounded memory, descriptor ownership and resource isolation. It fixed recursive malformed-entity handling, separators around omitted subtrees, and literal less-than text before validation. New and changed product/test lines pass lint; whole-file lint also reports pre-existing violations in `AskLocalWebTools.swift`, recorded separately in `lint.json`.

Remaining required GUL-405 work: RTF, XLSX/PPTX/ODT and explicit legacy Office handling; mixed-page/screenshot OCR and geometry; audio overlap/silence and resumable deduplicated video sampling; location-aware preview/open actions from both entries; per-category partial/failure retry; Range/ETag/checksum download recovery. Real-model new-content evaluation, native UI evidence and final end-to-end regression remain outstanding. This slice must be independently reviewed; it does not complete GUL-405.

Rollback: revert this PR or disable the existing experimental switch. Reverting the format list changes discovery keys and triggers a scoped rescan; no destructive schema/model migration is introduced.
