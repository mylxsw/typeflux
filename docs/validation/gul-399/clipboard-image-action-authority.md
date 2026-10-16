# Explicit clipboard image request authority

The default image-copy action binds native availability before its task is queued. `ClipboardImagePreparation.make` captures one existing worker authorization and forwards it through the clipboard facade's source preparation, native conversion and final action admission. A request accepted before readiness or retired before preparation cannot adopt a recovered generation. Recovery never replays input; a fresh explicit action can use current availability.

The factory is memory-only: no source metadata, IO, native work, capacity reservation or new grant. File lists and entries without image paths remain independent of native health. The protocol's default factory delegates existing custom preparation, preserving custom/actor owners' lifecycle contracts. System actions delegate to the same pure native factory. Direct clipboard-facade callers retain entry-time authorization unless an outer operation explicitly supplies its original stamp.

Native availability is separate from source/account/copy consent. Existing authorization, before-commit, source revision, PNG identity, TIFF protocol and byte/slot/FD/private-copy/child/host collection checks remain. The action now checks Task/generation after admission and terminal access callbacks and after an entered write. A canceled callback cannot admit a later write or restore old completion/failure state. An entered write can already have changed its sink; that effect is retained, never retried or rolled back. Intentional panel dismissal after committed=true still permits one intended paste under the existing post-delay account/revision checks.

## Review and scope

Baseline `8343acb866c2fea5bc1a4baa781f868fa98357cf` was read immediately after branch creation. Reviewed the protocol and all conformers, System preparation, clipboard facade, explicit action and history/launcher callers, including dismissal behavior. Implementation and self-review preceded focused functional validation.

The bound default request begins at accepted action entry, not earlier UI/account/source selection. Custom actions that wrap native work retain their own authority contract. The System bridge was not instantiated: its defaults touch pasteboard and Downloads/home. Tests exercise the exact production pure factory through fake actions and the actual action state machine; they do not establish full System-object/production-DI proof. Production custom Vision OCR remains a separate text-recognition-domain outer contract, not clipboardOCR or this image-copy fix.

Checks cover the described synchronous admission/commit callbacks, not arbitrary Published/Combine/AppKit reentrancy, every later paste callback, all UI epochs, an atomic filesystem/settings/account permission transaction or rollback. No new worker wrapper, pool, dispatcher, full DI, per-view handle, global bypass, helper ABI or packaging change was added. No producer/workflow/tool/program/command/paid-generation/POST/export/download/copy retry, deletion or overwrite was introduced. Raw receipts, stored images and private originals remain available after preparation failure.

## Focused validation

**31/31 distinct methods passed on the first functional run:** 16 XCTest methods in two suites (0.136 s execution), plus 15 Swift Testing methods in three suites (0.346 s). Exact names and exclusions are in `clipboard-image-action-authority-methods.json`.

Seven new methods include eight parameterized method cases and additional callback scenarios. They cover synchronously bound pre-ready and ready-then-retired requests; no readiness replay and successful explicit replacement; valid completed PNG/TIFF preparation followed by original native revocation before the sink; canceled uncooperative source/native work retaining action admission until actual return; file-list/nonimage/custom-actor independence; cancellation inside entry/terminal/write callbacks and entered-effect retention; denied and precanceled entry doing no binding or preparation. All gates were released and tasks joined. No executor freeze or exhaustive scheduling proof is claimed.

Existing selected tests cover duplicate/owner/cancel/account/permission/failure behavior, intentional dismissal and one paste, exact capture protocol, OCR request factory regressions, held source across managed recovery and byte/work-slot physical collection. Fake native replies are validated successful workflow-image protocol JSON, with eight PNG signature bytes and four TIFF signature bytes; they are not decoded images. The final-revocation test asserts one successful reply, zero native occupancy and original permission before revocation.

No actual system/named pasteboard, System clipboard object, Conversation model/AskTestFixture, Downloads/home, application/window, encoder/codec/helper/Vision, HTTP/provider/paid call, capture/audio/TCC or full suite ran. Unsafe fixture bodies were excluded explicitly, including methods that encode later despite injected runners. Tests use private files, synthetic protocol data and injected write/paste sinks only. No presentation/ABI/entry/package change required screenshots or a copied-helper probe.

**Changed executable coverage: 28/31 (90.32%)** against the baseline. Factory/protocol default 12/12, action 15/15 and facade forwarding 1/1; only the three System bridge lines are unhit. The 90% goal is met without hiding the bridge denominator or instantiating a forbidden system object. This is not every branch, race, errno, device or runtime/DI boundary.

| Foreground stage | Wall seconds |
| --- | ---: |
| Native coverage build, jobs 4 | 252.770 |
| Prebuilt native inventory | 4.822 |
| Explicit no-parallel skip-build coverage test | 25.860 |
| Evidence archive | 3.039 |
| Build + inventory + test | 283.452 |
| Including archive | 286.491 |

Extraction, review and platform delivery are additional, not separately timed. Build passed with no changed-file warnings; unrelated warnings and SwiftPM native-build deprecation remain. No retry, fixture correction or timeout relaxation occurred. Source/test inputs were unchanged after the build. Each build/inventory/test/archive/extraction completed and was collected before its dependent stage.

## Evidence integrity

Only three fresh matching HOST profiles from one binary were used: XCTest discovery/execution and Swift Testing. Each raw validated individually; sparse merge, matching-app-object show/export and all-functions inspection had empty stderr. Both binaries contain LLVM coverage sections. **1,145 Source + 849 test = 1,994 Swift inputs** match the PREBUILD snapshot, live tree and archive after extraction. Live/archived binaries and original/copied raw hashes match. Prior live/root default profiles were excluded; no old/cross-layout or child coverage is claimed. All 983 reported function hashes are zero; zero Swift hashes do not establish layout compatibility.

Private evidence: `.build/clipboard-image-action-authority-validation/final`.

- Test binary SHA256: `e3e7cb7290d8baef8daa2bb408b473abdac23eb218628110b177abeaf87cdb99`
- App binary SHA256: `1c027cb8d1249c3edd17cf65f36587da9b1e7db18ae04feb03121de1e09d84a2`

GUL-399 remains in progress. Production custom-native OCR outer binding, artifact denied-entry/source projection, earlier UI/native-fallback batches and external condition ordering remain. Artifact projection must not perform store validation IO on body recomputation. Prior document/indexing and other main features compiled but were not independently functionally validated here. Real model/device/performance/signing/full-Xcode/macOS-13-Intel/actual quit-recording checks remain unverified. Host filesystem, JSON, SQLite, raw memory, UI/AppKit, GPU and system-memory boundaries provide no arbitrary crash/OOM/power-loss guarantee.
