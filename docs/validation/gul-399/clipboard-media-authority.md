# Clipboard metadata batch authority

Validated base: main `1cb98924a6078eef222f2a90ce08b1d7842076c0`.

## Behavior and self-review

ClipboardMediaInfoProvider captures existing MediaWorker.Authorization at provider batch entry, after pure request validation and before slots/source preparation. Its detached work retains the original managed generation through source inspection, native admission and result delivery. Original cancellation/authorization is checked before and after initial source metadata, after final source identity verification and after awaiting the result. Pre-ready batches refuse before source inspection. A waiting PDF/duration/waveform batch cannot adopt a recovered lane; a fresh explicit batch can use the same provider normally.

Source identity uses the same stat/statfs fields and before/after comparison as previously. The immutable SourceReader constructor dependency allows counting/held private fixtures; production constructs the same Stamp. Stamp performs metadata syscalls, not source FD retention. Native copying/FD/child leases remain in MediaWorker. The two-slot provider admission still remains occupied until actual detached return, including cancellation-uncooperative source preparation. Already-entered effects cannot be rolled back.

Self-review before testing traced Request validation, provider wrappers, preview/waveform views, ClipboardMediaProjection and its presentation scope. Projection already cancels replaced tasks, retains failed request identity to prevent body-recompute retry, and checks original access/generation before publishing. Those contracts remain unchanged. The new authorization begins at provider load entry; it does not claim a single epoch covering all earlier selection/UI work. No new grant, pool, per-view ModuleHandle, helper/full DI/global bypass, recovery probe or replay. Other native consumers retain their existing contracts, and standalone/custom workers remain responsible for their lifecycle semantics.

No presentation, helper ABI/entry or packaging change; no screenshot/copied probe. Existing source/account/presentation consent and independent health budgets remain unchanged. Health recovery only reopens availability and never starts metadata extraction. No model work, export/write/install retry, deletion or side-effect replay. Stable mutation identity remains necessary before future write retries.

## Focused validation

Commands use scripts/test_runtime.child_environment:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '<explicit inventory in clipboard-media-authority-methods.json>'
```

Prebuilt inventory used native_tools/native_environment/swiftpm-testing-helper, not XCTest as a program. **34/34 distinct methods passed on the first functional run**:24 XCTest in four suites (0.143s execution) and10 Swift Testing in two suites (0.207s). Five new methods/seven cases cover:

- Pre-ready actual provider/projection refusing without source reads; becoming ready does not retry the same attempted identity; an explicit new scope succeeds.
- PDF/duration/waveform source preparation held across managed disable/start, rejecting old batches without native calls; fresh explicit batches succeed.
- Two canceled source preparations retaining both admissions until actual reader return, then allowing fresh work.
- Revocation during the final source check rejecting an already-completed native value while preserving the private source bytes.
- Actual projection replacement during held provider preparation, retaining the fresh result after old task collection and rejecting old access without replay.

Existing safe methods cover protocol/result bounds, peak/resampling arithmetic, uncooperative native host retirement, source replacement, projection authorization/identity/capacity, independent native health persistence, original timeline batches and worker cancellation/FD/directory/child collection. All held fixtures explicitly release and join. Managed native results are injected JSON; no media decode or child helper executes. Provider real audio/PDF/default-helper methods and isolation real-helper methods were excluded. Panel/view/screenshots and playback suites were not run.

Build107.66s passed without changed-file warnings; existing unrelated warnings/native build-system deprecation remain. Inventory3.767s; test command22.74s; archive2.124s. Tracked core134.167s,136.291s including archive, excludes extraction/audits/platform work. No retries, timeout relaxation or Source/test edits after build. Each build/test/archive/extraction completed and was collected before dependent evidence work.

## Coverage evidence

Changed executable lines vs stated base: **14/14 (100%)**, all in ClipboardMediaInfoProvider. This measures executable lines, not every branch/race/errno/native allocation/device.

Only three fresh matching HOST profiles from one binary: XCTest discovery, XCTest execution and Swift Testing host. Each raw validated individually; warning-free merge; llvm-cov show/export use matching app --object with empty stderr. Both binaries contain __llvm_covmap and __llvm_prf_cnts. Prior live/root default profiles excluded. No old/cross-layout profile merge or child-process coverage claim. All1,127 Source +812 test Swift hashes verified against prebuild and archive after extraction, with live and archived binary hashes. All1,010 Swift function hashes are zero and cannot prove coverage layout compatibility. No new production Source file.

Private evidence .build/clipboard-media-authority-validation/final:

- Test host SHA-256: `bae661e1221c3b0d8065a61b1af35b831d83a6cc696f7e83b1de6b0f09ee2d52`
- App SHA-256: `a2f6278827da84976bc4c3b90f5d9b750cf1aaecf6bbd2a22166286f723ece48`

## Boundaries and remaining work

This closes a demonstrated provider preparation gap, not all feature/native epochs. Other consumers with deferred source/raw-pixel preparation still need an operation-entry audit. Checks do not make filesystem metadata, native operations, settings or permissions linearizable. Earlier settings receipts still exclude concurrent writers versus bind, direct defaults writes, distinct defaults objects sharing one suite and external preferences/account/OS FDA transitions.

Private bytes, injected readers/runners/results and in-memory scope/projection fixtures only; existing private FIFO/input-copy/FD tests do not touch user files. No actual clipboard access, apps/panels, audio output/decoding, PDF/video decode, capture/mic/TCC, home/network mounts/network/provider/weights/CoreML/download/full suite/signing/hardware. Audio/TCC/signing/performance precede microphone ownership. Real CoreML/model performance/full Xcode/DeveloperID/notarization/macOS13 Intel/actual quit recording remain unverified. HostFS/JSON/SQLite/raw memory/UI/AppKit/GPU/system memory remain boundaries; no arbitrary host/native crash/OOM/power-loss guarantee.
