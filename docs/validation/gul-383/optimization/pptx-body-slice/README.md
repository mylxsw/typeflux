# GUL-405: local PPTX slide body slice

Based on main `388dad547e52f4e5262d7e646cad7d723a40186a`, including merged PRs #595, #598, #601, #605 and #607. This sixth partial slice adds PPTX slide text to the existing disposable file reader and persistent jobs. GUL-405 remains in progress; GUL-406 remains parked.

The reader streams `ppt/presentation.xml` and `ppt/_rels/presentation.xml.rels`, then resolves each `sldId` relationship in presentation order. Slide filenames, ZIP member order, relationship declaration order and numeric slide IDs do not determine page numbers. Internal relative or package-absolute targets are normalized solely to select a ZIP32 data member. Targets never become filesystem paths, and the reader never opens a URL. External relationships are ignored; a presentation slide that references an external or missing relationship fails with the existing `unreadable-content` reason. Duplicate relationship IDs also fail deterministically.

The supported subset is slide text shapes (including grouped shapes), visible text runs, cached field text, line/paragraph breaks and table cell paragraphs in XML document order. Transitional and Strict PresentationML/DrawingML namespaces are recognized. Only ordinary shape and table body paths are accepted. Pictures, objects, links, macros, notes, masters, layouts, charts, animation, alternate-content fallbacks and external resources are neither evaluated nor loaded. Hidden slides remain searchable in their presentation-list positions; visual layout, style-dependent visibility, custom show order, master-inherited text and complete PowerPoint rendering are outside this subset. Only PPTX is admitted; PPTM/PPSX and legacy PPT remain unsupported.

Each batch carries `pptx-slide`, the one-based presentation-list slide number, logical UTF-8 offset and existing held-descriptor file version. Those are index evidence, without a claim of precise external-player or native-preview navigation. The existing scalar-safe 32 KiB batch and overlap cursor uses zero-based slide plus logical offset, surviving both long-slide and cross-slide restarts. Long-slide continuation replays that slide's XML prefix; metadata and the ZIP directory are also reparsed. Already committed vectors remain reusable. Very large prefixes or presentation metadata may reach the existing disposable-worker deadline. ZIP CRC is checked when a member is consumed, so late damage can be detected after earlier partial batches.

The existing ZIP/XML failures are retained: encryption on a selected ZIP member is `password-required`; DTD/entity declarations, NUL-containing encodings, unsupported compression and ZIP64 are `unsupported-document`; malformed/missing members and CRC mismatches are `unreadable-content`. Encrypted OLE Office containers remain unsupported. No member is unpacked. Existing scope, descriptor identity, cancellation, file-version and permission checks gate publication. No new index, dependency, schema, asynchronous work or per-file/total-block quota is introduced. The extension-aware discovery keys revisit completed directories for PPTX while existing recipes/model space retain compatible vectors. Diagnostics record the distinct PPTX recipe.

The slide-order contract follows [Microsoft's PresentationML slide documentation](https://learn.microsoft.com/en-us/office/open-xml/presentation/working-with-presentation-slides) and [text extraction example](https://learn.microsoft.com/en-us/office/open-xml/presentation/how-to-get-all-the-text-in-a-slide-in-a-presentation). This implementation uses local Foundation XML parsing rather than the Open XML SDK.

## Validation scope

The explicit test closure extends the prior ODT closure with `SemanticPresentationTextTests.swift`; it reuses the Swift 6.4 native coverage wrapper. PPTX tests use stored and deflated synthetic packages, intentionally presenting `slide2.xml` before `slide10.xml` despite lexical ZIP order and reversed relationship declarations. They exercise native-child and in-process reads, text shapes/tables/CDATA, persistent index-to-body evidence, long Unicode reconstruction, both cursor axes after store restart, compatible-vector discovery, post-read cancellation/replacement/permission revocation, fixed failure reasons, explicit retry and version repair. Embedding fixtures are deterministic.

DOCX/ODT/RTF/HTML/PDF tests cover shared reader dispatch and ZIP/XML behavior. Policy/store/index/diagnostics/discovery/reader ownership suites cover the directly affected callers. No new real-model quality, native UI, input-to-result performance or long-term thermal acceptance is claimed. Earlier model/performance/UI evidence remains attached to its own source/model/tool fingerprints.

The first coverage command selected **68 methods** across 14 suites. **62 passed and six PPTX methods failed with 38 assertion issues** because Foundation does not report namespace prefix mappings by default. Enabling `shouldReportNamespacePrefixes` fixed relationship ID resolution. Only the containing PPTX suite was rerun: **7/7 methods passed**, including its previously passing cancellation method. The other **61 methods passed in the first run** and were not repeated. This is combined evidence for all 68 selected methods, not a claim of one clean full-scope pass.

First command wall time was **358.68 s**, including **305.76 s** first build, **337.79 s** discovery/build and **357.45 s** runner total. The PPTX-only retry took **110.30 s**, including **74.27 s** incremental build, **100.57 s** discovery/build and **107.41 s** runner total. There were no compiler/build failures and one test retry. The existing deprecated framework/build-system warnings remain in logs. Final strict lint of seven changed Swift files and `git diff --check` pass.

```bash
mkdir -p .build/gul405-pptx-bin
cp docs/validation/gul-383/optimization/html-body-slice/coverage-swift.sh .build/gul405-pptx-bin/swift
chmod +x .build/gul405-pptx-bin/swift
export PATH="$PWD/.build/gul405-pptx-bin:$PATH"
export TYPEFLUX_GUL405_TEST_FILES="$PWD/docs/validation/gul-383/optimization/pptx-body-slice/test-files.json"
export TYPEFLUX_GUL405_PPTX_EVIDENCE="$PWD/docs/validation/gul-383/optimization/pptx-body-slice"
export TYPEFLUX_COVERAGE_SCRATCH="$PWD/.build"
make coverage SUITE="SemanticPresentationTextTests SemanticODTTextTests SemanticRTFTextTests SemanticHTMLTextTests SemanticWordTextTests SemanticPDFOCRTests SemanticFilePolicyTests SemanticFileStoreTests SemanticFileContentTests SemanticFileIndexerTests SemanticIndexDiagnosticsTests SemanticReaderOwnershipTests SemanticScanAdmissionTests SemanticDiscoveryPauseTests"
# After the namespace-reporting fix, retry only the affected suite:
make coverage SUITE="SemanticPresentationTextTests"
```

Changed executable lines are **application 3/3 (100%)** and **shared reader/dispatch 168/168 (100%)**, combined **171/171 (100%)**. The denominator intersects added/modified Swift lines with LLVM LCOV DA records, excluding tests and unchanged lines; the extension constant has no executable mapping and is covered by discovery behavior. These are line counts, without branch, project-wide or full-helper coverage claims. The shared reader is compiled into the app library and used by its disposable child. Separate media/inference helper targets have no changed source. The preserved first-run profraw files and PPTX retry profiles were merged for changed-line reporting; resource-probe profiles are excluded. `changed-source.lcov` uses repository-relative paths and `changed-coverage.json` has the grouped denominator and no uncovered executable lines.

`coverage-provenance.json` records toolchain/hardware, source/test/tool/reader/test-binary/profile hashes, synthetic package members and full command timings. The source freeze note records the pre-compilation filename correction and subsequent parser fix. The failed console stream contains invalid UTF-8 within failure descriptions; its compressed file preserves normalized raw bytes, while summaries decode with replacement. The initial failed runner did not produce default.profdata; its raw profiles were retained and merged explicitly. No tests were repeated for these export/logging issues. This host is arm64 Mac16,10 with 16 GiB RAM and Apple Swift 6.4, using instrumented Debug binaries. No models or model-space definitions changed.


The foreground reader resource probe completed **300.07 s**, **2660 requests**, **zero missing identifiers** and worker exit **0**. Reader request p50/p95/p99 were **2.08/3.49/3.57 ms**, peak RSS **57.83 MiB**. It repeatedly reads the first slide of the same **2341-byte synthetic two-slide PPTX**, at nice 10 with 100 ms between requests. OS/framework caches can be warm. No Swift build or test ran concurrently; other host applications were not reserved. This measures reader requests without model inference, persistent indexing throughput, UI input, GPU contention or long-term thermal stability. Resource profiles are excluded from test coverage. Source/test/tool/reader/test-binary fingerprints matched after the probe.

```bash
LLVM_PROFILE_FILE="$PWD/.build/pptx-resource-%p.profraw" \
python3 docs/validation/gul-383/optimization/pptx-body-slice/pptx_resource_probe.py \
  --binary .build/arm64-apple-macosx/debug/Typeflux \
  --fixture docs/validation/gul-383/optimization/pptx-body-slice/synthetic-body.pptx \
  --seconds 300 \
  --output docs/validation/gul-383/optimization/pptx-body-slice/pptx-resources.json
```

## Self-review and remaining scope

Self-review traces held descriptor → presentation relationships → streamed slide body → persistent page/offset checkpoint → vector publication → body-hit evidence. It checks namespaces, archive-only path normalization, external/embedded-resource isolation, Unicode boundaries, descriptor/zlib/parser/child lifetimes, cancellation and post-read version/permission revalidation. Before validation it restricted body selection to ordinary shape/table paths, made mid-scalar cursor errors retain EINVAL, corrected the synthetic filename order and stale DOCX unsupported-format assertion and aligned retry assertions with the existing explicit-retry contract. No UI or localization strings changed.

XLSX shared/inline strings and cached values remain required; formulas must not execute. Other remaining GUL-405 scope is mixed-page/screenshot OCR and geometry, audio overlap/silence, short-frame video sampling/deduplication/actual timestamps/recovery, both entry points' location-aware preview/Return/Quick Look/media opening and fallback, per-category partial/failure retry, Range/ETag/checksum downloads, and new-content real-model/native UI/end-to-end acceptance. Legacy binary Office lacks a safe local importer and remains explicitly unsupported. This partial PR neither completes GUL-405 nor starts GUL-406, and is handed to Arch for independent review and merge.

Rollback: revert this PR or disable the existing experimental switch. Reverting the extension set changes discovery keys without invalidating compatible model vectors.
