Tool image model original native authority (GUL-399)
===================================================

Baseline: `dfe971674ebb601349b0deab577b69d4e89941b2`. This closes the separate default `AskToolImageModel` entry left after #603's per-call artifact presentation authorization.

The model checks cancellation before replacing source/generation/pixels, captures default native availability once before preparation, and forwards that original authorization to `AskArtifactPresentation.image`. It checks before parsing, after parsing and before final pixels. The custom decoder override is optional and independent; the concrete worker defaults to the same previews worker. Existing labeled/trailing decoder initializers compile. No generic dispatcher, new pool, full DI, per-view ModuleHandle, global bypass or helper change.

The existing data URL parser is extracted into `input` with an immutable MainActor `InputReader` dependency. The same 16 MiB UTF8 cap, base64/type behavior and empty-data parser contract remain; native presentation still rejects empty input. Parsing stays on MainActor: this increment does not claim an off-UI parsing/performance improvement. Raster edge/first-frame behavior, pixel budget and physical collection remain unchanged. Pre-canceled old calls preserve a newer snapshot. Generation checks still reject late old results. The view task identity remains the URL, without health/unavailable, so readiness does not replay input; a fresh explicit load may use current availability.

This is read-only presentation of existing tool output. Activity/run-output callers and their original receipt/proof contracts were inspected. There is no producer/tool/workflow/program/command/paid generation/POST/download/export retry, clipboard write, deletion or modification of raw output. Copy/save UI actions are unchanged and were not run. The stamp begins at model entry, not an earlier account/selection transition. `cancel()` still fences UI by generation; the caller's Task cancellation owns interruption. Entered effects cannot roll back and these checks do not form a linearizable source/FS/permission transaction.

Validation
----------

**29/29 distinct methods passed on FIRST functional execution:** 14 XCTest methods in four suites (0.078s execution), 15 Swift Testing methods in two suites (0.336s). Exact names are in `tool-image-model-authority-methods.json`.

Eight new methods cover pre-ready zero parser/native work and explicit same-source reload; actual default model authorization before parser-callback admission revocation; original legacy message image/text retention; two canceled uncooperative native calls retaining both model pixel reservations until actual return; a protocol-valid late native reply refused after original admission revocation; pre-canceled old entry preserving new pixels and independent custom actor decoding; late old custom result versus new selection; pure input/type/byte limits, empty parser compatibility and custom failure/edge behavior; completed pixel release on cancel/model deinit. All held gates are released and all tasks joined.

The late-reply fixture validates its synthetic response against the actual request, echoes the required image type and counts emitted replies. It proves no stale publication through the composed native/presentation/model checks; it does not freeze execution precisely between a successful presentation return and the final model check or prove every false guard branch. Parser revocation recovers only after the old operation returns; existing artifact retained-stamp tests separately cover actual managed recovery.

Mapping: new eight methods cover model entry/preparation/result/lifetime; seven `ArtifactImageAuthorityTests` methods cover the directly called default presentation and native generations; eight injected-worker and three preview-module methods cover physical retirement/independent budgets/controlled refusal; one tool normalizer admission/cancellation method covers shared worker collection; two pure typed-content negotiation/accessor methods cover neighboring raw receipt contracts. Relevant tool model/view/activity callers and test bodies were reviewed.

Audit correction: the earlier handoff called `testSandboxKeepsProgramOutputWhenImageProjectionFails` safe, but its latter half calls `normalized()`, which invokes actual picture encoding/decoding. That entire method is excluded here, as are the old completed-pixel/view-owned tests that call real image encoding despite custom decoders. New pure fixtures replace those lifecycle checks. Real helper/protocol-image codec/UI/window/pasteboard/URLSession methods are not run. No whole suite or actual network/provider/download/paid call, model/CoreML, OCR, capture/TCC/audio, home/mounts/apps/signing/hardware action. Tests use private bytes, small raw CGImage/NSImage and injected JSON/raw RGBA runners; fake executable URLs are never executed.

Changed executable line coverage: **20/20 (100%)** versus the baseline, from this same focused pass. Not all branches/races/errno/devices/global DI/runtime proof. No layout/helper ABI/entry/packaging change: no screenshot or copied-helper probe.

Evidence
--------

Direct native build with tests/coverage/jobs4 through `scripts/test_runtime.child_environment`: 92.29s passed, no changed-file warnings (existing unrelated/native-build deprecation warnings remain). Native tools/environment/testing-helper inventory 3.937s; direct skip-build/no-parallel explicit-scope test wall 23.19s; archive 2.711s. Core tracked 119.417s; including archive 122.128s, excluding extraction/audit/platform work. No retries, fixture corrections, production relaxation or Source/test edits after build. Each build/inventory/test/archive/extraction completed and was collected before dependent reads/edits.

Only THREE fresh HOST profiles from one binary: XCTest discovery/execution and Swift Testing execution. Each raw individually validated; warning-free sparse merge; matching app `--object`; show/export stderr empty; both binaries contain `__llvm_covmap` and `__llvm_prf_cnts`. All 1142 Source + 837 test Swift inputs match PREBUILD, live files and archive after extraction. Original/copied raw and live/archived binary hashes match. All 1027 reported profile function hashes are zero, which does not establish layout compatibility. Prior live/root-default profiles excluded; no old/cross-layout/child coverage claim.

Private evidence: `.build/tool-image-model-authority-validation/final`.

- Tests SHA256: `d7d43b9a913af567fcd822205abf2df2bc6898b9c91ec32736bc6e8a86f6719d`.
- App SHA256: `257cb51b2d6c32d230c9335ed268b3c34d15a3eb6db18990b120671b433ba4b8`.

Preserved offline HTML/DOCX/PDF OCR/index-budget/launcher/icon changes compile but are not independently validated here. Broader clipboard OCR/attachment/icon/native/source-condition audits remain. Earlier settings receipts exclude concurrent writers versus bind/direct defaults/distinct same-suite objects/external account/preferences/OS FDA ordering. Original source/root/FDA/account/model/control grants, independent budgets and actual retirement remain. Stable mutation identity precedes any future write retry; none added. Audio/TCC/signing/performance precede microphone ownership. Real CoreML/full Xcode/Developer ID/notarization/macOS13 Intel/actual recording quit remain unverified. Host FS/JSON/SQLite/raw memory/UI/AppKit/GPU/system memory remain boundaries; no arbitrary host/native crash, OOM or power-loss guarantee.
