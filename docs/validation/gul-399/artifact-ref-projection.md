# Artifact exact reference projection prerequisite

Artifact image presentation now reads a memory-only projection keyed by the complete `AskArtifactRef`. The model records the current attempt's ref separately from the ref that produced retained pixels. Card and preview image, model-error and busy presentation use this projection, so a new ref cannot display an old image or inherit another attempt's status before its task runs. Copying a different artifact cannot relabel retained pixels as the new source.

The getter never calls access load/validate, decodes, writes or starts work. Existing explicit operations retain full source/digest/grant/expiry/native validation, one copy with original encoded bytes, callback ownership and physical collection. Cancel clears both identities; canceled entry preserves an existing projection; old collected success/error cannot overwrite a newer projection. There is no new grant, worker wrapper, pool, dispatcher, full DI, per-view handle, global bypass, helper ABI or packaging change.

## Prerequisite boundary and review

Baseline `745f4ec099b7ce542e632df8e37486482ad96dec` was read immediately after branch creation. Reviewed model perform/load/copy/cancel, card/preview and access type, production account/selection/reset wiring, local-tool artifact access and store validation, all selected test bodies and fixture helpers. Implementation and self-review preceded functional validation.

This is the explicitly allowed exact-ref prerequisite, **not a completed account/source-authority fix**. `AskArtifactAccess` still has no memory authority identity. Production closures currently consult live session/selection; initial denied entry still replaces model state before filesystem validation. Same-ref stale access/account transitions, denied-entry protection and a memory-only original access predicate remain. Legacy raw model properties remain source-compatible for independent callers; production card/preview now use the scoped projection. Their separate local dialog/web errors and preview-bundle state are outside this model projection. Existing view task cancellation/identity behavior is unchanged.

Calling store validation from a getter would be wrong: validate opens/locks/reads the manifest and checks workspace binding; load additionally cleans expired artifacts before reading the bundle. None of that work was moved into body recomputation. The current ref is content/source identity, not permission to copy. A later account contract must retain full explicit filesystem checks and introduce only an honest memory condition, without forcing artifacts onto context-image settings or native health.

Custom/actor decoders, access initializers and write sinks retain their existing contract. No producer/workflow/tool/program/command/paid-generation request, copy/export/bundle-write retry, deletion, overwrite or health recovery replay was added. Entered effects cannot roll back. No atomic filesystem/settings/account permission transaction, arbitrary Published/Combine/AppKit reentrancy or all-UI-epoch guarantee is claimed. Unrelated document/indexing and other main features compile but are not independently functionally tested here.

## Validation history

**28 distinct methods have passing results across two builds, not a one-shot 28/28 run.**

The initial focused run passed **27/27**: eight XCTest methods (0.056 s execution) plus 19 Swift Testing methods in three suites (0.208 s). Six new methods/seven parameter cases cover all ten ref fields, repeated getter reads with zero load/validate/decode/write increments, keyed busy/failure, different-ref copy with retained old pixels, old late success/error, canceled entry/cancel reset and original denied/expired fallback. All held gates were released and tasks awaited. Existing safe methods cover custom/actor ownership, native stamps, two-slot physical collection, final revocation, callback retirement and copy sinks.

Initial coverage was **9/19 (47.37%)**: model 9/9, unexecuted view bridges 0/10. After reviewing this gap, one meaningful value-only test was added to check that constructing both body values does not invoke source preparation or writes in empty, ready, foreign-ref, busy and failure states. Product Sources were unchanged. The test target was rebuilt and **only the added method** ran: 1/1 passed (0.059 s); the earlier 27 passing methods were not rerun. This was added coverage, not a failed-test retry or production relaxation.

Value construction used injected models and private raw pixels. It did not install a host, lay out or render views, resolve application icons, create windows, encode images, execute button actions or take screenshots. It proves the body construction preparation boundary, not hosted UI/visual behavior. The layout itself was not redesigned. All suites touching MainActor state carry the required exclusive UI trait where applicable.

**FINAL changed executable coverage: 18/19 (94.74%)** using only the final binary's fresh profiles. Model 9/9, card/preview 9/10; the copy-button line 55 is unhit. The 90% goal is met without hiding this denominator. It is not every branch, race, errno, device or production DI boundary. Exact initial/final method inventories and exclusions are in `artifact-ref-projection-methods.json`.

No actual System clipboard action, pasteboard (including named), Conversation model/AskTestFixture, Downloads/home, window/application, actual icon/fallback/QuickLook operation, encoder/codec/helper/Vision, HTTP/provider/paid call, capture/audio/TCC or full suite ran. Some existing methods have Clipboard/Copy in their names but use injected sinks only. Unsafe MIME/real-helper/pasteboard/window-render/encoding methods were excluded. Native regressions use synthetic JSON/private RGBA and preserve the required image-type echo. No invalid native protocol was treated as successful completion. No ABI/entry/package change required a copied-helper probe.

| Foreground stage | Wall seconds |
| --- | ---: |
| Initial native coverage build, jobs 4 | 74.060 |
| Initial prebuilt inventory | 12.647 |
| Initial focused coverage test | 26.450 |
| Initial archive | 17.550 |
| Final test-only rebuild | 61.350 |
| Final prebuilt inventory | 4.191 |
| Added-method coverage test | 5.310 |
| Final archive | 2.562 |
| Builds + inventories + tests | 184.008 |
| Including both archives | 204.120 |

Extraction, review and platform delivery are additional, not separately timed. Both builds passed without changed-file warnings; unrelated warnings and native-build deprecation remain. No functional failure, fixture correction or timeout relaxation occurred. No Source/test inputs changed after the final build. Every build/inventory/test/archive/extraction completed and was collected before its dependent stage.

## Evidence integrity

FINAL evidence contains **two fresh HOST profiles from one binary**, XCTest discovery plus Swift Testing execution; no XCTest methods ran in the final pass. Each raw validated individually; sparse merge, matching-app-object show/export and all-functions inspection had empty stderr. Both binaries contain LLVM coverage sections. **1,146 Source + 853 test = 1,999 Swift inputs** match the FINAL PREBUILD snapshot, live tree and archive after extraction. Live/archived binaries and original/copied final raw hashes match. All 305 reported function hashes are zero; zero Swift hashes do not establish layout compatibility.

Initial three profiles/test binary are archived separately in `initial-functional` and excluded from FINAL coverage even though Sources/app binary are identical. The only changed Swift input between builds is the test file's added value-construction method/import. Initial raw relocation/copy hashes and initial source snapshot were also checked. Old live/root default profiles are excluded; no old/cross-layout or child coverage is claimed.

Private FINAL evidence: `.build/artifact-ref-projection-validation/final`.

- Test binary SHA256: `92d015b7b6a6e2722886f41793262c0118369b9d14ac3010869c93fcfffff496`
- App binary SHA256: `b73d175ddbca7c2737cd2009e79fb51f583586d33e896ced21c4d8ad009e23c5`

GUL-399 remains in progress for artifact memory source/account binding and denied-entry ownership, earlier UI/native-fallback batches and external condition ordering. Real model/device/performance/signing/full-Xcode/macOS-13-Intel/actual quit-recording checks remain unverified. Host filesystem, JSON, SQLite, raw memory, UI/AppKit, GPU and system-memory boundaries provide no arbitrary crash/OOM/power-loss guarantee.
