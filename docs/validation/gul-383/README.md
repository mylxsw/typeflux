## GUL-383 validation

Validated on an Apple Silicon Mac with Swift 6.4. The feature remains off by default. Screenshots in `native/` are rendered from the production SwiftUI views with isolated fixture settings and files.

The selected scope covered the seven new semantic-search suites, filename index/scope/snapshot/reliability/streaming, file preview policy/reader, staged search, quick-result ranking, file mode, scheduling and launcher settings. `WorkflowControllerProcessingTests/testSemanticIndexingPriorityFollowsRecordingAndProcessing` checks that indexing resumes only after both recording and processing end.

| Run | Result | Wall time including build/discovery |
| --- | --- | --- |
| Final integration with `main` (`5c79e4e0`), including localization resources | 129 Swift Testing cases + 25 XCTest cases, **154/154 passed** | 329.99 s |
| Original focused scope | 128 Swift Testing cases and one XCTest; the native click test exposed a missing wait for the rendered Resume button | 315.24 s |
| Final affected callers and failed suite: `SemanticHybridSearchTests SemanticFileServiceTests AskQuickSearchSessionTests AskFileSearchPluginTests` | 44/44 passed, including the native click flow and the separate folder-selection limit regression | 130.30 s |
| Packaged, signed helper with real weights | English/Chinese retrieval, finite normalized 768D vectors, three invalid requests rejected | 6.08 s |

Every selected suite has a passing result after its last relevant change. Earlier failed passes identified and fixed the helper's required protocol field, asynchronous ready/count publication, file-reader fixture path canonicalization, the first-opening SwiftUI state bug, real download progress delivery, and native accessibility readiness. An intermediate build was invalidated by editing a test during compilation; later runs kept build inputs fixed. Validation used focused scopes throughout.

The real model was downloaded through the production download delegate with intermediate progress, HTTP 200 and the pinned SHA-256 verified. The final complete-download integration case took 80.50 s. Default tests do not access the network; this case requires `TYPEFLUX_SEMANTIC_LIVE_DOWNLOAD=1`. `TYPEFLUX_SEMANTIC_TEST_MODEL` enables real checksum/install and application IPC tests against an already downloaded model.

## Coverage

LLVM line coverage is **93.77% for the new semantic modules and native settings views** (2,362/2,519 LLVM-counted lines), and **96.83% for the separate helper** (61/63). The corresponding new-module region coverage is 82.60%. Per-file details and timing measurements are in `validation.json`.

The focused runs produce 3.93% line coverage over all instrumented project Swift sources. Full-project tests were outside this validation scope.

In this environment, `swift test --enable-code-coverage list` did not generate instrumentation. A local command wrapper selected `--build-system native` and passed `-Xswiftc -profile-generate -Xswiftc -profile-coverage-mapping` through the existing runner. The repository's runner was unchanged. Both build/discovery and execution used these options.

Coverage initially combined the complete focused pass with the final affected-suite pass. Before merging binary profiles, `llvm-profdata merge --no-function` removed earlier `TypefluxTests`, `SemanticFilePolicyO5merge` and `AskQuickSearchSessionC13commitResults` records. Those two changed production function families use only the final rerun's counters; unchanged production functions retain the complete scope's measurements. The merge completed without counter mismatches. After integrating `main`, the full selected scope and localization resources ran again. The final report uses that passing integration profile, supplemented only with earlier `Semantic` production-function counters for the unchanged feature sources (including the explicitly verified live download). The feature sources are byte-for-byte identical to `aec306d9`; profile merging completed without counter mismatches.

## Self-review

- Default-off and unsupported-device gates are enforced before dispatch, including persisted settings. Filename scores and their first rows remain intact; semantic-only hits never acquire default Return. Explicit file/folder choices survive late publication using their respective display limits.
- Selected folders retain blocked permission information while reads stay forbidden. Scope/type/extension/folder restrictions apply before ranking. Descriptor-based reads reject links, placeholders, non-local mounts and credential paths; text/PDF extraction is bounded. Empty/scanned content is skipped.
- Cancellation and generation checks stop stale publication. Index writers finish before cache/model removal; corrupt databases can be removed without opening them or deleting verified weights. Recording/processing, power notifications, FSEvents and settings changes have lifecycle tests.
- Download continuations complete once, cancellation releases the session, and temporary files are owned before callbacks return. Size/hash validation and atomic replacement precede model activation. File contents and query text are absent from process arguments and logs.
- The runtime source/revision/profile are pinned. The packaged arm64/macOS 14 helper was checked for system-only dynamic dependencies and verified with an isolated ad-hoc hardened-runtime signature. Runtime/model licenses and implementation documentation are included.

## Design fidelity pass

A review against the approved interactive design found the first native version used different names, layout and flow. The settings card, setup, management and result rows were reworked to match the design:

- Files tab: an "Experimental" section with the semantic file search card (accent badge, off-state detail, status dot, download/indexing progress, Manage… plus a retry/download/permission link). File search off shows the paused warning; unsupported devices show the requirement and cannot enable the switch.
- Setup: privacy notice, content folder scope with counts, model card with download size, "Download Model and Turn On"; the sheet closes and the card shows progress.
- Management: status notice, folders edited as a draft applied on Done (an empty list turns the feature off), indexed files / index / model size, Pause/Resume or Rebuild, and separate confirmations for clearing the index and deleting the model. Sheets size to their content; long folder lists scroll.
- Results: content matches show a "Content match" badge, folder and PDF page, then the passage, in both mixed search and `f` mode. Line breaks inside CJK passages no longer add spaces.
- ja/ko/zh-Hant previously shipped English copies of these strings; all five languages are now translated.
- A rebuild running while folders are edited no longer restores the old folders.

Validation ran on the Apple Silicon worker against the final tree. `make test SUITE="SemanticFileServiceTests SemanticFileSearchVisualTests SemanticFileSearchStatusTests SemanticHybridSearchTests AskQuickResultsFileTests AskFileSearchPluginTests AskPluginListViewTests AskWorkflowItemRowTests AskFloatingPanelStyleTests LauncherSearchSettingsViewTests LocalizationResourceTests AgentSettingsRedesignTests"` passed: 62 Swift Testing + 37 XCTest, 278.89 s wall including the rebuild. `make coverage` passes the same suites but this toolchain writes no profile, so coverage came from the same suites under `swift test --build-system native --enable-code-coverage --no-parallel`, which also passed: 65 Swift Testing + 37 XCTest, 185 s wall incremental. Line coverage of the lines changed in this pass is **95.84%** (438/457). The uncovered lines are mostly the cancel-download, download and retry buttons in management, which fixtures finish too fast to show. SwiftLint against the repository baseline reports no new findings in the touched files compared with the PR head.

The native click test covers the disabled unsupported-device switch, cancel, directory validation, setup closing into the card, Manage, resume, rebuild, draft folder removal applied on Done, and confirmed clearing/model removal. Screenshots in `native/` cover the card (off, ready, file search off, unsupported), setup, management (including a scrolling folder list), and content-match rows in `f` mode and mixed launcher results (plain and selected), in light and dark appearances. Fixture folders are temporary directories, so their paths look longer than real `~/Documents` folders.

Intel/macOS 13 hardware execution, release notarization and large-directory performance/recall benchmarking were not run. The model ranking check uses synthetic text fixtures; image/audio embeddings and OCR are outside this first version.
