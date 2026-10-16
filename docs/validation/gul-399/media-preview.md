# GUL-399: file image/PDF preview isolation

This increment is stacked on #522 (`566ae1cba4fcedfb048e8924ff1bceb0d141108e`). The overall issue remains in progress.

## Boundary and behavior

File previews now send bitmap and PDF decoding to the existing `TypefluxMediaHelper`. `MediaPreviewDecoder` owns ImageIO source inspection, orientation handling, thumbnail creation, PDFKit page selection/text matching and CoreGraphics PDF rendering. The app links only the shared protocol; it constructs display images from validated, uncompressed RGBA pixels. Attachment import retains its existing protocol and separate pool.

Previews use an independent `MediaWorker.previews` pool: two disposable children, no queue or replay, a three-second process deadline, and its own rolling failure budget. The existing preview loader deadline, cancellation and selection/cache generations remain in force. AppCoordinator fences this pool on quit and waits for bounded retirement. Cancellation after dispatch or extraction cannot publish a late image. Resources and admission slots remain owned until both the caller returns and the child is actually reaped; delayed removal stays outside the reaper callback thread.

Input copies are private, fixed-name regular files capped at 50,000,000 bytes. Preview requests allow 32 KiB, including at most 16 KiB of passage text; attachment requests remain 1 KiB. The helper reads bounded chunks until EOF so a long passage is not treated as a complete short pipe read. The versioned UUID envelope permits only the image/PDF preview operations and rejects mixed attachment/preview results. Preview stdout is capped at 16 KiB. The original file/semantic worker's 8 MiB response contract and scan progress behavior are untouched.

Pixels are separate fixed-name `raster-0` through `raster-2` files. Each raster has an explicit width, height, stride, byte count and optional page number; there are no child-selected paths. The host checks request identity, exact selected/default page ordering, page count, dimensions, stride and file size before constructing a bitmap. It opens outputs relative to the owned directory descriptor with `O_NOFOLLOW|O_NONBLOCK`, requires regular files with one link, reads a bounded exact byte count and retains its own data after directory cleanup. Symlinks, FIFOs, directories, missing, short and oversized outputs fail closed.

Requested dimensions must be finite and positive, at most 4096 per axis and four megapixels per raster (at most three rasters / 48 MiB per result). Image sources retain a 100-megapixel/100,000-axis ceiling. A valid evidence page renders only that page; absent/out-of-range evidence renders the first three pages. Rotation, aspect fit, PDF page totals, Unicode whitespace/diacritic matching and passage highlights are preserved. Pathological PDF boxes outside 0.01...1e9 points are refused before integer conversion. Images honor EXIF orientation and do not upscale. Requests beyond these explicit limits produce unavailable preview rather than unbounded allocation.

SVG retains the existing macOS Quick Look service path, as do document previews. Failed bitmap/PDF decoding does not fall back to another original-media decoder in the host. This change does not replace Quick Look's implementation or claim its service is owned by this pool.

The existing SwiftPM runtime target automatically includes the new decoder files. Xcode links the same package product and embeds the same executable under `Contents/Helpers`; development and release copy/signing paths need no additional target or resource. The macOS deployment baseline remains 13.0.

## Validation

Self-review preceded execution. **44 distinct Swift test methods passed across the initial pass and targeted follow-ups**, plus **2/2 packaging tests** and a real copied-helper raw-RGBA probe. No full suite ran.

| Scope | Behavior |
| --- | --- |
| `MediaPreviewTests` (11) | Request/raster bounds, mixed protocols, output identity/stride/page checks, native malformed/truncated/oversized input, image orientation, PDF selection/rotation/highlights/password protection, Unicode offsets, output symlink/FIFO/directory/size refusal, retained output lifetime, two slots until confirmed reaping, actual crash/hang children, real helper and late cancellation |
| `MediaProtocolTests` (7), `MediaWorkerTests` (9) | Shared attachment protocol and process ownership regression, independent admission/cooldown, no replay, copy/input limits, shutdown, malformed output, cancellation and real child faults |
| `AskFilePreviewLoaderTests` (7), `AskFilePreviewControllerTests` (4) | Cache identity/eviction, memory pressure, malformed dimensions before integer conversion, cancellation/deadline, stale selection and prefetch |
| Four `AskContentPreviewTests` methods | Evidence page/passage cache identity, actual child PDF highlight versus plain pixels, page defaults, Unicode offsets |
| Two `AskFilePreviewVisualTests` methods | Actual image/PDF/text/audio renderer integration and immediate cancellation of each renderer |

Build/test children used `scripts/test_runtime.py`'s sanitized `child_environment()`. Commands:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
# Verify __llvm_covmap and __llvm_prf_cnts in both test bundle and media helper.
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '<scope>'
python3 -m unittest scripts.tests.test_media_packaging
```

Initial selected scope (42 methods actually selected):

```text
^Typeflux(?:Focused)?Tests[./](?:MediaPreviewTests|MediaProtocolTests|MediaWorkerTests|AskFilePreviewLoaderTests|AskFilePreviewControllerTests)[./]|^Typeflux(?:Focused)?Tests[./]AskContentPreviewTests[./](?:sameFileReloads|previewCacheSeparates|pdfMatchUses|whitespaceNormalization)
```

The initial command also tried to select two backtick-named renderer methods without their leading backtick, so they were not selected. After inspecting the prebuilt inventory (no rebuild), these two methods were run:

```text
^Typeflux(?:Focused)?Tests[./]AskFilePreviewVisualTests[./]`(?:real text PDF image and audio renderers|cancelled renderers do not publish content)
```

The cancellation method passed; the real-renderer method hit the existing file metadata worker's startup timeout at 3.123 seconds. A separate harmless file-worker probe returned correctly in 0.046 seconds. Only the failed real-renderer method was retried, with no source or timeout changes; it passed in 0.858 seconds. The initial timeout was not reproduced, and this does not establish a cold-start latency guarantee.

That retry's SwiftPM post-test coverage merge failed while reading a file-worker child profile with an unfinished header. After the child exited, **all 13 profiles passed `llvm-profdata show` and merged with exit 0 and no warnings**. The child profile was not dropped, and the tests were not rerun merely to regenerate coverage. Two earlier prebuilt-inventory invocation mistakes (executing a bundle as a program, then omitting the native DYLD test paths) were corrected using `test_runtime.native_environment`; they did not rebuild or execute test methods and their diagnostic profiles are excluded.

Preparation builds: **185.55 s** (test fixtures needed explicit `CGFloat.nan`/`CGFloat.infinity`) and **32.89 s**. Initial focused test command: **13.19 s**; renderer follow-up: **24.80 s**; failed-method retry including the unsuccessful automatic coverage merge: **2.47 s**. Packaging: **0.161 s**; actual bundled synthetic-image probe: **0.140 s**. Recorded build/test/packaging/probe total: approximately **259.20 s**, excluding coverage analysis and read-only diagnostic probes. There were no production changes after the first build and no source changes after the successful second build.

The copied `Contents/Helpers/TypefluxMediaHelper` rendered a synthetic 2×2 red PNG into exactly sixteen expected RGBA bytes. A symbol audit found **0** `TypefluxMediaRuntime` symbol lines in the app executable and **112** in the helper. `vtool` reports a **13.0** minimum OS. These checks do not replace a full Xcode/release build, Developer ID signing, notarization or a macOS 13/Intel hardware run.

## Coverage attribution

Changed executable lines: **238/243 = 97.94%** relative to #522. `media-preview-coverage.json` contains per-file counts and SHA-256 hashes. The helper is included as an additional `llvm-cov --object`, so helper-only code is counted. All thirteen profiles belong to the same final build: seven test-host, five media-helper (including the copied-helper probe), and one existing file-worker. No profiles across changed counter layouts or from earlier GUL-399 increments were merged.

The five uncovered lines are the four DI/quit bridges and the attachment-only decoder's defensive rejection of a preview operation. Guard-line coverage does not prove every rejection branch, native allocation failure, alarm expiration or real AppKit quit/recording interaction. The new display path's success, malformed-file refusal and actual child lifecycle are covered without constructing unrelated hotkey/audio services.

## Remaining boundaries

- AVFoundation video frame extraction and audio waveform reading in `AskFilePreviewRenderer` remain in the host. They need a separate media request/result contract for selected timestamps, duration and waveform samples; they are the next preview boundary. No microphone/capture change is included here.
- Tool/typed image validation (`AskTypedContent`, `AskLocalTools.jpegDataURL`), stored artifact presentation and generated-image validation still have native in-process paths. Migrating those must preserve approvals, permission revocation and already-generated output; decoder failure must not replay a paid generation or an Agent operation.
- Original filesystem copying, metadata/text reads, raw-pixel display, screenshot encoding, SQLite/JSON/import/export and UI remain host boundaries. A stuck filesystem syscall can retain a bounded worker slot; process isolation does not guarantee host/native-memory or system-wide OOM immunity. A host crash may leave private temporary files.
- Storage registry/settings health still covers three stores. Media, inference and native-command pools need further condition-driven lifecycle/health integration. Real CoreML performance, audio/TCC/signing verification before capture isolation, and actual AppKit quit/recording behavior remain required later stages. This increment is not whole-issue acceptance.
