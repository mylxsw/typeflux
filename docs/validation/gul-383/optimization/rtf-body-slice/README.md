# GUL-405: offline RTF body slice

Based on main `d04f94c1eab06f360fdfd592bbf0e6818f50b4b6`, including merged PRs #595, #598 and #601. This is the fourth partial GUL-405 slice. GUL-405 stays in progress; GUL-406 stays parked.

RTF now enters the existing disposable reader and durable document index. The parser uses an 8 KiB source buffer and at most 32 KiB of logical UTF-8 body per response, with the existing scalar-safe overlap cursor. Paragraph/line breaks, table separators, escaped braces/backslashes, common punctuation, scoped Unicode fallback counts and UTF-16 surrogate pairs are supported. Legacy body bytes support Windows code pages 1252, 936 (GBK) and 950 (Big5), including common font charset overrides. Font tables provide encoding metadata only. Images, objects, field instructions, header/footer metadata and optional destinations are skipped as data. Visible field results remain body text. No importer, external URL loader, decoder for embedded objects, script execution or upload is introduced.

The existing held-descriptor identity/version checks, scope/permissions, cancellation before publication, worker deadline and lifecycle owners remain authoritative. Logical offsets are UTF-8 bytes in extracted body text, without invented page numbers or geometry. A distinct RTF recipe is recorded in jobs and diagnostics. Supported extensions already participate in discovery and event checkpoint keys, so completed folders are rediscovered while compatible text/PDF/DOCX/HTML vectors retain their existing recipes. No model-space or destructive schema migration is introduced.

Long bodies replay the source prefix to reach their persistent logical cursor, with bounded memory; committed vectors are reused. Very large prefixes can hit the existing worker deadline. There is no single-file length, total-chunk or directory-entry quota. Parser complexity is bounded to 256 nested groups and 1024 explicit font encodings; over-complex syntax is `unsupported-document`. The parser accepts RTF version 1. Unsupported document code pages, Mac/PC character sets and alternate `upr` representations retain that fixed reason. Unsupported font encodings are rejected if non-ASCII bytes need them; Unicode remains readable. Malformed syntax, byte sequences and surrogate pairs retain `unreadable-content`. This is common body extraction, without full RTF rendering, page layout, complete destination coverage or RTFD package support. Native preview/open positioning remains a later slice.

Control-word assumptions follow Microsoft's [RTF specification](https://learn.microsoft.com/en-us/previous-versions/office/developer/office2000/aa140277(v=office.10)) and [plain-text RTF encoding rules](https://learn.microsoft.com/en-us/openspecs/exchange_server_protocols/ms-oxrtfex/1e44fa4c-3ea3-402c-8b21-fb19a617e43b). The implemented subset and fixed rejection reasons above define this slice's support boundary.

## Validation

The reviewed test closure extends the previous HTML slice by one RTF suite, using the same Swift 6.4 coverage shim. No full test run or duplicate plain-test pass is used. Command and exact timing are recorded in `validation-command.json` and `validation-timing.json`.

```bash
mkdir -p .build/gul405-rtf-bin
cp docs/validation/gul-383/optimization/html-body-slice/coverage-swift.sh .build/gul405-rtf-bin/swift
chmod +x .build/gul405-rtf-bin/swift
PATH="$PWD/.build/gul405-rtf-bin:$PATH" \
TYPEFLUX_GUL405_TEST_FILES="$PWD/docs/validation/gul-383/optimization/rtf-body-slice/test-files.json" \
TYPEFLUX_GUL405_RTF_EVIDENCE="$PWD/docs/validation/gul-383/optimization/rtf-body-slice" \
TYPEFLUX_COVERAGE_SCRATCH="$PWD/.build" \
make coverage SUITE="SemanticRTFTextTests SemanticHTMLTextTests SemanticWordTextTests SemanticPDFOCRTests SemanticFilePolicyTests SemanticFileStoreTests SemanticFileContentTests SemanticFileIndexerTests SemanticIndexDiagnosticsTests SemanticReaderOwnershipTests SemanticScanAdmissionTests SemanticDiscoveryPauseTests"
```

The RTF suite covers real child-process reads, Unicode batch reconstruction, durable worker/store restart and index-to-body-query evidence, completed-folder discovery and compatible vector retention, stable failure reasons/retry, cancellation/version replacement/permission revocation, Chinese code pages/font changes, binary payload skipping and malformed syntax. HTML/DOCX/PDF cover the directly shared dispatch; policy/store/index/diagnostics/discovery/ownership suites cover affected callers. Functional embeddings are deterministic. Existing model-quality and UI/performance evidence remains tied to its original source/model/tool fingerprints; this slice makes no new real-model Recall/MRR, UI, input-to-result latency or long-term thermal claim.

The initial **55-method** focused run completed in **367.30 s** (first build **326.24 s**, build/discovery **353.51 s**, runner **366.36 s**), with **54 passes and one stale DOCX test assertion** that still listed RTF as unsupported. All seven RTF methods passed. The stale exclusion was removed without changing product sources. A method filter initially matched no discovery IDs (**60.45 s**, zero tests executed); the corrected command below selected and passed exactly one method (**54.81 s**, including **22.70 s** cached build/planning, **43.60 s** discovery/build, **50.31 s** runner). All **55 selected methods now have passing results**. There were no functional build failures, one failed-method test retry, and no duplicate full-scope execution.

```bash
# Same environment and source closure as above:
make coverage FILTER="SemanticWordTextTests.*old"
```

Changed executable lines: **application-only 3/3 (100%)**, **shared reader/dispatch 206/206 (100%)**, combined **209/209 (100%)**. The denominator intersects added/modified Swift lines with LLVM LCOV DA mappings, excluding tests and unchanged code. Constants without executable mappings are exercised by policy/recipe behavior assertions. This is line coverage, not branch coverage; no claim is made that every exceptional branch was induced. Native media/inference helper source has zero changed lines. Initial raw counters were merged with the successful method retry; the helper export is `changed-source.lcov`. The first counter-copy attempt found no SwiftPM-merged profile after the failing test, so existing raw counters were merged directly; that preparation error executed no tests. See `coverage-provenance.json` for source/tool/binary/profile hashes and complete timings.

Strict lint on all touched Swift files and `git diff --check` pass. The host is arm64 Mac16,10 with 16 GiB RAM and Apple Swift 6.4; binaries are instrumented Debug. Existing app/SwiftPM deprecation warnings remain in build logs. No full historical matrix or external CI polling was performed.

The foreground reader probe completed **300.11 s**, **2698 requests**, with **zero missing identifiers**, worker exit 0. Request p50/p95/p99 were **0.98/1.97/2.08 ms**, peak worker RSS **56.67 MiB**. It repeatedly extracts the same **411-byte synthetic RTF** at nice 10, sequentially with 100 ms pauses. OS/framework caches can be warm. No test/build ran concurrently in this task; the host and its other applications were not reserved. This measures only reader requests, not model quality, index throughput, UI/search latency, GPU contention or long-term thermal stability. Summary and compressed raw samples are included.

```bash
LLVM_PROFILE_FILE="$PWD/.build/rtf-resource-%p.profraw" \
python3 docs/validation/gul-383/optimization/rtf-body-slice/rtf_resource_probe.py \
  --binary .build/arm64-apple-macosx/debug/Typeflux \
  --fixture docs/validation/gul-383/optimization/rtf-body-slice/synthetic-body.rtf \
  --seconds 300 \
  --output docs/validation/gul-383/optimization/rtf-body-slice/rtf-resources.json
```

## Self-review and remaining work

Self-review traced descriptor → parser → logical batch → persistent FTS/checkpoint → vector publication → body hit. It checked bounded buffers/state, malformed input, surrogate/DBCS boundaries, cancellation and scope/version revalidation, descriptor/child lifetime, additive discovery and recipe compatibility. Before product compilation, it fixed header delimiter whitespace leaking into body, a multibyte character spanning an encoding/control change, and raw DBCS delimiter trails being mistaken for RTF syntax. Final source fingerprints were frozen during dependency compilation; see `source-freeze-note.txt`. The focused validation also found and corrected the old DOCX test assertion that rejected newly supported RTF.

Remaining required GUL-405 work: XLSX/PPTX/ODT and explicit legacy Office handling; mixed-page/screenshot OCR and geometry; audio overlap/silence and resumable deduplicated video sampling; location-aware preview/open actions from both entries; per-category partial/failure retry; Range/ETag/checksum download recovery. New-content real-model evaluation, native UI evidence and final end-to-end regression remain outstanding. No merge or GUL-406 launch is authorized for this developer turn.

Rollback: revert this PR or disable the existing experimental switch. Reverting the extension list changes discovery keys and triggers a scoped rescan without invalidating compatible model vectors.
