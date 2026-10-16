# Injected native clipboard OCR request authority

The explicit clipboard OCR factory now recognizes the concrete `VisionImageTextRecognizer` used by production DI. It captures that recognizer's existing worker authorization before the action's original source metadata and queued task, forwards the same stamp to recognition, and exposes the original permit predicate to final commit admission. An old queued request cannot adopt a recovered text-recognition generation.

The native branch uses the injected recognizer's own worker, independently of the factory's clipboardOCR fallback worker. Arbitrary custom/actor recognizers retain their existing contract. No protocol requirement, generic dispatcher, pool, full DI, per-view handle, global bypass, new grant, helper ABI or packaging change was added. Direct recognizer entry, exact text/UTF-16/region geometry, original file revision, blank nil versus failure, action admission and native/FD/private-copy/child/host physical collection remain unchanged.

## Review and boundary

Baseline `1f57541f80c3848c86ffbca0d3f42dc06fcf271f` was read immediately after branch creation. Reviewed the factory, System forwarding/direct recognition, all production System constructors, AppCoordinator/DI, the native facade and tiled precedent, and the explicit OCR action before implementation. AppCoordinator injects the direct Vision facade from DI into workflow clipboard actions; other System defaults use the already-bound clipboardOCR branch. Implementation and self-review preceded focused functional validation.

Binding is memory-only: no metadata, OCR, probe, capacity spend or new authorization. The action then performs its existing source-version preparation. In a ready-then-retired test that outer metadata has already been captured synchronously; zero-work counters refer specifically to the native facade's injected revision preparation and native dispatch, not every metadata read in the whole action.

Native availability is not source/account/copy consent. The existing original revision, authorization/account/generation checks, OCR text validation and one commit remain. Fresh explicit operations may use current availability; health readiness/recovery never recognizes or copies old input. No producer/workflow/tool/program/command/paid request/export/write retry, deletion, overwrite or rollback was introduced. Already-entered effects cannot be undone.

The factory handles the audited direct native type. Custom wrappers and nested recognizers remain responsible for their own outer contract. Tests use the exact production factory through fake actions and the actual action state machine, without constructing System actions, AppCoordinator or production DI objects. The System bridge remains unexercised; its pasteboard/Downloads defaults are forbidden in this scope. Earlier UI/source/account transitions, synchronous source-callback ownership beyond existing checks, arbitrary Published/Combine/AppKit reentrancy, all UI epochs and filesystem/settings/permission transactions are not proved by this native-generation fix.

## Focused validation

**30/30 distinct methods passed on the first functional run:** 13 XCTest methods in four suites (0.206 s execution), plus 17 Swift Testing methods in three suites (0.502 s). Exact names and exclusions are in `clipboard-vision-request-authority-methods.json`.

Six new methods include seven parameterized method cases. They exercise pre-ready acceptance followed by readiness with zero native preparation/dispatch and no replay; ready requests bound synchronously before queued entry then managed recovery; a valid completed recognition followed by final authorization revoking the original native permit before the commit sink; two canceled uncooperative metadata/native operations retaining both facade/action/native admissions until actual return; original source replacement and account refusal after completed recognition plus blank nil; account notification canceling held work with no early slot release or replay. Each new gate was released, surviving actions were observed retired, and native occupancy returned to zero. No global executor freeze or exhaustive scheduling proof is claimed.

The unrelated fallback worker stays unavailable throughout new native-branch tests, so a passing native result cannot be attributed to adopting clipboardOCR health. Synthetic successful `recognizeText` replies are protocol-validated, contain exact UTF-16 email regions after an emoji, and cross only private 1–3-byte input files. Final revocation asserts one valid reply, zero active native work and original permission before revocation. There is no image decoder, Vision call or helper process.

Existing selected tests cover custom actor independence, default clipboardOCR entry binding, owner release/duplicate/cancel, direct preparation/physical collection and exact geometry, pure serialization/protocol bounds, independent persistent health budgets/corrupt recovery, and eight fake/pure media-worker methods. The existing owner-release fixture's 20 ms cleanup is unchanged. Real-helper/encoding/raw-engine/UI/production-account methods were explicitly excluded rather than running whole suites.

No actual pasteboard (including named), System clipboard object, Conversation model/AskTestFixture, Downloads/home, window/application, image encoder/codec/helper/Vision, HTTP/provider/paid call, capture/audio/TCC or full suite ran. New commits are injected sinks only. No presentation/ABI/entry/package change required screenshots or a copied-helper probe. Main's XLSX/document indexing and other unrelated features compiled but were not independently functionally tested here.

**Changed executable coverage: 7/7 (100%)** in `ClipboardContentActing.swift` against the baseline. The 90% goal is met. This does not establish all branches, races, errno, devices or production DI/runtime behavior, nor revise earlier reports' System-bridge coverage limits.

| Foreground stage | Wall seconds |
| --- | ---: |
| Native coverage build, jobs 4 | 236.670 |
| Prebuilt native inventory | 4.735 |
| Explicit no-parallel skip-build coverage test | 26.930 |
| Evidence archive | 27.192 |
| Build + inventory + test | 268.335 |
| Including archive | 295.527 |

Extraction, review and platform delivery are additional, not separately timed. Build passed with no changed-file warnings; unrelated warnings and native-build deprecation remain. No retry, fixture correction or timeout relaxation occurred. Source/test inputs were unchanged after the build. Each build/inventory/test/archive/extraction completed and was collected before its dependent stage.

## Evidence integrity

Only three fresh matching HOST profiles from one binary were used: XCTest discovery/execution and Swift Testing. Every raw was individually validated; sparse merge, matching-app-object show/export and all-functions inspection had empty stderr. Both binaries contain LLVM coverage sections. **1,146 Source + 851 test = 1,997 Swift inputs** match the PREBUILD snapshot, live tree and archive after extraction. Live/archived binaries and original/copied raw hashes match. Prior live/root default profiles were excluded; no old/cross-layout or child coverage claim is made. All 984 reported function hashes are zero; zero Swift hashes do not establish layout compatibility.

Private evidence: `.build/clipboard-vision-request-authority-validation/final`.

- Test binary SHA256: `2f9ab047801aa7ce7325caad5286dbd5d60fd5213ee486af1da69933809882f1`
- App binary SHA256: `d5a8078afb8712af81b22192513895250ec470b5d0cd9d9b930a51b875042a7c`

GUL-399 remains in progress. Artifact denied-entry/source projection, remaining source-callback ownership, earlier UI/native-fallback batches and external condition ordering remain. Artifact getters must not perform store validation/load IO on body recomputation. Real model/device/performance/signing/full-Xcode/macOS-13-Intel/actual quit-recording checks remain unverified. Host filesystem, JSON, SQLite, raw memory, UI/AppKit, GPU and system-memory boundaries provide no arbitrary crash/OOM/power-loss guarantee.
