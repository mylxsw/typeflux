Clipboard file recognizer original authority (GUL-399)
=====================================================

Baseline: `2a467deefed717342f997877b91bdb8276210798`. This is the file-only recognizer preparation/admission prerequisite; the outer queued copy action is still a separate entry.

`ClipboardTextRecognizer.recognize` snapshots existing native availability before slot admission and metadata inspection, or retains a supplied original authorization for future outer forwarding. It captures immutable worker/reader values per invocation, checks composed Task cancellation/original generation before and after metadata, passes that same stamp to the existing worker `perform(.clipboardOCR)` and checks before returning text. The response identity extraction is equivalent to the old `decode` wrapper; helper ABI/protocol/budget/timeout are unchanged.

The narrow `readRevision` dependency defaults to the same `ClipboardImageRevision` lstat metadata constructor; it does not open/read/retain a source FD. Native preparation still copies/opens the source later. Source revision matching, input/file/text limits, nil blank versus failure, two recognizer slots, independent clipboard OCR budget and native FD-copy-child-host retirement remain. An uncooperative metadata reader keeps its recognizer slot until actual return even when native lifecycle recovery can complete independently. No new pool/generic dispatcher/full DI/per-view ModuleHandle/global bypass/grant.

Readiness does not reread or run OCR. Fresh explicit recognizer calls may use current availability; old preparation cannot adopt recovery. No copy/paste/export/source producer/workflow/command/paid generation/write retry, model/DB deletion or input replay. Entered effects cannot roll back and the checks do not make an immutable FS/permission transaction.

Scope limit: the stamp begins at recognizer entry. `ClipboardContentAction.startText` still queues `actions.recognizeText`, and the default System action constructs the recognizer later. This increment does not stamp the whole outer copy request. Custom `ImageTextRecognizing` actions retain their separate contract. Existing outer account/permission/source checks and one-shot commit are unchanged. Default System actions/pasteboards/Downloads lookup are not instantiated in tests. The actual-action integration uses fake actions delegating to this recognizer and an in-memory commit sink; it is not a claim of default outer-factory integration.

Validation history
------------------

**25 distinct methods have passing results across runs, not a single 25/25 pass.** Initial 18 XCTest methods in three suites passed (0.418s execution); 6/7 new Swift Testing methods passed (0.126s overall). The failing fixture validated a typed refusal inside its fake runner, throwing before returning the native reply. The worker correctly treated a thrown runner error as an infrastructure failure. Fixed only the fake runner to return refusal JSON and prevalidate successful replies only. Production Source and app binary are unchanged from the first functional pass.

Final affected suite: seven `ClipboardRecognizerAuthorityTests` methods passed (0.115s). The other 18 initially passing methods were not rerun. No production/timeout relaxation or further functional retry.

New methods cover pre-ready/pre-canceled/frozen-pre-ready/foreign zero metadata/native work; metadata held across actual managed disable/start with zero old native and fresh success; two canceled uncooperative metadata readers retaining both slots; two canceled entered native calls retaining occupancy; a valid late reply refused after original admission revocation; actual `startText` with fake actions withholding a revoked recognition, no recovery replay, then one fresh explicit commit; blank nil versus controlled refusal without poisoning health. All gates are released and entered tasks joined. Native replies are pure synthetic `MediaResponse.ocr`, not decoded images or actual OCR text.

Exact initial/final inventory is in `clipboard-recognizer-authority-methods.json`. Mapping: new seven cover recognizer entry/preparation/result/collection and fake consumer compatibility; six selected isolation methods cover protocol bounds/source replacement/oversize/cancellation/one-shot sink/account-owner fencing; four selected OCR module methods cover bounded retirement/independent persistent budgets/corrupt health/typed refusal versus protocol faults; eight injected-worker methods cover the shared native gate. Existing module cancellation fixture uses its pre-existing 0.03s synthetic cleanup policy; no production deadline changed. Selected bodies and actual recognizer/System actions/startText/protocol/revision callers were inspected.

No real codec/helper/Vision OCR, system/named pasteboard, provider/network/download/paid call, image encoding, windows/apps/QuickLook, capture/TCC/audio, weights/CoreML/home/network mounts/signing/hardware or full suite. New tests use only private 1–3 byte files, lstat metadata, injected runner/reader/fake actions and memory sinks. Existing selected oversize test writes bounded synthetic private bytes. Unsafe real child/image/helper/pasteboard/window methods were explicitly excluded, not opt-in skipped. No presentation/helper ABI/entry/package change: no screenshot or copied-helper probe.

Coverage and provenance
-----------------------

Final changed executable coverage **13/13 (100%)** versus the baseline, using only the final affected scope. Not all branches/races/errno/devices/global DI/runtime proof. Valid late-reply rejection exercises the composed path, not every precise post-native/pre-final scheduling interleaving.

Direct native coverage builds with tests/jobs4 through `scripts/test_runtime.child_environment`: 69.79s and fixture-only 38.27s, both passed with no changed-file warnings (existing unrelated/native-build deprecation warnings remain). Native tools/environment/testing-helper inventories: 4.083s + 4.149s. Direct skip-build/no-parallel explicit-filter tests: 36.42s + 5.72s. Archives: 10.525s + 1.605s. Core tracked 158.432s; including archives 170.562s, excluding extraction/audit/platform work. Each build/inventory/test/archive/extraction completed and was collected before dependent reads/edits. No Source/test inputs changed after the final build.

Only TWO fresh FINAL HOST profiles from one binary: XCTest discovery and Swift Testing execution (no final XCTest methods). Initial three profiles and test binary archived separately and excluded. Each raw individually validated; sparse merge warning-free; matching app `--object`; show/export stderr empty; both binaries contain `__llvm_covmap` and `__llvm_prf_cnts`. All 1142 Source + 838 test Swift inputs match FINAL PREBUILD/live/archive after extraction. Sources also match the initial functional archive. Original/copied raw and live/archived binary hashes match. All 581 reported profile function hashes are zero, which does not prove layout compatibility. Prior live/root-default profiles excluded; no old/cross-layout/child coverage claim.

Private evidence: `.build/clipboard-recognizer-authority-validation/final`.

- Tests SHA256: `7d4e78467943a4ab2d7ef78e645fc4a8d20bc590fc9be72d20c456d2d5f2c09c`.
- App SHA256: `a9171be98b3d2fc05023ff35075918cdd4eab7896a292bff9b991e7ad930e059` (also identical to initial functional app).

The outer clipboard action/native factory and broader feature/native/source ordering remain. Earlier settings receipts exclude concurrent writers versus bind/direct defaults/distinct same-suite objects/external account/preferences/OS FDA. Independent budgets/original grants/physical retirement remain. Stable mutation identity precedes any future write retry; none added. Audio/TCC/signing/performance precede microphone ownership. Real CoreML/full Xcode/Developer ID/notarization/macOS13 Intel/actual recording quit remain unverified. Host FS/JSON/SQLite/raw memory/UI/AppKit/GPU/system memory remain boundaries; no arbitrary host/native crash, OOM or power-loss guarantee.
