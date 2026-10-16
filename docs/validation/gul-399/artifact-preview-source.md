# Artifact retained preview source

Explicit artifact preview now retains the original complete ref, memory source and owning preview attempt with its loaded bundle. The card passes that receipt into the sheet instead of authorizing an old bundle with whatever access the card currently has. Projection requires matching ref/source identity, samples fresh memory access before original memory access, and checks attempt ownership after callbacks. Closing, replacement or owner release retires the receipt. Text, JSON, HTML, filename and preview web-error presentation are withheld when the original receipt is unavailable.

`AskArtifactPreviewModel.open` remains an explicit synchronous load. It fences memory callbacks and load returns/errors, preserves a still-authorized owned preview/failure against stale denied entry, rejects a mismatched manifest ref, and provides bounded safe failures. Its projection and close perform no filesystem validation/read, decoding, writes or task launch. The same production `AskArtifactAccess.boundImages` factory is exercised with fake memory contexts. No new native grant, worker wrapper, pool, dispatcher, full DI, global bypass, scheduling hook, helper ABI or package change was introduced.

The queued image continuation uses the retained original access and checks the preview receipt before entering the existing image model. Direct preview initializers and independent unscoped/custom access remain compatible; these callers retain their own lifetime contract. Original and current HTML enablement must both allow presentation. New permission/selection or explicit reopen can accept a fresh preview; body/readiness changes do not reload the source or rerun a producing tool.

## Review and scope

Baseline read immediately after branch creation: `0977a6ebbc57f4c533d677436b8efab3a4c12afe`. Reviewed card preview/error/sheet/save/copy, all preview callers, text/JSON/image/HTML/web-error branches, memory access factory, image model and relevant test bodies/helpers before selection. Implementation and self-review preceded each functional scope. Existing image native authority and callback fences were not rewritten.

Store validation is not a pure boolean: it opens/locks/reads manifests and checks workspace grants; load also cleans expired artifacts before reading bundles. Those explicit operations remain with load/copy/export boundaries. Neither getter nor body calls them. Account ownership remains the account, not a private-conversation cache partition. Native availability is not source, copy or export consent. Saved bundles, manifest/data and producing receipts remain intact on preview refusal. No tool/workflow/program/command/provider/paid generation, download, export/copy/write retry, overwrite, deletion or recovery replay was added. Entered effects cannot roll back.

This is a retained-preview/source projection contract at the described synchronous callbacks. It does not prove arbitrary Published/Combine/AppKit reentrancy, every UI epoch, live sheet-dismissal timing or a filesystem/settings/account permission transaction. Withholding occurs when projection/body is reevaluated; hosted UI was not exercised. Card-local **save-dialog** errors and the save/export lifecycle remain outside this readonly preview model. Existing explicit export revalidation is unchanged. Actual WebKit coordinator/message/dismantle behavior, earlier UI/native-fallback batches, OS QuickLook/capture/live-meter/audio and external permission ordering remain separate.

Production ConversationModel/System clipboard objects were not instantiated: their eager defaults touch pasteboard, Downloads/home and apps. Production source wiring is audited/compiled, with the same pure production factory tested through fake contexts and the actual small preview/image models. This is not full production object/DI integration. Direct legacy/unscoped receipts do not acquire an inferred account or owner lifetime. The visible layout and styles were not redesigned; this is a source-visibility fence, not a screenshot/hosted-render proof.

## Functional history

**27 distinct methods have passing results across two builds, not a one-shot 27/27 run.** The initial scope passed **26/26 on the first functional run**: Swift Testing, three suites, 0.055 s execution. Ten new methods/14 parameter cases covered bound-before-queue access, exact ref and original-last source, zero-I/O projection, stale denied success/failure, bounded denied/expired/corrupt errors, reentrant old load success/error, callback retirement, Task cancellation, closure/reopen, raw bytes and value-only content branches. Existing memory-source and ref-projection suites supplied 16 related methods. All continuations and tasks were collected.

Initial changed executable coverage was **65/73 (89.04%)**, including new model 48/48. The unexecuted View image continuation was then extracted into a shared production entry method, with one meaningful direct test for closed/foreign/canceled/revoked/text receipt admission before source preparation. The preview model Source file was unchanged; only the View Source and test file changed. After rebuild, only the affected preview suite ran: **11/11 passed** (0.115 s), including the ten initially passing methods and the added method. The other 16 initial methods were not rerun. There was no functional failure, assertion correction or timeout relaxation.

**FINAL changed executable coverage is 69/75 (92%)** versus the actual baseline: preview model 48/48, card/preview 21/27. The 90% goal is met. Six unhit View bridge lines remain in the denominator: button actions 99–100, sheet setter/content 126/129–130 and SwiftUI task launcher 219. The shared continuation itself is tested directly. This is not all branches, races, errno, devices or runtime/DI proof. Exact initial/final inventories, mapping and exclusions are in `artifact-preview-source-methods.json`.

New fixtures use private text/JSON/HTML/invalid UTF-8 and small byte arrays, fake source callbacks, the production memory factory, raw 2×2 pixels and injected decoders/sinks. No actual artifact filesystem source, native codec or helper is needed for the new receipt tests. Existing selected fixtures use private data/raw pixels and custom actor decoders; their held gates are released and tasks joined. Native code/budgets are unchanged and are not independently functionally validated by this projection scope.

Body tests construct SwiftUI **values only** across ready, revoked and legacy text/JSON/HTML/image/unsupported/truncation paths, asserting zero extra load/validate/decode/write counts. They do not install a host, lay out/render a view, construct a WebKit coordinator, open a window/application, invoke buttons/sheets or launch SwiftUI tasks. The production image continuation is invoked explicitly through its shared method with a fake source and custom raw-pixel model. Ordinary Swift Tasks test cancellation and are joined; no global executor freeze or exhaustive scheduling claim is made.

Every System clipboard action and pasteboard (including named), ConversationModel/AskTestFixture, Downloads/home, actual window/panel/WebKit host/application/icon/QuickLook, encoder/codec/helper/Vision/OCR, actual HTTP/provider/paid call, capture/audio/TCC/device and full suite was excluded. Unsafe artifact MIME, clipboard, real-helper and window-render tests and unrelated document/resource tests were not executed. No screenshot or copied-helper probe was required by an owned layout/ABI/entry/package change.

| Foreground stage | Wall seconds |
| --- | ---: |
| Initial native coverage build, jobs 4 | 346.210 |
| Initial prebuilt inventory | 4.083 |
| Initial focused coverage test | 20.700 |
| Initial archive | 2.016 |
| Shared continuation rebuild | 56.450 |
| Final prebuilt inventory | 4.864 |
| Affected-suite coverage test | 10.760 |
| Final archive | 27.930 |
| Builds + inventories + tests | 443.067 |
| Including archives | 473.013 |

Both builds passed with no changed-file warnings; unrelated warnings and native-build deprecation remain. No compile/functional retries or Source/test edits after the final build occurred. Extraction, review and platform delivery are additional, not separately timed. Every build/inventory/test/archive/extraction completed and was collected before its dependent step.

## Evidence integrity

FINAL evidence contains **two fresh HOST profiles from one binary**, XCTest discovery and Swift Testing execution; no XCTest methods executed. Initial two profiles and both binaries are archived separately in `initial-functional` and excluded from FINAL coverage. Their relocation/copy/binary hashes were verified. Exactly the View Source and test file changed between input snapshots; the new preview model file is identical across functional builds. App/test binaries differ, so profiles were not mixed.

Every final raw was validated individually. Sparse merge, matching-app-object show/export and all-functions inspection had empty stderr. App/test binaries contain both LLVM coverage sections. **1,149 Source + 856 test = 2,005 Swift inputs** match FINAL PREBUILD, live and archived hashes after extraction. Live/archived binaries and original/copied raw hashes match. All 378 reported function hashes are zero; zero Swift hashes do not prove layout compatibility. Prior live/root default profiles are excluded; no old/cross-layout or child coverage is claimed.

Private final evidence: `.build/artifact-preview-source-validation/final`.

- Test binary SHA256: `efea36ae41c043d994f1ab08de283fa5eeb8d49df8c159de5138308d2665619a`
- App binary SHA256: `1f89e8140db4103a106e62e85134b270d94bd0262701d2956a6466fde848b1f6`

The baseline includes #622 screenshot OCR indexing and prior document/indexing work, compiled but not independently functionally tested here. GUL-399 remains in progress for earlier UI/native-fallback accepted-request boundaries and separate external conditions. Real model/performance/device/signing/full-Xcode/macOS-13-Intel/actual quit-recording checks remain unverified. Host filesystem/JSON/SQLite/raw-memory/UI/AppKit/GPU/system-memory boundaries provide no arbitrary native crash/OOM/power-loss guarantee.
