# Workflow image consumer authority

Validated base: main `5c588c7ce14a2a4210a1b7f51c37230bed601ee2`, including the concurrent launcher-list change preserved in the previous landing. No independent launcher UI behavior is claimed tested here.

## Behavior and self-review

Existing workflow image resolve, render and clipboard-byte preparation capture original MediaWorker.Authorization at consumer entry. They retain it through deferred source reads, native admission and final delivery. The existing bounded work helper accepts an additional cancellation predicate; it checks before admission, at detached entry and after actual return. Its default remains unchanged for independent/custom work. Native calls use the original explicit stamp, and source/digest preparation checks cancellation before continuing.

Resolve retains the same content digest/cache identity. It checks original cancellation after native inspection, after hashing and at cache preparation/write admissions. Save checks before opening the cache, after its nonblocking directory lock and before creating a new file. Existing content reuse, mismatch refusal, quotas and private permissions remain unchanged; no overwrite, eviction, retry or producer replay. An already-entered filesystem effect cannot be rolled back. These checks are not an atomic filesystem/settings/permission transaction.

Render forwards its original stamp through the existing renderImage/decode/perform path. Optional parameters preserve legacy callers' entry-time behavior; no QuickLook/icon behavior changed. Clipboard preparation keeps original PNG/source revision or normal copy semantics, original digest checks and byte reservations. Cancellation keeps the existing two work slots and copy reservations occupied until physical preparation returns. Native FD/copy/child/host ownership remains in MediaWorker. Final system clipboard commits remain with their existing source/account/selection owners and are not invoked by these consumers.

Narrow per-call source-reader and pure digest dependencies allow held private fixtures; production defaults use the existing bounded read and hash. No global bypass, new pool, generic wrapper, per-view ModuleHandle, full DI or new authority grant. Existing custom dependencies retain responsibility for their contracts. Self-review before testing traced all three consumers, work/save, original output and cache identity, shared renderImage forwarding, workflow result fallback and original presentation/clipboard commit guards. No workflow execution logic or paid generation request was changed.

Audit correction: the previous handoff mentioned a clipboard image-copy domain. Actual SystemClipboardContentActions uses `.previews` by default; there is no new independent image-copy worker/domain. Functions continue to honor the worker supplied by their caller. Existing reader/model/native budgets remain independent. Original authority begins at each consumer entry, not all earlier workflow execution/UI scheduling. Source/account/OS transitions retain their existing callers' contracts.

## Focused validation

Commands use scripts/test_runtime.child_environment:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '<explicit inventory in workflow-image-authority-methods.json>'
```

Prebuilt native_tools/native_environment/swiftpm-testing-helper inventory, not XCTest as a program. **25/25 distinct methods passed on the first functional run:**18 XCTest across five suites (0.490s execution), seven Swift Testing methods in one suite (0.284s). Seven new methods/ten cases cover:

- Pre-ready resolve/render/normal-copy/original-PNG preparation with zero source/hash/native admissions, no cache and no readiness-triggered work.
- Each of those four consumers held after actual private source read across managed disable/start, rejecting old input before native admission; fresh explicit consumers succeed and source bytes remain intact.
- A successful native inspection held at digest completion before cache write; recovery rejects the old result without creating a cache. A fresh explicit request writes the retained original bytes.
- Two canceled source readers retaining both work slots and copy byte reservations until actual return.
- Stable digest reuse/private mode, corrupt-existing-output refusal and a full128-entry cache with no overwrite or eviction.
- Actual AskContextImageModel replacement while old render preparation is held, retaining fresh pixels after old collection and rejecting old access without replay.
- Legacy renderImage caller without an explicit stamp retaining its existing native-entry behavior.

New fixtures use an eight-byte synthetic PNG signature, four-byte TIFF signature and fixed2x2 raw raster responses. No encoded-image parser or real helper executes. Existing selected methods cover protocol bounds, private FIFO/sparse input refusal, physical native collection, bounded independent health, uncooperative normalizer/validator and fake workflow post-execution failure preserving full output without another producer invocation. The workflow runner is injected; no script executes. Real helper/child decoder, image encoding/decoding tests, provider/network/download, windows and actual clipboard methods were explicitly excluded. Held fixtures release and join all tasks.

Build121.89s passed without changed-file warnings; unrelated warnings/native build-system deprecation remain. Inventory3.748s; test command23.05s; archive2.217s. Tracked core148.688s,150.905s including archive, excludes extraction/audits/platform work. No retries, timeout relaxation or Source/test edits after build. Each build/test/archive/extraction completed and was collected before dependent work.

## Coverage evidence

Changed executable lines vs stated base: **44/44 (100%)**, workflow consumer39/39, preview forwarding5/5. This measures lines, not every branch/race/errno/native allocation/device.

Three fresh matching HOST profiles from one binary: XCTest discovery, XCTest execution and Swift Testing host. Every raw validated individually; warning-free merge; llvm-cov show/export use matching app --object with empty stderr. Both binaries contain __llvm_covmap and __llvm_prf_cnts. Prior live/root default profiles excluded; no old/cross-layout merge or child-process coverage claim. All1,127 Source +815 test Swift hashes verified against prebuild/archive after extraction, plus live/archived binary hashes. All1,210 Swift function hashes are zero and cannot establish layout compatibility. No new production Source file.

Private evidence .build/workflow-image-authority-validation/final:

- Test host SHA-256: `25016f2f6ae8e55b4acbe1f162c349ef55f0e53e17f5cea8ab4f932705c81e26`
- App SHA-256: `b108ac27f219692d2ac400852942612c53112426b50ab89a31667525b37b46d9`

## Boundaries and remaining work

Other deferred image facades, including tool normalization/generated-image validation, still need original-operation admission review. Neither paid generation nor workflow execution may be retried by recovery. Health stays availability-only with no probe/prepare/load/download/query/scan/rebuild/replay. Stable mutation identity remains necessary before future write retries; none added. Earlier condition limits remain: concurrent settings writers versus bind, direct defaults/distinct objects sharing a suite and external preferences/account/OS FDA transitions.

Private synthetic bytes/raw pixels/injected readers/runners/results/FS only. No real OCR/helper/codec/media/weights/CoreML/provider/network/download/home/network mounts/TCC/capture/mic/audio output/user clipboard/external apps/full suite/signing/hardware. No presentation/helper ABI/entry/package change, so no screenshot/copied probe. Audio/TCC/signing/performance precede microphone ownership. Real CoreML/model performance/full Xcode/DeveloperID/notarization/macOS13 Intel/actual quit recording remain unverified. HostFS/JSON/SQLite/raw memory/UI/AppKit/GPU/system memory remain boundaries; no arbitrary host/native crash/OOM/power-loss guarantee.
