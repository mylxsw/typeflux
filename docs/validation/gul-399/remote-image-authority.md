# Remote image native presentation authority

Validated base: main `29e4817385eba9ae3522bf50334a58885eaeb4de`.

## Behavior and review

Default AskRemoteImageLoader presentation now snapshots existing native authorization before reserving a download slot or awaiting transport. It retains that original stamp through response admission, detached decoding, native admission and final result. AskRemoteImageModel snapshots before its internal task/pixel reservation and forwards the same stamp, then rechecks it before publishing NSImage. Queued or received old input cannot recapture a recovered managed generation. A fresh explicit load can use current availability.

The optional custom Decoder override keeps its own independent contract and does not inherit a forced native-health dependency. The concrete worker dependency defaults to the same shared preview pool. The original one-argument decodePixels bridge remains; the worker/authorization overload retains an enclosing operation's stamp. Existing initializer/call sites compile unchanged. No new pool, generic dispatcher, per-view ModuleHandle, full DI, global scheduling switch, health grant or helper change.

For default native presentation, unavailable entry now refuses before GET. The reference and eligible HTTPS link remain available through the existing unavailable UI path. Health readiness never retries that input. Existing GET method,15s timeout,16MiB response limit, credential-free request, raster bounds, two-operation download admission and native budgets remain. Custom decoders may still consume a request without native readiness. No paid generation, producer invocation, POST, automatic download retry, export/write retry or deletion is added.

Two download slots, pixel reservations, native slots and FD/private-copy/child/host ownership remain held through actual return, including cancellation-uncooperative injected work. Already-entered transport/FS/native effects cannot be rolled back. Checks do not make filesystem/settings/permissions linearizable. Standalone/custom owners retain their underlying lifecycle responsibility.

Self-review before tests traced remote access/scope/view identity, model task ownership and default decoding, and compared Context/Artifact presentation and callers. Existing access/cancellation/selection guards after await are unchanged and regression tested. This increment addresses original native generation, not every source/UI entry condition:remote model still calls cancel before validating a new load's Task/access. A queued canceled or stale denied invocation can therefore clear a newer snapshot. Original access retention for later display also needs separate review. Those are explicit remaining condition-lifecycle work, not claimed fixed here.

## Focused validation

Using scripts/test_runtime.child_environment:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '<explicit inventory in remote-image-authority-methods.json>'
```

Prebuilt native_tools/native_environment/swiftpm-testing-helper inventory, not XCTest as a program. **44/44 distinct methods passed on the first functional run:**36 XCTest methods across seven suites (0.501s execution),eight Swift Testing methods in one suite (0.143s). Eight new methods establish:

- A fake response held across managed disable/start cannot enter old native decoding; no readiness replay occurs. An explicit fresh load works and the original asset/reference/query remain unchanged.
- Actual model pre-ready entry performs no GET/native work, keeps unavailable/link fallback, and remains unchanged when readiness opens. Explicit fresh load displays raw injected pixels.
- Explicit retained pre-ready, retired and foreign stamps refuse loader and direct decoder admission. Fresh direct decoding works; pre-canceled load performs no GET/native work. This exercises retained-stamp forwarding, not exhaustive executor scheduling.
- Two canceled uncooperative fake transports retain both download slots until actual return; neither late response enters native decoding, and fresh work succeeds after collection.
- Two canceled uncooperative fake native calls retain download/native capacity until return; late pixels are rejected and fresh work succeeds.
- Actual model scope replacement while old transport is held preserves new pixels/source after old collection. Original denied scope cannot publish the old result.
- A custom raw-pixel decoder remains independent of an unready native worker.
- Final model delivery observes explicit native revocation from the existing access-check boundary after pixels have returned; no stale NSImage is published and the link remains eligible.

All held gates released and tasks joined. Injected runner writes private2x2 RGBA raster bytes and bounded protocol JSON; no codec/helper executes. Fake transport only checks request shape/returns Data([1,2,3]); no HTTP/provider/download/paid request. NSImage/CGImage construction uses raw pixels only, with no windows/apps.

Selected existing methods:AskRemoteImageTests8(fake transport/decoder,scope,admission,limits),AskContextImageTests6(pure input/custom model ownership),AskArtifactImageTests6(custom decoder/write sinks),AskGeneratedImageTests3(pure DTO/URL/output mapping),MediaPreviewTests2(pure raster protocol/Unicode text),MediaWorkerTests8 excluding real helper,MediaPreviewModuleTests3(independent budgets/corrupt health/controlled refusal). Every selected body was reviewed. Methods using actual image encoding/decoding/helpers, URLSession redirect fixtures, windows, system pasteboards and production-account fixtures were excluded. Test names mentioning clipboard/copy use injected sinks only; no system clipboard is accessed.

Build376.08s passed with no changed-file warnings; unrelated warnings/native-build deprecation remain. Inventory4.973s; focused test26.35s; archive2.827s. Tracked core407.403s,410.230s including archive, excludes extraction/audit/platform work. No retries, timeout relaxation or Source/test edits after build. Each build/test/archive/extraction completed and was collected before dependent reads or input edits.

## Coverage evidence

Changed executable lines vs stated base: **26/28 (92.86%)**. Only lines49-50 of the retained one-argument decodePixels bridge are unhit. Tests exercise the explicit worker/authorization implementation and actual default loader/model path with an injected managed worker. This is line coverage, not every branch/race/errno/native allocation/device proof.

Only three fresh HOST profiles from one binary:XCTest discovery,XCTest execution,Swift Testing. Every raw individually validated, warning-free merge, matching app --object for llvm-cov show/export with empty stderr; both binaries contain __llvm_covmap and __llvm_prf_cnts. Raw copy/original hashes match. Prior live/root default outputs excluded. No old/cross-layout merge or child-process coverage claim; zero Swift function hashes do not establish layout compatibility.

All1,138 Source +831 test Swift inputs and live/archived binaries hash-match the prebuild snapshot/archive after extraction. No new production Source file.

Private .build/remote-image-authority-validation/final:

- Test host SHA-256:`97066e621d7facba0ebb903453a02efca6741ec1561f1abbbb00c6c7118f3e50`
- App SHA-256:`a3a0fe6033d1e3e62a47873030ee960250aabc8b58e0dc550f3f746851eaae16`

## Remaining boundaries

Remote model stale-entry/original-access conditions and other legacy native presentation consumers(Context/Artifact,clipboard text OCR,attachments,small icons) still need review. Tool/history/sandbox/generation batches are already integrated; this increment does not redo them. Health is availability only, never a source/account/model grant or trigger to decode/download/replay. Original source/root/FDA/account/model/control consent, independent budgets and actual retirement remain. Concurrent settings writers versus bind,direct defaults/distinct same-suite objects,external preferences/account/OS FDA ordering remain outside prior receipt contracts. Stable mutation identity is required before future write retries; none are introduced here.

The base includes #587 GUL-404 and #595 GUL-405 changes. They are compiled here, but their index-budget/PDF OCR behavior is not independently validated by these focused methods. Preserve them and earlier launcher/icon/cache/session/plugin,storage-only automatic quarantine recovery,chat/background and checkpoint/subtree/prune changes.

No real weights/CoreML/provider/network/download/home/network mounts/TCC/capture/mic/audio output/user clipboard/external apps/full suite/signing/hardware. No presentation layout/helper ABI/entry/package change, so no screenshot/copied probe. Audio/TCC/signing/performance precede microphone ownership. Real CoreML/model performance/full Xcode/DeveloperID/notarization/macOS13 Intel/actual quit recording remain unverified. HostFS/JSON/SQLite/raw memory/UI/AppKit/GPU/system memory remain boundaries; no arbitrary host/native crash/OOM/power-loss guarantee.
