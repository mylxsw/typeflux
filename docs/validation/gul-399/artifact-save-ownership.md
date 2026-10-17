# Artifact explicit save source and attempt ownership

Baseline: `19214cef79bd52aa55880983a4118edf0c2bf027`. The scope closes the demonstrated card save gap and publishes the [bounded whole-issue acceptance matrix](acceptance-status.md) and [stage 4 prerequisites](stage-4-prerequisites.md). It does not open another image/cache consumer audit chain or claim completion of the four-stage issue.

## Behavior

The small `AskArtifactSaveModel` captures the exact ref, original `AskArtifactAccess` and original attempt before initial artifact loading or the destination chooser. The card delegates its existing NSSavePanel and atomic export to this same production contract. Original memory source checks fence synchronous load/chooser/writer returns and errors. A retired invocation cannot enter the next step or clear a newer attempt's error. A stale denied entry preserves a still-authorized owned error; errors are projected only for exact ref/source identity.

The chooser remains explicit destination consent, independent of native readiness. The second full artifact load after the chooser is retained using the ORIGINAL access, including its production account/selection receipt and full store/workspace/grant/expiry checks. The final manifest ref, entry and digest are checked before write admission; `AskArtifactExport.write` retains its existing digest check and atomic write. An entered writer may have changed its sink before cancellation: one entered effect remains, no retry or rollback is introduced. Original files, saved bundles, producer receipts and outputs are unchanged.

Error projection and cancellation perform memory checks only. They never call load/validate, open a store, clean expired records, decode, launch a task or spend a native budget. Fresh access is sampled first and original access last through the existing retained source condition, with attempt/Task checks after callbacks. No new grant, worker, pool, dispatcher, helper ABI, full DI or test scheduler is introduced. Custom unscoped access retains its independent contract.

The card replaces unkeyed local save errors with this projection, retires saves on disappearance, and preserves clearing save errors after a successful explicit preview. Image/preview model authority and native accounting are unchanged. Scope is the described synchronous callbacks and body projection; not arbitrary Published/Combine/AppKit reentrancy, modal dismissal timing, filesystem permission transactions, all UI epochs or rollback of entered writes.

## Focused validation scope

Implementation and self-review preceded functional execution. `ArtifactSaveOwnershipTests` maps 11 new methods/20 parameter cases to original production-bound access, two explicit reads, source/account/selection revocation, exact-ref errors and getter zero I/O, initial/terminal cancellation, nested new owner vs old return/throw, one entered writer, final ref/digest/missing-entry failures, bounded unknown-error fallback, canceled destination and pure card body values. Destination is a URL VALUE only; fake writer records in memory and never writes it.

`ArtifactPreviewSourceTests` maps 11 reviewed regressions to shared source receipt ordering, denied entry, original binding, actual image continuation and changed card constructor/body. All selected bodies and called fixture helpers were read: private Data/text/JSON/HTML/invalid UTF-8 and raw CGContext pixels, never the separate encode helper. Existing actor gates release all continuations and caller tasks are awaited. New save tests use synchronous callbacks and join both canceled Tasks.

No NSSavePanel, actual export/destination write, store cleanup, system clipboard (including named), SystemClipboardContentActions, ConversationModel/AskTestFixture, Downloads/home/apps, NSWorkspace/Quick Look, window/host/layout/render/button/task launch, WebKit coordinator, encoder/codec/helper/Vision/OCR, real network/provider/paid request, model/device/audio/TCC/signing or full suite is executed. The panel and actual writer bridge are compiled but deliberately unhit. Body tests construct VALUES only and are not visual proof. No owned layout/ABI/entry/package change requires a screenshot or copied-helper probe.

## Results and provenance

**22/22 distinct methods passed on the first functional run** (11 new save +11 preview regressions), Swift Testing two suites in 0.063 s; zero XCTest methods selected. New save suite 0.004 s. No functional failure, assertion correction, retry, timeout relaxation or Source/Test input edit after the build. All build/inventory/test/archive/extraction jobs were collected before their dependent step.

Changed executable lines **52/56 = 92.86%** against the baseline: SaveModel 47/47, Card 5/9. Unhit Card 101 (preview-success cleanup) and 137/140/141 (real panel/writer forwarding). The entire denominator is retained. This meets the 90% changed-line goal, not all branches/races/devices or production UI/DI proof.

| Command | Total wall seconds |
| --- | ---: |
| Instrumented native build, jobs4 | 322.05 |
| Prebuilt inventory | 6.180 |
| Focused coverage execution | 26.52 |
| Archive after test collection | 2.374 |
| Core build/inventory/test | 354.750 |
| Including archive | 357.124 |

Extraction, source audit and platform/Git operations are additional. Build passed with no warnings in the two changed production files or new test; unrelated/pre-existing warnings and the native-build deprecation remain. The newer #599 launcher layout is compiled by this fresh build, not independently functionally validated.

Two fresh HOST profiles (XCTest discovery and Swift Testing execution) belong to ONE instrumented binary. Each raw validates; sparse merge and independent remerge are warning-free and byte-identical; matching app-object show/export and all-functions inspection have empty stderr; both app/test binaries contain both LLVM sections. All **1153 Source +870 Test =2023 Swift inputs** match PREBUILD/live/archive after extraction. Live/archived binaries and original/copied raw hashes match. The 452 reported function hashes are all zero, which is NOT counter-layout proof. Prior live/root default profiles were moved aside; new pre-test inventory root default is separately excluded. No mixed layout or child coverage claim.

| Binary | SHA-256 |
| --- | --- |
| Test | `37d9c628331701fb62fd3a6aae0818cb576c43b755c3d8fbc6fd6ec548a2ea3b` |
| App | `45559bce40715c4b4a007ec923e9cecb2e4b7300c8c9aa2c23d45dbd91ee600a` |

Private reproducibility archive: `.build/artifact-save-ownership-validation/final`; repository method and coverage JSON retain exact selection and exclusions. This archive is local verification evidence, not an attached deliverable or a promise of host-native crash containment.

