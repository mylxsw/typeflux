# Clipboard OCR source callback ownership

The explicit OCR action now retains its entry generation before authorization and rechecks Task cancellation, owner generation, shutdown and vacant admission after synchronous entry callbacks. A precanceled caller or a callback that retires the owner cannot bind/queue fresh recognition. A callback that accepts another request cannot have its task overwritten by the old invocation.

Factory and original-permit callbacks are checked before source metadata and task admission. The queued task checks its original ownership before invoking recognition. Terminal authorization and permit callbacks, and failure authorization, are followed by Task/generation checks before commit or failure publication. An old callback cannot restore a retired completion or failure.

Native generation binding from earlier increments remains unchanged for default clipboardOCR and production's direct injected Vision recognizer. This change adds no worker wrapper, protocol requirement, pool, dispatcher, full DI, per-view handle, global bypass, helper ABI, new grant or replay. Independent custom/actor preparation contracts remain. Source versions, text validation, blank nil, account checks, commit once and actual native/FD/private-copy/child/host collection remain intact.

## Review and admission contract

Baseline `f7ae9d057ef0d46aac99177a5cd74aec530ebf8a` was read immediately after branch creation. Reviewed `startText`, cancel/shutdown/owner lifetime, factory contracts, the history caller's account/source/selection closure and image action's previously landed callback fences. Implementation and self-review preceded focused functional validation.

A request retired during synchronous entry authorization/factory/permit callbacks is rejected before task admission (`false`). Native unavailability or an ordinary source error with a current owner retains the existing accepted-then-failure contract (`true`, one failure callback). Cancellation after accepted admission keeps the slot until actual task return, rejects duplicates and does not replay recognition. A fresh explicit request remains available after collection. Entered commit effects cannot be rolled back or retried; the tests retain one entered nil commit even when its callback cancels the owner.

The checks cover these synchronous callback boundaries on MainActor. They do not promise arbitrary Published/Combine/AppKit reentrancy, all earlier UI/account/source epochs, an atomic filesystem/settings/permission transaction or recovery from arbitrary host crashes. The separate image action's later paste lifecycle was not rewritten. No producer/tool/workflow/program/command/paid request, clipboard/paste shortcut, export/write retry, deletion, overwrite or automatic recovery work was introduced.

## Focused validation

**30/30 distinct methods passed on the first functional run:** ten XCTest methods in two suites (0.206 s execution), plus 20 Swift Testing methods in three suites (0.426 s). Exact method names and exclusions are in `clipboard-ocr-source-ownership-methods.json`.

Eight new methods include 15 parameterized method cases. They cover precanceled and owner/Task/shutdown retirement at entry; nested accepted requests from authorization/factory/permit callbacks retaining their own task; canceled factory/permit binding with no queued recognition; cancellation before queued recognition and a fresh successful action; terminal valid-text authorization retiring owner/Task/shutdown; terminal permit callbacks canceling before true or false returns; retired failure authorization; held canceled recognition retaining admission until return, followed by one entered blank commit with no replay. All new continuations were released and surviving actions observed retired. Tests use synchronous callbacks and continuations, not a global executor freeze or exhaustive interleaving claim.

Existing selected methods cover source mutation, account/owner cancellation, duplicates, blank/failure/text limits, actual default and injected-native pure factories, managed recovery, two-slot physical collection and valid final-native revocation. Image-copy regressions include intentional dismissal after commit, one paste sink, account/revision checks and failure behavior. Existing owner-release fixtures retain their unchanged 20 ms cleanup. New callback tests use valid fake text; native regressions validate synthetic successful JSON rather than relying on invalid-protocol refusal.

No System clipboard action, pasteboard (including named), Conversation model/AskTestFixture, Downloads/home, actual window/application, encoder/codec/helper/Vision, HTTP/provider/paid call, capture/audio/TCC or full suite ran. Only private bytes/metadata, synthetic replies and injected commit/write/paste sinks were used. Unsafe methods that later encode images or construct pasteboards were explicitly excluded. The System bridge and production DI object were not instantiated. No presentation/ABI/entry/package change required screenshots or a copied-helper probe.

**Changed executable coverage: 17/17 (100%)** in `ClipboardContentAction.swift` against the baseline. The 90% goal is met; this is not every branch, race, errno, device or production-runtime boundary.

| Foreground stage | Wall seconds |
| --- | ---: |
| Native coverage build, jobs 4 | 98.030 |
| Prebuilt native inventory | 7.793 |
| Explicit no-parallel skip-build coverage test | 43.100 |
| Evidence archive | 5.046 |
| Build + inventory + test | 148.923 |
| Including archive | 153.969 |

Extraction, review and platform delivery are additional, not separately timed. Build passed with no changed-file warnings; unrelated warnings and native-build deprecation remain. No retry, fixture correction or timeout relaxation occurred. Source/test inputs were unchanged after the build. Each build/inventory/test/archive/extraction completed and was collected before its dependent stage.

## Evidence integrity

Only three fresh matching HOST profiles from one binary were used: XCTest discovery/execution and Swift Testing. Each raw was validated individually; sparse merge, matching-app-object show/export and all-functions inspection had empty stderr. Both binaries contain LLVM coverage sections. **1,146 Source + 852 test = 1,998 Swift inputs** match the PREBUILD snapshot, live tree and archive after extraction. Live/archived binaries and original/copied raw hashes match. Prior live/root default profiles were excluded; no old/cross-layout or child coverage claim is made. All 873 reported function hashes are zero; zero Swift hashes do not establish layout compatibility.

Private evidence: `.build/clipboard-ocr-source-ownership-validation/final`.

- Test binary SHA256: `00539b22a454b63805765085d793599cbfa9e5fbc9d876f7ec38e4f5be15874d`
- App binary SHA256: `be237add1ccb9ee5b7c80c9dd63a6639c450c0075e5cf65943516abe0e95c2b5`

GUL-399 remains in progress. Artifact denied-entry/source projection, earlier UI/native-fallback batches and external condition ordering remain. Artifact getters must not call store load/validate on body recomputation: those functions perform filesystem IO and load also cleans expired artifacts. Prior document/indexing and other main features compiled but were not independently functionally tested here. Real model/device/performance/signing/full-Xcode/macOS-13-Intel/actual quit-recording checks remain unverified. Host filesystem, JSON, SQLite, raw memory, UI/AppKit, GPU and system-memory boundaries provide no arbitrary crash/OOM/power-loss guarantee.
