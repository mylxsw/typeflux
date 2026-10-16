# Tiled text batch authority

Validated base: main `4c2ad5b91ad10d806261da80a6ad7e753f93b619`.

## Behavior and self-review

TiledImageTextRecognizer captures existing native authorization once at whole-request entry when its base is VisionImageTextRecognizer, which is the audited production composition. The same immutable stamp reaches every internal band's native admission. Checks before cropping/reading, after each read and around final merge reject observed cancellation or retired generation. Short images and files use the same original stamp. Direct recognition still captures its own explicit invocation stamp; geometry retains the existing direct-entry behavior.

No protocol requirement, generic wrapper, pool, per-view ModuleHandle, full DI or global bypass was added. Custom and actor bases keep the existing ImageTextRecognizing contract and are not forced to depend on native availability. Custom wrappers/nested tiled compositions retain responsibility for any underlying native batch authority; they are not silently granted a generation. All production tiled constructors were audited: defaults and DI use the native facade directly. The optional explicit authorization overload performs no recovery work.

The crop constructor function defaults to the original CGImage.cropping operation and is captured per invocation; a narrow read-only fixture can hold between completed native bands. No producer scheduling/throttling, crop geometry, overlap selection, merge order, exact UTF16 regions, band/output limits or redaction failure semantics changed. Existing outer batch slots and native pixel/FD/private copy/child/host leases remain occupied through actual collection. A failed/canceled batch returns no partial merged text and never retries earlier bands. Fresh explicit requests may use current availability.

Self-review before tests traced all TiledImageTextRecognizer production constructors, native overload/default fallback, custom/actor dispatch, short/file paths, cancellation and merge boundaries. Original authority starts at whole tiled-request entry; earlier UI/account scheduling remains controlled by existing callers. Checks are not a linearizable filesystem/settings/permission transaction and cannot roll back an entered effect. No recovery-triggered OCR/translation/clipboard operation, new grant, write/export/install retry, deletion or side-effect replay. Native budgets remain independent and health recovery remains availability-only.

## Focused validation

Using scripts/test_runtime.child_environment:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '<explicit inventory in tiled-text-authority-methods.json>'
```

Prebuilt native_tools/native_environment/swiftpm-testing-helper inventory, not XCTest as a program. **53/53 distinct methods passed on the first functional run:**42 XCTest methods across six suites (0.176s execution) and11 Swift Testing methods across two suites (0.212s). Six new methods/seven cases cover:

- Holding before the second or third native admission, after earlier bands actually completed and worker activeCount is zero; managed disable/start then rejects old continuation without further pixel preparation/native calls or merged output. Fresh explicit whole batch completes.
- Pre-ready and pre-canceled whole requests with zero crop/pixel/native admissions and no readiness-triggered work.
- Two canceled batches held between bands retaining both outer slots until actual crop return, then allowing a fresh batch.
- Exact sensitive-region lookup and merged coordinates, plus native short-image/file forwarding.
- Actor custom base receiving every band/short/file without any native lane.
- Crop failure after a completed band returning no partial text, retaining healthy native availability and admitting a fresh request.

Existing selected methods cover overlap/dedup/exact bounds, output/geometry/UTF16 limits, direct preparation authority, uncooperative native retirement, source changes, independent budgets and failed redaction remaining failed after readiness. All held gates are released and tasks joined. No real helper, OCR/Vision engine, codec/decoder, screenshot/capture, translation window or clipboard operation. ImageTilingTests' synthetic file URL is only passed to a custom reader, never opened. Existing private FIFO/FD/input-copy tests remain local.

Build92.60s passed without changed-file warnings; existing unrelated warnings/native build-system deprecation remain. Inventory4.080s; test command22.13s; archive2.345s. Tracked core118.810s,121.155s including archive, excludes extraction/audits/platform work. No retries, timeout relaxation or Source/test edits after build. Every build/test/archive/extraction completed and was collected before dependent work.

## Coverage evidence

Changed executable lines vs stated base: **33/33 (100%)**, native facade6/6 and tiled recognizer27/27. This measures lines, not every branch/race/errno/native allocation/device.

Three fresh matching HOST profiles from one binary: XCTest discovery, XCTest execution and Swift Testing host. Every raw individually validated; warning-free merge; llvm-cov show/export use matching app --object with empty stderr. Both binaries contain __llvm_covmap and __llvm_prf_cnts. Prior live/root default profiles excluded; no old/cross-layout merge or child-process coverage claim. All1,127 Source +814 test Swift hashes verified against prebuild/archive after extraction, plus live/archived binaries. All1,141 Swift function hashes are zero and cannot establish coverage layout compatibility. No new production Source file.

Private evidence .build/tiled-text-authority-validation/final:

- Test host SHA-256: `f39c1f7454aa9a326c4d10813aaf41219cde51e1e1893c3dae6e74c68fd45ba2`
- App SHA-256: `959dbceb3cb2efe0a4a88afae28cc7b01e4ce1f51a61badf0edd8d0afc45f837`

## Boundaries and remaining work

This covers the audited production native tiled composition. Custom wrappers/standalone readers own their batch semantics; earlier UI/account/OS permission transitions and other media feature consumers remain outside this increment. Earlier settings receipts still exclude concurrent writers versus bind, direct defaults/distinct objects sharing a suite and external preferences/account/OS FDA ordering. Stable mutation identity remains necessary before future write retries; none added here.

Concurrent main `fb711a2d4cb072c0c1b1dd873146acdfcbb6f7ad` changes12 disjoint launcher-app/list paths after this binary's base. Preserve them at landing and verify actual main ancestry/tree/path blobs. This validation binary does not contain that increment; independent launcher behavior or the whole newer main are not claimed tested.

Private bytes/small raw CGImages/injected readers/runners/results only. No real OCR/helper/media/weights/CoreML/provider/network/download/home/network mounts/TCC/capture/mic/audio output/user clipboard/external apps/full suite/signing/hardware. No presentation/helper ABI/entry/package change, so no screenshot/copied probe. Audio/TCC/signing/performance precede microphone ownership. Real CoreML/model performance/full Xcode/DeveloperID/notarization/macOS13 Intel/actual quit recording remain unverified. HostFS/JSON/SQLite/raw memory/UI/AppKit/GPU/system memory remain boundaries; no arbitrary host/native crash/OOM/power-loss guarantee.
