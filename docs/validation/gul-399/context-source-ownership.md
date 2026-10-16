# Context image source and callback ownership

Baseline: `9497b9a8dea5e41627d2d457584c0b535369961b`. A stale denied invocation previously cleared context-image state solely because its epoch matched. Access callbacks could also cancel/invalidate the model and then return `true`, after which the old invocation could replace state, publish pixels or restore a failed identity.

`AskContextImageModel` now checks its original generation after entry, deduplication, terminal and projection access callbacks. It checks Task cancellation after entry/terminal callbacks and rechecks the incoming scope's visibility/epoch after entry authorization. Denied calls clear state only when the current state's own original access is revoked. Projection checks exact source, scope, epoch and original/current access; a fresh access object cannot authorize revoked original pixels. Failure eligibility is evaluated before cleanup, with ownership rechecked before retaining the failed identity.

Same-content/same-epoch success **and failure** deduplication remains intentional: body-like reloads, getter calls and native readiness do not retry failed input. Explicit cancel/reopen/new identity can start fresh work. Nil source reset, custom actor/independent decoders, native original grants, pixel/worker/FD/private-copy/child/host leases and actual collection are unchanged. No new wrapper, pool, DI, per-view handle, grant, native operation, recovery replay, producer rerun, clipboard write, export or paid request was added. View task identity and layout are unchanged.

## Functional validation

**34/34 distinct methods passed on the first functional run**: 15 XCTest methods in two suites (0.380 seconds execution) and 19 Swift Testing methods in three suites (0.144 seconds). Seven new methods include one with three parameterized cancellation cases. Exact prebuilt names and exclusions are in `context-source-ownership-methods.json`.

New tests use the actual small `AskContextImageModel`, private 2×2 raw pixels and injected decoders. They cover stale denied same-epoch/foreign/empty access preserving success and failure; incoming scope invalidation; pre-canceled and entry-callback-canceled calls; cancellation from original-access callbacks during denial/deduplication; original-authority revocation and getter callback invalidation; terminal owner/Task/scope cancellation on both success and failure; old held success/failure against a replacement; pixel capacity retained until the uncooperative decoder actually returns; and failed identity remaining deduplicated until explicit reopen. All held continuations were released and tasks joined. Terminal success fixtures return a valid in-memory raster; these new cases do not claim native-protocol execution.

Selected existing context-native authority tests separately exercise managed generation changes, pre-ready/no-replay, private raw RGBA/JSON replies, cancellation and final native checks (including required imageType echo). Other selected tests cover pure input/protocol, original access, bounded retirement and remote source ownership with fake transports. All selected bodies were reviewed. Custom context call sites for clipboard thumbnails, workflow images, browser favicons, Finder/small icons and Quick Look wrappers were inspected; their native/source preparation contracts were preserved, not independently validated or newly granted authority here.

No `AskConversationModel`/`AskTestFixture` object was created: those eagerly construct System clipboard actions and other production defaults. Production-account, actual helper/MIME encoding, attachment recovery, window/view-rendering, real icon/application and URLSession fixtures were excluded. Methods named copy/clipboard in the selected worker/protocol code use private fixtures or injected sinks; no pasteboard was accessed.

## Coverage and provenance

Changed executable lines: **27/27 (100%)**, all in `AskContextImage.swift`, versus the baseline. This is line coverage, not every branch, callback, interleaving, errno, device or runtime condition.

The mandated native build passed in 202.14 seconds without warnings in changed files; unrelated existing warnings and native-build deprecation remain. Prebuilt inventory took 5.289 seconds, focused test command 24.89, archive 13.690. Core wall time was **232.319 seconds**, or **246.009 seconds** with archive, excluding extraction, audit and platform operations. No retries, fixture corrections, timeout relaxation or Source/test edits followed the build. Each build, inventory, test, archive and extraction completed and was collected before dependent reads or edits. All run-owned jobs were collected.

Only three fresh HOST profiles from one matching binary were used: XCTest discovery, XCTest execution and Swift Testing. Every raw validated individually; sparse merge was warning-free. Coverage show/export used the matching app object, with empty stderr; all-functions profile inspection also had empty stderr. Both binaries have `__llvm_covmap` and `__llvm_prf_cnts`. **1,144 Source + 843 test Swift inputs** match the PREBUILD snapshot, archive and live tree after extraction. Live/archived binaries and original/copied raw hashes match. Old live/root-default profiles were excluded; zero Swift function hashes are not layout compatibility proof, and no child coverage is claimed.

- Tests SHA-256: `47f9101c709f86a03d83decb1ef3880a399ecff7b9c429e51b0e353bc0042cac`
- App SHA-256: `ac113e34f115bbb3414e96b6996911fbf9edb4e0949ab22972f3d04f234c9f21`

## Remaining boundaries

These checks cover synchronous **access callback** boundaries. They do not promise arbitrary reentrancy protection for Published/Combine/AppKit callbacks, an atomic account/FS/settings permission transaction, rollback of entered effects, or arbitrary host/native crash, OOM or power-loss immunity. Earlier UI/account/source transitions remain their callers' responsibility. Successfully completed valid pixels are not erased merely because native health later changes.

Only private bytes, raw pixels, fake transports/readers/runners and private FD/FIFO/sparse fixtures were used. No codec, OCR/Vision/helper process, network/provider/download/paid call, actual clipboard, home data, window, external app, capture, microphone/audio, TCC, real model or full suite ran. No presentation/helper ABI/entry/packaging change required a screenshot or copied probe. The baseline includes ODT/RTF/HTML/DOCX/PDF OCR/indexing-budget changes; compiling them is not independent functional validation of those features.

AskSmallIcon native preparation, clipboard image-copy/custom-native OCR outer entry, artifact access/commit callback ownership and broader external condition ordering remain. OS Quick Look, capture/live meter and audio ownership are separate. Original source/root/FDA/account/model/control consent, independent budgets, actual retirement, partial indexing/checkpoints/fallback and no-replay policy remain. Audio/TCC/signing/performance validation precedes microphone ownership. Real CoreML/model performance, full Xcode, Developer ID/notarization, macOS 13 Intel and actual quit-recording remain unverified.
