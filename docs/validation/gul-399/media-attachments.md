# GUL-399: attachment media decoding

This increment is stacked on #521, base `e34406bf`. It isolates the composer attachment import path; it does not complete GUL-399 or all media isolation.

## Delivered boundary

`AskAttachmentLoader` sends external image/PDF inputs to a disposable `TypefluxMediaHelper`. Only the helper links `TypefluxMediaRuntime`, which owns ImageIO decoding, PDFKit text extraction/rendering, and JPEG conversion. The host keeps folder/text attachment handling and the existing encoder for screenshot pixels already in memory. A symbol audit found **0** `TypefluxMediaRuntime` symbol lines in the app executable and **71** in the helper. The built helper's minimum OS is **13.0**.

The independent media domain admits two children, has no queue or replay, and uses the shared `ManagedProcess` lifecycle. Each child accepts one allowlisted operation with protocol version and request UUID. Input is a private directory's fixed `input` file, copied with a 50,000,000-byte bound; regular-file checks reject devices/FIFOs, and chunked copying checks cancellation and growth. Paths, names and original bytes are not placed in command arguments or logs. The request is at most 1 KiB and the response at most 16 MiB, enough for the existing eight scanned pages at 1,500,000 bytes each. The existing file-index worker's 8 MiB contract is unchanged.

The parent applies a 30-second child deadline, bounded stdout/stderr, cancellation and confirmed reaping. An independent 35-second alarm bounds an orphaned helper's ordinary native work. A lease retains the input and admission slot until both the caller returns and actual collection is confirmed; delayed cleanup runs outside the reaper callback thread. A child failure consumes the independent rolling recovery budget. No failed attachment is automatically resubmitted. App shutdown fences admission and waits up to two seconds; uncooperative work remains counted.

Images retain the 2048-pixel long edge, opaque white background, and JPEG size/quality reduction behavior, with a new 100-megapixel source ceiling and 100,000-pixel axis ceiling. Freshly encoded EXIF/IPTC/comment headers are removed too: ImageIO emits default metadata even for a newly drawn RGB image. The host uses a pure Swift JPEG header validator to reject invalid dimensions, ambiguous frames, malformed segments and disallowed header metadata without invoking ImageIO. This is structural validation, not a full independent JPEG entropy decoder or a security sandbox.

PDF text is accumulated page by page up to 200,000 characters, retaining page count and truncation state. A PDF without nonblank text produces up to eight ordered page images, retaining the localized page names and partial-page behavior. Native allocation for one page remains inside the child. The existing attachment/message limits remain; a batch now also bounds retained output before it reaches the draft.

The composer owns at most two batch tasks and at most fifteen source references per admitted batch. Session/selection changes, launcher replacement, conversation window close and model release cancel owned work. Cancelled tasks remain counted until completion, and late results cannot alter a replacement draft or its counters. Busy admission has a localized message in all five languages. Existing approval, privacy, durable execution receipts and unknown side-effect outcomes are unchanged.

SwiftPM and the Xcode project define the separate helper and shared protocol/runtime targets. The checked-in Xcode project and generator embed/sign the helper under `Contents/Helpers`. Development, attached-development and release scripts require and explicitly sign it. Missing helpers fail packaging instead of selecting a host decoder fallback.

## Focused validation

Self-review preceded execution. **61 distinct Swift test methods** were validated across the first pass and correction pass. Final correction scope: **27/27 passed**. **2/2 packaging contract tests passed**. No full test suite ran.

| Scope | Behavior |
| --- | --- |
| `MediaProtocolTests` (7) | Version/identity, response shape, JPEG structure/dimensions/metadata, malformed/truncated/oversized inputs, scanned/locked PDF, bounded text extraction, request framing |
| `MediaWorkerTests` (9) | Private copy and delayed reaping, two-child admission, cooldown/no replay, cancellation/late completion, shutdown, missing/FIFO/oversized files, bundled/development path resolution, real harmless crash/hang children |
| `AskAttachmentLoaderTests` (11) | Real helper conversion, metadata removal, image sizes, text/PDF/scanned-page behavior, ordering and first partial failure |
| `AskAttachmentDraftTests`, `AskAttachmentModelTests` (15) | Existing request limits plus batch ownership, session changes, busy refusal, source cap, preserved partial results, discarded stale output |
| `AskLauncherInputHistoryTests/lateAttachmentCannotFillReopenedLauncher` (1) | Old attachment work cannot fill a reopened launcher |
| `ManagedProcessTests`, `OwnedProcessReaperTests`, `ModuleRecoveryBudgetTests` (18) | Directly reused cancellation, process-group cleanup, output bounds, deferred reaping and recovery admission |

Build/test children use `scripts/test_runtime.py`'s `child_environment()`. Commands:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
# Verify __llvm_covmap and __llvm_prf_cnts in both the test bundle and media helper.
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '<explicit scope below>'
python3 -m unittest scripts.tests.test_media_packaging
bash -n scripts/copy_media_helper.sh scripts/build_release.sh scripts/run_dev_app.sh scripts/run_dev_attached.sh
ruby -c scripts/xcode_media_helper.rb
ruby -c scripts/generate_xcodeproj.rb
```

Initial filter:

```text
^Typeflux(?:Focused)?Tests[./](?:MediaProtocolTests|MediaWorkerTests|AskAttachmentLoaderTests|AskAttachmentDraftTests|AskAttachmentModelTests|ManagedProcessTests|OwnedProcessReaperTests|ModuleRecoveryBudgetTests)[./]|^Typeflux(?:Focused)?Tests[./]AskLauncherInputHistoryTests[./]lateAttachmentCannotFillReopenedLauncher
```

The initial 60-method pass found real helper lookup and JPEG-normalization failures, plus an invalid long-text PDF test fixture. Lookup now reuses the existing bundle-aware app executable resolver. The encoder removes its generated EXIF/IPTC headers before validation. The text-limit test supplies a deterministic page reader and verifies that extraction stops early; real PDF text extraction remains covered by the attachment loader's actual child test. One helper-location regression method was added. Only these affected suites were rerun:

```text
^Typeflux(?:Focused)?Tests[./](?:MediaProtocolTests|MediaWorkerTests|AskAttachmentLoaderTests)[./]
```

Build wall times: **203.31 s** (test fixture option-key compilation error), **69.81 s**, **67.87 s** (self-review additions), **49.22 s** (functional corrections). Initial test command: **34.81 s**; correction command: **12.71 s**; packaging tests: **0.14 s**. A synthetic 10×10 PNG was converted by the actual copied `.app/Contents/Helpers/TypefluxMediaHelper` in **0.125 s**, yielding a validated 959-byte response; it used no app DI, model, microphone or TCC prompt. Recorded build/test/probe total: approximately **438.00 s**, excluding coverage analysis, diagnostic probes and shell syntax checks. The two fault fixtures only kill or hang their own child processes; no hardware toggle or destructive system command was executed.

## Coverage attribution

Changed executable lines: **416/422 = 98.58%**, compared with `e34406bf`; details and binary hashes are in `media-attachments-coverage.json`. `llvm-cov` includes the helper as an additional object so helper-only source is counted. Seven profiles from the final correction build (three test-host profiles, three direct-helper profiles, one bundled-helper probe) were merged without layout mismatches.

For five production files unchanged since the initial pass, the report uses that pass's saved test binary and matching profile: `AppCoordinator.swift`, `DIContainer.swift`, `AskConversationModel+Attachments.swift`, `AskConversationModel.swift`, and `AskConversationWindowController.swift`. All other source files use the final build/profile. Profiles across changed counter layouts were not merged. Earlier GUL-399 increments' results were not reused. The uncovered lines are the four production DI/quit bridges, the actual conversation-window-close bridge, and the batch's local refusal assignment. Line coverage of guards and closure declarations does not prove every failure branch, native allocation failure, signal path or real AppKit lifecycle.

## Explicit remaining native paths and limits

- `AskFilePreviewRenderer` still decodes file images with ImageIO and AVFoundation media in the host; `AskFilePreviewPDF` still renders/highlights PDF pages there. These need their own preview result contract, evidence/page mapping, owned cancellation and normalized-pixel handling. Existing metadata/index and semantic workers were audited and not duplicated or narrowed.
- `AskTypedContent` still validates tool images using ImageIO; `AskLocalTools.jpegDataURL` still normalizes them in the host. `AskArtifactPresentation`/`AskStoredArtifactCard` and image-generation response validation also decode in process. Their callers, permission revocation and generated-image retention require a separate coherent migration; paid generation must never be replayed on media failure.
- Pasteboard acquisition, filesystem metadata/text reads, temporary copying/removal, normalized-image display, screenshot pixel encoding, SQLite/JSON/import/export and UI remain host boundaries. A stuck host filesystem syscall can retain a bounded slot. A host crash can leave a private temporary directory; no arbitrary power-failure cleanup guarantee is claimed.
- The two-child pool is not yet integrated into persisted module health/settings or condition-driven lifecycle. The registry still covers the three stores. No OS-level native-memory limit or immunity to process-wide/system-wide OOM is claimed.
- The 35-second alarm's expiration and actual AppKit quit/window-close integration were not manually exercised. No full Xcode app build, release Developer ID signing/notarization, Intel hardware or macOS 13 machine run occurred. Packaging contracts and a copied debug helper are not substitutes for those checks.
- Media preview/tool/generated-image isolation, remaining stage-2 adapters and audio/TCC/signing/performance verification before deciding capture isolation are still required. The prior inference increment's real CoreML/performance boundaries remain unverified. Keep the overall issue `in_progress`.
