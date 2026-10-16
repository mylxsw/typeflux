# GUL-399: audio/video file preview isolation

Stacked on #523 (`8943cb5c`). This increment moves file preview AVFoundation decoding into the existing media helper; it does not change microphone capture or complete GUL-399.

## Delivered boundary

`AskFilePreviewRenderer` no longer creates `AVURLAsset`, `AVAssetImageGenerator` or `AVAssetReader`. Its owned background request goes through `MediaPreviewDisplay` and the existing preview pool; only validated RGBA pixels, duration/start metadata and eighty normalized waveform values return to the UI. No playback, audio device, model, permission UI or full app DI starts in the helper.

`MediaAVDecoder` owns asset loading, preferred-transform video thumbnails and float PCM extraction. The requested evidence time is clamped to `[0, max(0, duration - 0.001)]`; nonfinite UI input still means zero. Waveforms cover up to thirty seconds from that position, with the existing eighty peak buckets and silence normalization. Preroll and samples outside the requested window are excluded. Video output keeps the requested pixel bounds and validates the original natural size before frame decoding (finite, positive, at most 100,000 per axis and 100 megapixels).

The allowlisted preview operations share the existing protocol version/UUID envelope. Audio responses must have no raster/pages and exactly eighty finite values in `[0,1]`. Video responses must have one unpaged raster and no waveform. Both require a finite nonnegative duration (at most `Int32.max` seconds, keeping CMTime conversion bounded) and the exact expected clamped start. Mixed image/PDF/AV metadata is rejected. No failed operation is replayed.

Common local clips can exceed the attachment import ceiling, so AV requests use a separate **512 MiB** private input-copy limit; image/PDF/attachment inputs retain **50,000,000 bytes**. The helper uses a private hard link to the copied input, with a format extension from the existing preview policy allowlist; extensionless input defaults to WAV/MOV by operation. The original filename/path is not sent as a format hint. The hard link adds no second file copy and is removed on normal completion or failure; the directory lease retains it through actual child retirement after a crash. AVFoundation does not reliably recognize extensionless files. No whole-file Data allocation is used. Chunked parent copying checks cancellation and growth. Native PCM blocks are checked before allocating a Swift array: at most **4 MiB per block**, a multiple of four bytes, and **128 MiB total** per request. Timestamp checks precede integer conversion. These are explicit refusal limits, not a claim to bound all OS decoder allocations.

AV work uses the existing two-child preview pool, three-second process deadline, rolling failure budget, 16 KiB stdout limit, private files and confirmed-reaping lease. The loader's three-second UI deadline also cancels copying/work; a stuck host filesystem syscall can retain a bounded slot. Cancellation or shutdown cannot publish a late result. The helper's existing 35-second orphan alarm remains. All owned resources remain retained until both host return and actual child collection; no new queue, replacement pool or global worker is introduced.

The helper entry point is now asynchronous for AVFoundation's loading APIs. Its bounded frame reader/writer and redacted error mapping are shared with the synchronous image/PDF test adapter. SwiftPM, the Xcode target and dev/release packaging already embed the same helper; no new product, signing target or resource is needed. The file metadata/index worker's 8 MiB protocol, directory progress and metadata policy are unchanged.

## Validation

Self-review covered process ownership, result identity, finite-number/byte limits, format-hint path safety, stale-result rejection and the absence of original AV decoding in `AskFilePreviewRenderer`. No full suite was run.

The initial focused pass executed **48 distinct Swift methods**: 33 XCTest and 15 Swift Testing. Five failed: four exposed a real extensionless-private-input compatibility bug (native audio/video, real helper, evidence time, visual video), and one hit the existing metadata worker's three-second cold-start timeout. An actual copied-helper audio probe also failed before correction. The fix supplies an allowlisted extension using a private hard link; tests now exercise uppercase WAV, MOV, extensionless defaults, path-injection rejection and normal link cleanup.

After the correction, the **20 affected methods passed** (17 XCTest and 3 Swift Testing). This included all six new `MediaAVPreviewTests`, eleven `MediaPreviewTests`, the evidence-time method, and the two previously failing visual methods. The metadata-worker timeout did not recur; no timeout value was changed. The 28 other initial methods exercised unchanged worker/loader/controller/protocol and cancellation paths. Thus 48 distinct methods were validated across the pass and focused correction; this is not a claim that the final retry reran all 48.

Commands use `scripts/test_runtime.py`'s sanitized `child_environment()`:

```text
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
xcrun otool -l <test-binary>  # verified __llvm_covmap and __llvm_prf_cnts
xcrun otool -l <media-helper> # same
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter <explicit-scope>
python3 -m unittest scripts/tests/test_media_packaging.py
```

Initial scope: `MediaAVPreviewTests`, `MediaPreviewTests`, `MediaProtocolTests`, `MediaWorkerTests`, `AskFilePreviewLoaderTests`, `AskFilePreviewControllerTests`, `AskContentPreviewTests/mediaPreviewStartsAtTheMatchedSegment`, and the backtick-named `AskFilePreviewVisualTests` methods `real text PDF image and audio renderers`, `video frame and invalid media`, `cancelled renderers do not publish content`.

Final retry filter (passed as a subprocess argument, preserving literal backticks):

```text
^Typeflux(?:Focused)?Tests[./](?:MediaAVPreviewTests|MediaPreviewTests)[./]|^Typeflux(?:Focused)?Tests[./]AskContentPreviewTests[./]mediaPreviewStartsAtTheMatchedSegment|^Typeflux(?:Focused)?Tests[./]AskFilePreviewVisualTests[./]`(?:real text PDF image and audio renderers|video frame and invalid media)
```

Measured command times: initial direct build **243.07 s**, initial tests **18.98 s**; correction build **46.19 s**, affected tests **17.83 s**. Both packaging tests passed (**0.207 s**). A synthetic one-second PCM WAV through the actual helper copied to `Fixture.app/Contents/Helpers` passed (**0.189 s**), confirming selected start, duration and eighty normalized samples. These synthetic probes are not codec/hardware performance benchmarks. The helper Mach-O reports minimum macOS **13.0**; no full Xcode build, signed release, notarization or macOS 13/Intel hardware run was performed.

Changed executable lines: **199/205 = 97.07%**, including helper-only source via `llvm-cov --object`. `av-preview-coverage.json` gives per-file counts. Every profile used for this report comes from the **one final correction build**: three host profiles, one existing file-worker profile and six media-helper profiles (including the copied-helper probe). All ten individually passed `llvm-profdata show` before merging, with no warnings. Initial-build profiles were archived separately and are **not** included; no counter layouts are mixed. The six uncovered lines are the Data-input copy limit, three compatibility-result defaults, the attachment decoder's defensive preview refusal, and the async command's malformed-input catch. Native decoder line coverage is 100%, but guard-line coverage does not prove every rejection branch, native allocation failure or the 35-second alarm expiration.

SHA-256 of the measured final artifacts:

```text
test binary 2522a716bef434486badc4fb2453e5838686c7dbed60b9e6d9527e2e6e421aa9
media helper 9d69e5b0e19c9684ee1ab03fccad865ac1b06696a7c4872b45bbc683e7e171c4
profile 1fe9d5cf19120133089203975425641f2e91acc33c9238f8fc3f67dfbe592e30
```

## Remaining work and limits

- Typed/tool image validation, local-tool JPEG conversion, stored artifact presentation and generated-image validation still contain native media calls. Their migration must retain generated output and approvals without replaying a paid generation or Agent operation.
- SVG/document Quick Look paths remain macOS-managed services, not this pool. File metadata and semantic extraction retain their existing workers. The preview view remains a static image/waveform display with no autoplay.
- Native codec memory allocations, filesystem copying, normalized display, screenshots, SQLite/JSON/import/export and UI still have process/OS boundaries. A crash can leave private temporary files; no arbitrary host crash, power-loss cleanup, security sandbox or system-wide OOM guarantee is claimed.
- Persisted health/settings and condition-driven lifecycle integration for media/native/inference pools remain. The registry still covers three stores. Real CoreML performance, release signing/notarization, Intel/macOS 13 hardware, AppKit quit/recording interactions and audio/TCC/signing/performance verification before deciding capture isolation remain unverified. Keep the overall issue in progress.
