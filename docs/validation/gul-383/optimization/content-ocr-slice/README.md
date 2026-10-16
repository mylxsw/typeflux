# GUL-405: scanned PDF and matching-passage slice

This is a partial GUL-405 delivery, based on main `dcae50561a637082ffc8710f06a9d99924cd3f5c` (PR #587 included). The rest of GUL-405 remains required before GUL-406 starts. No global embedding profile, ranking weights, search scope, experimental default, filename behavior or native owner was changed.

## Inventory and change

The existing content reader supports TXT/Markdown/RST/CSV/TSV and PDF text layers. Image, audio and video extraction already feeds multimodal embeddings. Preview already carries PDF pages and media times. Durable jobs, checkpoints, retries and download-progress reporting also exist. Office/RTF/ODT/HTML content, OCR-backed exact screenshot search, improved media sampling, opening at an evidence location and download resumption still need work.

This slice adds on-device Vision OCR in the existing disposable content reader. Each request processes one PDF page, using its native text when it contains at least eight alphanumeric scalars, otherwise rasterizing at a 2,400-pixel long edge for OCR. Sparse native text is retained with recognized text. Recognition uses accurate English/Simplified/Traditional Chinese support without language correction, to preserve identifiers. The existing UTF-8 batch cursor, descriptor identity/version checks, IPC deadline and indexing cancellation guard remain in force. Password-required and OCR-failed jobs retain fixed failure codes; no exception text or private content is persisted as a reason.

PDF extraction gets a separate recipe, leaving the text/model profile unchanged. Previously completed PDF jobs enter the durable queue once. Queue enrollment uses one metadata transaction; its cost on a very large existing catalog was not benchmarked. On a same-version upgrade, unchanged native chunks adopt their original vectors and IDs; new OCR chunks receive new vectors. Unmatched old chunks are removed only when the new job finishes. A changed file cannot reuse those vectors, and cancellation resumes at the last committed page. Very large OCR output may require the same page to be recognized again for a later 32 KiB slice; there is no total-page or file-size quota.

Both lexical and vector channels now select a bounded excerpt near the query, preferring exact identifiers and quoted phrases. The excerpt remains a literal substring for PDF text-layer highlighting. Evidence also carries the persisted chunk ID and segment kind; its offsets still describe the complete chunk, not the display excerpt. Existing page/time/version fields remain intact. OCR pages can preview their page, but this slice does not add OCR rectangle highlighting or external-reader jumps.

## Validation

`test-files.json` records the reviewed ten-file test/fixture closure. `coverage-swift.sh` is the task-local Swift 6.4 instrumentation/discovery shim, following the already established GUL-404 validation setup. It does not change production targets or test execution scope.

```bash
mkdir -p .build/gul405-bin
cp docs/validation/gul-383/optimization/content-ocr-slice/coverage-swift.sh .build/gul405-bin/swift
chmod +x .build/gul405-bin/swift
export PATH="$PWD/.build/gul405-bin:$PATH"
export TYPEFLUX_GUL405_TEST_FILES="$PWD/docs/validation/gul-383/optimization/content-ocr-slice/test-files.json"
export TYPEFLUX_COVERAGE_SCRATCH="$PWD/.build/gul405-coverage"
make coverage SUITE="SemanticPDFOCRTests SemanticSearchSnippetTests SemanticFilePolicyTests SemanticFileStoreTests SemanticFileContentTests SemanticFileIndexerTests SemanticLexicalSearchTests SemanticIndexRecoveryTests SemanticIndexDiagnosticsTests SemanticFileValidatorTests SemanticReaderOwnershipTests"
```

The new suites cover raster invoice OCR through a real child and reader restart, page checkpoints, compatible vector adoption, stale chunk cleanup, version changes, cancellation after OCR, permission exclusion, encrypted/corrupt input and fixed failure retries. Snippet tests cover Chinese, Unicode width/case/accents, exact-number boundaries, literal PDF highlight ranges, both search channels and filename-result enrichment. Existing suites cover the affected policy, SQLite, reader ownership, recovery and index callers. Synthetic invoice data is the only document content used. Embeddings in these functional tests are deterministic test vectors, not real-model recall evidence.

All **58 unique focused methods passed** across the initial functional pass and the corrected seven-method OCR retry. Changed executable-line coverage is **95/95 application lines (100%)** and **34/35 content-reader lines (97.14%)**; the only uncovered reader line rejects invalid PDF geometry. Native media/inference helper source is unchanged (zero changed-line denominator). The initial runner rejection and unmatched method-filter attempt executed no tests; the one functional failure was an invalid fixture assumption about PDFKit Live Text, corrected without changing product source. Full command wall times were 413.54 / 185.31 / 57.07 / 59.73 seconds, including build/discovery and report overhead. First build was 320.16 seconds. Detailed results, source hashes and exact binary/profile provenance are recorded in the JSON files beside this document. The native OCR fixture and result are retained for review. Lint comparison has zero new diagnostics; the touched scope retains one pre-existing `optional_data_string_conversion` diagnostic. No unrelated full test run or ranking/latency matrix was requested.

The first intended five-minute reader probe stopped after 166.75 seconds and 810 successful requests when the functional retry rewrote the shared exported fixture. Its response errno was not retained; this is a harness failure, not an accepted continuous stress result. `ocr-resources-shared-fixture.json` preserves it. The corrected foreground `ocr_resource_probe.py` snapshots an immutable private input and runs a 90-second short probe, with a 100 ms gap and nice level 10. The 30-minute checkpoint limits further repetition; a clean continuous five-minute run remains unverified. It records individual request durations, reader RSS and CPU samples. Repeated requests can benefit from warm PDFKit/Vision/OS caches; they are not independent uncached pages. The host was not reserved, and focused test rebuilding overlapped part of the probe. This is an OCR-only stress check of an instrumented Debug binary; it does not measure input-to-results latency, GPU use, production scheduler throughput, native mouse/keyboard response or long-term thermal stability. The isolated run completed **404 requests in 90.17 seconds**, with zero missing identifiers, request p50/p95/p99 **117.61/126.48/134.28 ms**, and peak reader RSS **207.06 MiB**. Results must not be substituted for those acceptance criteria.

## Remaining short segments

1. Add isolated Office/RTF/ODT/HTML extraction; explicitly establish supported Word/Excel/PowerPoint formats, long-document continuation, corrupt/encrypted failures and local-only resource handling.
2. Add screenshot OCR alongside visual embeddings, plus scanned-page OCR geometry/highlight support. The current sparse-eight threshold does not detect a scanned body hidden behind a longer native header/watermark; broaden it with real mixed-page samples. Keep completed-page recovery and avoid repeat encoding.
3. Add overlapping audio windows and silence skipping, and determine video density with short scenes; persist perceptual deduplication and actual decoded times across preemption. Retain document → image → audio → video priority. Audio vectors do not imply exact transcription search.
4. Close preview/Return/Quick Look/media-open location propagation across both entries, with explicit capability fallback for external readers, and capture light/dark UI evidence.
5. Complete per-category progress/partial/failure-retry management and Range/ETag model download recovery, including interrupted transfers, ignored Range, changed ETag, checksum failure and incompatible-model isolation.

The fixed new-content quality groups, real-model/user-input end-to-end checks and sustained resource/input response acceptance remain for these segments and later GUL-406. Existing GUL-404 measurements describe their original source/tool versions; they are not new measurements of this head.

## Review and rollback

Self-review also corrected the resource harness to isolate its input from functional-test artifact writes. Self-review checks the complete reader → chunks/FTS → encoding → evidence path, upgrade/cancellation/version boundaries, descriptor and child ownership, SQL bindings, permissions, fixed error codes and documentation. It caught and fixed two issues before validation: decorative snippet ellipses would break PDF substring highlighting, and a shorter invoice number could select the wrong longer-number occurrence for its excerpt. Compatible PDF upgrades also preserve text vectors instead of re-encoding unchanged pages.

Disabling the experiment stops use of the feature. Reverting this slice restores the previous extraction recipe and requires PDFs to be revisited; the additive evidence fields and existing database columns need no destructive schema rollback. Native reader ownership, GUL-404 budgets/events/migrations and permission revocation remain on their existing paths.
