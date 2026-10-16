# Text recognition preparation authority

Validated base: main `c6b1a26a0deed4bb9dcf349f9639d6aca699d722`.

## Behavior and self-review

VisionImageTextRecognizer captures existing MediaWorker.Authorization at direct recognition/geometry invocation entry, before slot reservation or detached source preparation. Original cancellation and managed generation are checked before preparation, after it, at native admission, after file revision verification and after awaiting the result. File metadata or pixel preparation that spans managed recovery cannot adopt the recovered generation. Fresh explicit invocations can succeed. Existing two-slot admission remains occupied until actual preparation/native return, including canceled uncooperative preparation.

File preparation still uses ClipboardImageRevision and its existing lstat/revision matching semantics. Raw preparation still validates MediaTextInput before allocating/drawing/copying RGBA bytes. The same pixel code is extracted into a bounded concrete reader; it validates matching shape dimensions as well. Narrow immutable per-recognizer readRevision/readPixels function dependencies allow held/counting private fixtures. Production defaults use the original operations. No source FD is retained by the revision metadata stamp; copying, FD, child and host leases remain in MediaWorker.

Self-review before tests traced direct recognition/geometry, TiledImageTextRecognizer, sensitive-info scanner/controller, launcher and translation entry guards and clipboard action commit fences. Text/geometry coordinate and exact UTF16-region contracts remain unchanged. Existing source/account/UI checks remain in their callers. This stamp starts at each direct recognizer invocation: a tiled request still invokes its base separately per band, and one immutable authorization across the entire multi-band request is **remaining work**. Earlier caller scheduling/selection does not acquire this new stamp. Standalone/custom recognizers retain their existing contracts.

No new grant, pool, generic wrapper, per-view ModuleHandle, full DI/global bypass, helper protocol/entry/packaging change, recovery-triggered OCR/probe or write/export/install retry/deletion/replay. Already-entered effects cannot be rolled back. Checks do not make filesystem, settings and permissions a linearizable transaction. No producer throttling/restart or change to foreground priority. Existing independent native budgets and actual retirement remain unchanged.

## Focused validation

Commands use scripts/test_runtime.child_environment:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '<explicit inventory in text-preparation-authority-methods.json>'
```

Prebuilt native_tools/native_environment/swiftpm-testing-helper discovery, not XCTest as a program. **43/43 distinct methods passed on the first functional run:**38 XCTest methods across six suites (0.204s execution), five Swift Testing methods in one suite (0.108s). Five new methods/eight cases cover:

- Pre-ready file/raw/geometry and pre-canceled recognition with zero preparation/native admissions.
- File, raw recognition and raw geometry preparations held across managed disable/start, rejecting old invocation without native work and accepting a fresh explicit invocation.
- Two canceled file or pixel preparations retaining both slots until actual return; no native calls, then fresh invocation succeeds.
- Injected valid text and geometry preserving exact whole-region lookup, unavailable unrequested ranges and sensitive finding materialization from private raw pixels.
- Preparation failures releasing admission without spending native health or poisoning a subsequent fresh invocation.

Existing selected methods cover protocol/UTF16/geometry bounds, uncooperative native retirement, source mutation/input bounds, tiling output limits, redaction failure remaining failed across readiness, synthetic detector and scanner behavior. Only two pure ImageTextRecognizerTests methods run; native OCR methods excluded. SharedOCR child decoder/real helper/translation windows/launcher fixture and redaction panel presentation methods excluded. All held fixtures release and join. No real Vision recognition, image codec/helper or device input; raw CGContext preparation is exercised.

Build112.10s passed without changed-file warnings (existing unrelated warnings/native build-system deprecation remain); inventory3.851s; test command23.16s; archive4.043s. Tracked core139.111s,143.154s including archive, excludes extraction/audits/platform work. No retries, timeout relaxation or Source/test edits after build. Each build/test/archive/extraction completed and was collected before dependent work.

## Coverage evidence

Changed executable lines vs stated base: **25/25 (100%)**, all in ImageTextRecognizer. Executable line coverage does not prove every branch/race/errno/native allocation/device.

Three fresh matching HOST profiles from one binary: XCTest discovery, XCTest execution, Swift Testing host. Each raw individually validated; warning-free merge; llvm-cov show/export use matching app --object with empty stderr. Both binaries contain __llvm_covmap and __llvm_prf_cnts. Prior live/root default profiles excluded; no old/cross-layout merge or child-process coverage claim. All1,127 Source +813 test Swift hashes verified against prebuild and archive after extraction; live/archived binaries verified. All1,136 Swift function hashes are zero and cannot prove layout compatibility. No new production Source file.

Private evidence .build/text-preparation-authority-validation/final:

- Test host SHA-256: `871fcf8f5a75eed719e69e7f2e2722f3d10eeee7aa268a9ee119f91ad6e46428`
- App SHA-256: `c60736e81f6f45dcd5193d77f73e2670617df27139ea7dd4646c48ba2e41178e`

## Remaining boundaries

Whole multi-band original authorization and broader feature/native lifecycle remain. Health recovery reopens availability only; it does not run a failed redaction, translation, clipboard write or old input. Stable mutation identity remains necessary before future write retries. Earlier settings receipts still exclude concurrent writers versus bind, direct defaults/distinct defaults objects sharing a suite, external preferences/account/OS FDA ordering.

Private bytes/small raw CGImages/injected readers/runners/results and in-memory controller/detector fixtures only; existing private file/FD tests remain local. No screenshot/capture, native OCR/Vision engine/helper, real media/weights/CoreML/provider/network/download/home/network mounts/TCC/mic/audio output/user clipboard/external apps/full suite/signing/hardware. No presentation/ABI/entry/package change, so no screenshot/copied probe. Audio/TCC/signing/performance precede microphone ownership. Real CoreML/model performance/full Xcode/DeveloperID/notarization/macOS13 Intel/actual quit recording remain unverified. HostFS/JSON/SQLite/raw memory/UI/AppKit/GPU/system memory remain boundaries; no arbitrary host/native crash/OOM/power-loss guarantee.
