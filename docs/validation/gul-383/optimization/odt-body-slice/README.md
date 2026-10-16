# GUL-405: local ODT body slice

Based on main `1a451e1dc341c6a14a1ebcc2ba01af0bd5ae2125`, including merged PRs #595, #598, #601 and #605. This is the fifth partial GUL-405 slice. GUL-405 remains in progress; GUL-406 remains parked.

ODT enters the existing disposable file reader and persistent document jobs. The existing ZIP32 central-directory reader now accepts a fixed member name, preserving DOCX's default. ODT streams `META-INF/manifest.xml` for encryption detection and `content.xml` for the main `office:body/office:text` content. It does not unpack any member, follow package paths, load URLs, expand DTD entities, execute macros, evaluate fields or open embedded objects. The manifest root must be recognized; any manifest encryption declaration is rejected as `password-required`, including an encrypted auxiliary member. Malformed packages/XML retain `unreadable-content`; ZIP64, unsupported ZIP compression, DTD/entity declarations and NUL-containing encodings such as UTF-16 retain `unsupported-document` through the existing reader. ZIP-layer encryption also retains `password-required`.

Paragraphs/headings, inline text/spans/visible links, lists and table cells are extracted in XML document order, with paragraph, cell and row separators. Explicit spaces, tabs, line breaks and CDATA are supported. Drawing/object text, annotations, footnotes, tracked-deletion storage and ruby annotations are omitted. Links contribute visible text only. The reader reports `odt-body` and logical UTF-8 offsets, with no page numbers or geometry. It uses the existing scalar-safe 32 KiB batch/overlap cursor, held-descriptor identity checks, permissions and worker deadline. Cancelled, replaced or permission-revoked content is revalidated before indexing. No new indexing subsystem, dependency, schema, single-file limit, directory quota or total-chunk quota is introduced.

The ODT recipe is recorded in document jobs and run diagnostics. The existing extension-aware discovery/checkpoint keys cause completed folders to discover ODT. Existing text/PDF/DOCX/HTML/RTF recipes and model space remain unchanged, so compatible vectors are retained. Long documents replay their XML prefix to reach the saved logical cursor; committed vectors are not reencoded. Large prefixes or metadata may hit the existing disposable-worker deadline. ZIP member CRC is verified when the member is consumed; late corruption can therefore be detected after earlier partial batches. The parser does not implement visual layout, style-dependent visibility, repeated table row/cell expansion, footnote text, complete ODF rendering, Flat ODT, legacy binary Office, XLSX or PPTX. XLSX/PPTX are still required later slices, rather than implicitly supported by accepting ZIP packages. Legacy DOC/XLS/PPT lack a safe local binary importer; encrypted containers and ZIP64 remain explicitly unsupported.

Package/encryption handling follows the [OASIS ODF 1.3 package specification](https://docs.oasis-open.org/office/OpenDocument/v1.3/OpenDocument-v1.3-part2-packages.html). Support is the body subset described here.

## Validation scope

The source closure extends the already reviewed RTF closure with `SemanticODTTextTests.swift`. It retains the Swift 6.4 native-build coverage shim. The normal focused runner chooses explicit suites; no unfiltered or duplicate plain test run is used.

```bash
mkdir -p .build/gul405-odt-bin
cp docs/validation/gul-383/optimization/html-body-slice/coverage-swift.sh .build/gul405-odt-bin/swift
chmod +x .build/gul405-odt-bin/swift
PATH="$PWD/.build/gul405-odt-bin:$PATH" \
TYPEFLUX_GUL405_TEST_FILES="$PWD/docs/validation/gul-383/optimization/odt-body-slice/test-files.json" \
TYPEFLUX_GUL405_ODT_EVIDENCE="$PWD/docs/validation/gul-383/optimization/odt-body-slice" \
TYPEFLUX_COVERAGE_SCRATCH="$PWD/.build" \
make coverage SUITE="SemanticODTTextTests SemanticRTFTextTests SemanticHTMLTextTests SemanticWordTextTests SemanticPDFOCRTests SemanticFilePolicyTests SemanticFileStoreTests SemanticFileContentTests SemanticFileIndexerTests SemanticIndexDiagnosticsTests SemanticReaderOwnershipTests SemanticScanAdmissionTests SemanticDiscoveryPauseTests"
```

ODT tests cover actual stored/deflated ODT packages through the child process, ordered paragraphs/list/table extraction, XML and external-resource isolation, multibatch Unicode reconstruction, child/store restart and persistent checkpoint recovery, index-to-body-hit evidence, compatible-vector preservation, discovery upgrades, cancellation/version/permission revalidation, encrypted/malformed/unsupported fixed failures and version retry. DOCX exercises the shared ZIP reader; RTF/HTML/PDF exercise the shared content dispatch. Policy/store/index/diagnostic/discovery/ownership suites cover affected callers. Functional embedding vectors are deterministic. This slice adds no claim about real-model quality, input-to-result latency, native UI or long-term thermal stability. Existing evidence remains tied to its own source/model/tool fingerprints.

The focused command passed **61/61 methods** (9 XCTest methods and 52 Swift Testing methods across 13 selected suites), with **zero build failures, test failures or retries**. Full command wall time was **362.38 s**, including **312.42 s** first build, **344.13 s** cumulative discovery/build and **358.29 s** runner wall time. The remaining time generated the coverage report. This fresh checkout had no task build cache; dependencies were resolved from available SwiftPM caches. Strict lint of all eight touched Swift files and `git diff --check` passed.

Changed executable lines: **application 2/2 (100%)**, **shared reader/dispatch 119/122 (97.54%)**, **combined 121/124 (97.58%)**. The denominator intersects added/modified Swift lines with LLVM LCOV DA records, excluding tests and unchanged code. The extension constant has no executable mapping and is exercised by policy/discovery assertions. This is line coverage rather than branch or project-wide coverage. ODT CDATA delegate lines 128–130 have no test-process counters: the real child-process test asserts its CDATA table output, but the stopped worker does not flush counters. No tests were rerun to fill this gap, and resource-probe counters are not added to the test numerator. Separate media/inference helper targets have zero changed source lines. Raw exports and grouped numerators are in `changed-source.lcov` and `changed-coverage.json`.

The host is arm64 Mac16,10 with 16 GiB RAM and Apple Swift 6.4, using instrumented Debug binaries. `coverage-provenance.json` records source/tool/binary/profile hashes and complete timings. The existing model hash is unchanged, with no new model inference claim. Existing app/compiler deprecation warnings remain in the build log; the changed Swift files pass strict lint.

The foreground reader probe completed **300.05 s**, **2704 requests**, **zero missing identifiers**, and worker exit **0**. Request p50/p95/p99 were **1.18/2.36/2.42 ms**, peak worker RSS **57.31 MiB**. It repeatedly extracts the same **1199-byte synthetic ODT** at nice 10, with 100 ms between requests. OS/framework caches can be warm. No test or build ran concurrently in this task; the host and its other applications were not reserved. This is reader request timing, without model inference, indexing throughput, UI input, GPU contention or long-term thermal claims. Raw samples are compressed in `odt-resources.json.gz`; the summary and fixture/reader/tool hashes are included. Frozen source/test/tool/binary fingerprints match after the probe.

```bash
LLVM_PROFILE_FILE="$PWD/.build/odt-resource-%p.profraw" \
python3 docs/validation/gul-383/optimization/odt-body-slice/odt_resource_probe.py \
  --binary .build/arm64-apple-macosx/debug/Typeflux \
  --fixture docs/validation/gul-383/optimization/odt-body-slice/synthetic-body.odt \
  --seconds 300 \
  --output docs/validation/gul-383/optimization/odt-body-slice/odt-resources.json
```

## Self-review and remaining scope

Self-review traced held descriptor → ZIP/XML → logical batches → persistent body index/checkpoint → vector publication → body query. It checked descriptor/stream/child lifetimes, bounded extracted-text buffers, namespace/body selection, malformed/encrypted input, external-resource isolation, Unicode overlap, version/permission checks, cancellation after extraction, additive discovery and unchanged vector recipes. Before the focused pass it corrected the ODT fixture's uncompressed first `mimetype` member, process lifetime in ZIP fixture creation, the expected existing encrypted-file reason and an old DOCX assertion that still excluded ODT. No product UI or localization strings changed.

PPTX was left for the next short slice to preserve verification time; XLSX shared/inline strings and cached cell values remain required. Other required GUL-405 scope remains: mixed-page/screenshot OCR and geometry; audio overlap/silence; short-frame video density, perceptual deduplication, actual timestamps and preemption/recovery; two-entry preview/highlight/Return/Quick Look/media-open location handoff and fallbacks; per-category partial/failure retry; Range/ETag/checksum download recovery; new-content real-model and native UI/end-to-end acceptance. This partial PR does not complete GUL-405, merge itself or start GUL-406.

Rollback: revert this PR or disable the existing experimental switch. Reverting the extension set changes discovery keys without invalidating compatible model vectors.
