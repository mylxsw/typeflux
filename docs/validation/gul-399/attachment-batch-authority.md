# Attachment batch original native authority

Baseline: `05ae91e5e4baf3a68c769dc63943cf84a17921d1`. Default `addAttachments` snapshots existing media-extraction availability before its detached work. `AskAttachmentBatch.load` retains one original authorization across all sources, and direct loader entries retain their invocation's authorization before file metadata preparation. Image/PDF admission and final loader return use the same stamp. No recovery callback prepares, retries or replays input.

Text files and folders remain independent of native availability. A batch keeps earlier successfully completed attachments when a later native source refuses the original generation, and continues collecting eligible text/folders with the original source list. It cannot use a recovered generation for later images/PDFs. No completed output, original file or durable receipt is erased. Existing item/image/folder/payload limits, first-failure reporting, JPEG protocol bounds, source controls and worker FD/private-copy/child/host retirement are retained. No helper ABI, pool, generic dispatcher, full DI, per-view handle, global bypass, new grant, provider call, write retry or producer replay was added.

The narrow immutable `MetadataReader` default performs the same URL resource-value lookup. It allows held private metadata fixtures; it is not a source-permission transaction or a new metadata service. The model's optional custom batch loader remains independent and retains trailing-closure source compatibility. Default worker remains `.shared` / mediaExtraction, distinct from previews, query, indexing and reader domains.

## Functional validation

**32/32 distinct methods passed on their first functional run**: 13 XCTest methods in two suites (0.150 seconds execution) and 19 Swift Testing methods in five suites (0.176 seconds). Six new methods include a two-case PNG/PDF test. The exact prebuilt inventory and exclusions are in `attachment-batch-authority-methods.json`.

New cases prove:

- Pre-ready batches and retained pre-ready stamps cannot acquire native work after readiness; text/folder results survive, and a fresh explicit batch succeeds.
- The second private file's metadata is held **after the first native operation has actually returned, with activeCount zero**. Managed disable/start cannot authorize later PNG or PDF work from that old batch; the first completed image and trailing text survive.
- Direct file entry captures before metadata; retired/foreign image and PDF stamps refuse; fresh direct calls work.
- Two canceled uncooperative batches retain native occupancy and the explicit `AskAttachmentWork` owner entries until actual return/removal. A third request refuses; fresh work succeeds after collection.
- A valid synthetic native reply after original revocation cannot enter the partial batch; trailing text and private original bytes remain available.
- Pre-canceled metadata, cancellation during metadata, missing/unsupported files, text fallback and the eight-image batch limit remain controlled.

All held gates were released and tasks joined. Selected existing tests cover pure attachment DTO/draft/prompt/text behavior, owner cancellation, independent native health, expected refusals, private-copy retention and bounded worker retirement. The selected module fixture's 0.04-second cleanup timeout is pre-existing; no production timeout was relaxed.

**Object-level model/selection integration was not run.** `AskTestFixture` constructs `AskConversationModel`, whose eager `SystemClipboardContentActions()` default touches pasteboard/Downloads dependencies forbidden in this scope. Model/launcher fixtures, even those using injected attachment closures, were therefore excluded. The selected method named `AskAttachmentModelTests.ownerReleaseCancelsAndCancelledBatchDoesNotReadSources` constructs only `AskAttachmentWork`, not the conversation model. The three model forwarding lines are unhit; no frozen per-image substitute or full model/DI proof is claimed. Existing selection, draft, account and two-work-slot model logic was inspected and preserved.

## Build history and evidence

The initial mandated native build failed after 77.72 seconds because the compiler reported it could not open the SDK's `LibcShims.h`. Read-only inspection then found the referenced regular file present and readable. The cause is unconfirmed. The same build command, with **no agent changes to source, tests, SDK, toolchain or cache**, passed in 71.71 seconds; changed files emitted no warnings. Existing unrelated warnings and native-build deprecation remain. No functional test retry or input edit followed the final build.

Commands used direct native Swift build (`--build-tests --enable-code-coverage --jobs 4`) and skip-build, no-parallel Swift test with an explicit filter, through `scripts.test_runtime.child_environment`. Prebuilt inventory used `native_tools`, `native_environment` and `swiftpm-testing-helper`, not the XCTest binary as a standalone program. Inventory took 4.077 seconds; the focused command took 24.74; archive 3.661. Core build/inventory/test wall time was **178.247 seconds**, or **181.908 seconds** with archive, excluding extraction, audit and platform operations.

Changed executable coverage: **27/30 (90%)** versus the baseline. Loader lines: 23/23; batch/model file: 4/7. Only model forwarding lines 37, 39 and 40 are unhit. This meets the 90% line goal, not every branch, interleaving, device, errno or runtime condition.

Only three fresh matching HOST profiles from one binary were used (XCTest discovery, XCTest execution, Swift Testing). Each raw validated individually; sparse merge was warning-free. `llvm-cov show`/export used the matching app object and empty stderr; all-functions profile inspection also had empty stderr. Both binaries contain `__llvm_covmap` and `__llvm_prf_cnts`. **1,143 Source + 841 test Swift inputs** match the PREBUILD snapshot, live tree and archive after extraction. Live/archived binary hashes and original/copied raw hashes match. Old live/root-default profiles were excluded; zero Swift function hashes are not layout compatibility proof, and no child coverage is claimed. Each build, inventory, test, archive and extraction completed and was collected before dependent reads or edits. All run-owned jobs were collected.

- Tests SHA-256: `533b2637f7b3466306877ebb621da65acab4a0040da3bb5debd9df08ea233b0d`
- App SHA-256: `b54df73b41adb3be94840ff5c9ca1daebc2dfb559ab3c0ab2124cc3cfdc675c8`

## Limits and remaining work

Only private bytes/files/folders/text, raw synthetic protocol replies, injected readers/runners, FIFO/sparse fixtures and memory-only draft/prompt values were used. The handcrafted JPEG envelope is checked by the pure protocol validator, never decoded. No actual image/PDF codec, OCR/Vision/helper, pasteboard, Downloads/home data, picker/drag UI/window, external app, capture, audio, TCC, network/provider/paid call, real model or full suite was used. No presentation/helper ABI/entry/packaging change required a screenshot or copied probe. Prior RTF/HTML/DOCX/PDF OCR/indexing-budget changes compiled but were not independently functionally tested here.

Model object/selection integration, earlier UI/source/account transitions, AskSmallIcon, clipboard image-copy/custom-native OCR outer entry and remaining source-condition/reentrant callback ownership require further work. A retired grant stops new native admission, not previously entered FS/native effects or a completed valid attachment. No linearizable FS/settings/permission transaction, global heap cap, rollback or arbitrary host/native crash, OOM or power-loss immunity is claimed. External preference/account/OS FDA ordering and concurrent/direct/same-suite settings writes retain earlier limits. OS Quick Look, capture/live meter and audio ownership are separate. Audio/TCC/signing/performance validation precedes microphone ownership; real CoreML/model performance, full Xcode, Developer ID/notarization, macOS 13 Intel and actual quit-recording remain unverified.
