# Artifact image memory source authority

Artifact image operations retain an account/session/conversation/selection identity independently of native health and filesystem validation. A fresh access callback cannot authorize pixels produced under a revoked original identity. A stale denied entry preserves a different still-authorized model success, failure or busy operation. Model projection requires the complete ref and matching source identity, samples fresh memory access before original access, and checks attempt ownership after callbacks. It never loads, validates files, decodes, writes or starts a task.

`AskArtifactAccess.boundImages` captures the original memory context synchronously, before queued source preparation. Both explicit load and validate delegates receive the original account owner and run only while that original context remains current. Production `artifactAccess` uses this same factory, reading session, selected conversation, selection generation and deletion state on MainActor. Artifact ownership remains the account owner, rather than a private-conversation cache partition. Missing context has a stable, always-denied identity. Ordinary body recomputation does not invent a UUID. Independent custom/unscoped access and actor decoders retain their contract; unscoped access cannot project previously scoped pixels.

Card and preview image projections include the access receipt; their task identity includes source identity, without health/unavailable state. Card task entry checks cancellation and no longer unconditionally cancels model state before model admission. Explicit selection/reopen operations may start new work; readiness does not replay a failed producer or consumer. Legacy raw model properties remain available to custom owners.

## Review and boundaries

Baseline read immediately after branch creation: `e49877a340531adac684a7c21a1e4f6c7860d280`. Reviewed model load/copy/perform/cancel/projection, access/card/preview, production session/private-cache/selection/reset/deletion wiring, local-tool load/validate and store `withArtifact`, plus selected test bodies and their helpers. Implementation and self-review preceded each functional scope.

During delivery, main advanced independently to `2bff08de1a38a187b811f1644571f25cb77e8f27` through #622 (GUL-405 screenshot OCR alongside visual indexing). Its 37 changed paths (seven Sources, two tests and 28 evidence/docs) are disjoint from this increment. This binary includes the original baseline, not that newer indexing layout or behavior. Landing must preserve those paths and the seven validated increment paths using a read-only merge-tree comparison; no screenshot/OCR behavior validation is claimed here.

Full explicit filesystem/digest/account/conversation/workspace-grant/expiry checks remain. Store validation opens, locks and reads manifests; load also cleans expired artifacts before reading bundles. None of that work runs from a getter. Native availability is not source or copy consent. Existing original native stamps, callback attempt fences, physical native/FD/private-copy/child/host collection and one explicit copy with original encoded bytes remain. Entered sink effects cannot roll back and are never retried. Original bundles, receipts and producer output are retained after preview failure.

This is the image model's memory source boundary, not every UI lifecycle or external permission transaction. Production ConversationModel construction and tool delegation are compiled/audited but not executed here: constructing it would eagerly initialize System clipboard actions and Downloads/home/app dependencies forbidden by this scope. Tests exercise the **same production bound-access factory** through fake memory contexts and the actual small model; this does not prove production object/DI integration. Independent unscoped access retains its owner-defined lifecycle. Card-local dialog errors/preview bundles, preview text/HTML/web-error state, earlier View/native-fallback batches, arbitrary Published/Combine/AppKit reentrancy and external account/root/FDA/grant ordering remain outside the image projection contract. Completed pixels do not vanish merely because native health changes.

No new native grant, pool, dispatcher, full DI, per-view module handle, global bypass, scheduler hook, helper ABI or package change was added. No source producer/tool/workflow/program/command/paid request, recovery replay, copy/export/bundle-write retry, deletion or overwrite was added. There is no filesystem/settings/account permission transaction or arbitrary crash/OOM/power-loss guarantee. Other main features compile but were not independently functionally validated.

## Functional history and coverage

**37 distinct methods have passing results across two functional builds, not a one-shot 37/37 run.** Initial scope passed **36/36** on its first functional run: eight XCTest methods (0.055 s execution) plus 28 Swift Testing methods in four suites (0.147 s). Eight new memory methods cover the pure receipt, original-last projection, denied success/failure/busy ownership, callback cancellation, final source revocation, explicit copy, original bytes and denied/expired fallback. Existing safe methods cover native stamps, callback fences, exact refs, canceled uncooperative physical collection and copy sinks.

Initial coverage was **47/64 (73.44%)**. The memory binding and explicit delegate checks were then extracted into the shared production `boundImages` factory, and one meaningful queued-binding/delegate test was added. Production card/access and ConversationModel wiring changed; model implementation was unchanged. After rebuilding, only the affected nine memory methods plus the existing body-value construction method ran: **10/10 passed** (0.057 s). The other 27 initial passing methods were not rerun. There was no functional failure, timeout relaxation or assertion correction.

**FINAL changed executable coverage: 57/70 (81.43%)** versus the actual baseline. Model 33/33; shared factory/source/card/preview file 24/26; ConversationModel wiring 0/11. Unhit lines are the card task action at 114–115 and production context/tools bridge at 1633–1643. This exceeds 80% but **misses the 90% goal**; the denominator includes the forbidden production object bridge. We did not construct System objects, add artificial lines, or hide that bridge to meet a percentage. Core model and source factory behavior are exercised; not every branch, race, errno, device or runtime/DI boundary is proved. Exact initial/final inventories and exclusions are in `artifact-memory-authority-methods.json`.

New fixtures use private three-byte bundle data, raw 2×2 pixels, fake contexts, custom decoders, synchronous callbacks, continuation gates and write sinks. All held gates were released and tasks joined. Factory capture is observable before its queued model task runs; no global executor freeze or exhaustive scheduling proof is claimed. Existing native fixtures use synthetic preview JSON/private RGBA with image-type echo. Only successful protocol responses count as valid completion.

The body test constructs SwiftUI values only: no host, layout, rendering, window, button/task action or icon fetch. No System clipboard action or pasteboard (including named), ConversationModel/AskTestFixture, Downloads/home, external apps/icons/QuickLook, encoder/codec/helper/Vision/OCR, actual HTTP/provider/paid call, capture/audio/TCC/device or full suite ran. Unsafe MIME/clipboard/real-helper/window-render fixtures were excluded rather than skipped by opt-in. There is no layout redesign or ABI/package change requiring a screenshot or copied-helper probe.

| Foreground stage | Wall seconds |
| --- | ---: |
| Initial build, failed task-ID Hashable conformance | 43.480 |
| Corrected initial functional build | 262.770 |
| Initial inventory | 4.181 |
| Initial focused coverage test | 25.940 |
| Initial archive | 3.360 |
| Shared-factory rebuild | 79.950 |
| Final inventory | 4.560 |
| Affected final coverage test | 8.170 |
| Final archive | 18.734 |
| Builds + inventories + tests | 429.051 |
| Including both archives | 451.145 |

The first build failure was corrected before functional tests by using Equatable, which matches the existing ref and SwiftUI task contract. Successful builds had no changed-file warnings; unrelated warnings and native-build deprecation remain. Extraction, audit and platform delivery are additional, not separately timed. No Source/test inputs changed after the final build. Each build/inventory/test/archive/extraction completed and was collected before its dependent stage.

## Evidence integrity

Only **two fresh FINAL HOST profiles from one binary** are used: XCTest discovery and Swift Testing execution, with no XCTest methods executed in the final pass. Initial three profiles/binaries are archived separately in `initial-functional` and excluded. Initial relocated/copied raw hashes and binary hashes were verified; exactly two Source files and the new test file differ between initial and final snapshots. Both app and test binaries changed, so profiles were not mixed.

Every final raw was validated individually; sparse merge, matching-app-object show/export and all-functions inspection had empty stderr. Both app/test binaries contain LLVM coverage sections. **1,146 Source + 854 test = 2,000 Swift inputs** match FINAL PREBUILD, live and archived hashes after extraction. Live/archived binaries and original/copied raw hashes match. All 407 reported function hashes are zero; zero Swift hashes do not establish layout compatibility. Prior live/root default profiles are excluded. No cross-layout or child coverage is claimed.

Private final evidence: `.build/artifact-memory-authority-validation/final`.

- Test binary SHA256: `90c787e8d85e49e824d6473e91f6e2de8a4a7961cee4e6d8355b98411d54495a`
- App binary SHA256: `b763f4f0bf8f7f1aed6e2bb224dc23f582c8cc912e8238442a46b509ceb9d1c5`

GUL-399 stays in progress for remaining artifact View/local-bundle source projection, earlier UI/native-fallback and separate external conditions. Real model/performance/device/signing/full-Xcode/macOS-13-Intel/actual quit-recording checks remain unverified. Host filesystem/JSON/SQLite/raw-memory/UI/AppKit/GPU/system-memory boundaries do not promise arbitrary crash or resource-failure recovery.
