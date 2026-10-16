# Explicit clipboard OCR request authority

Baseline: `703e2f57a078d4fdb1e43c4a64793d56905bb234`. This increment binds the default file OCR request at `ClipboardContentAction.startText`, before its task and source metadata preparation. The same original native availability is retained through recognition and checked immediately before the existing one-time commit callback. Availability does not grant source access or permission to copy.

`ClipboardContentActing.textRecognition` has a backward-compatible custom default. `ClipboardTextRecognition.make` is the read-only factory used by System actions; it snapshots existing `MediaWorker.Authorization` without IO, OCR, capacity reservation or a new grant. Its custom `ImageTextRecognizing` branch stays independent. All conformers and production constructors were reviewed. In particular, AppCoordinator injects DI's `VisionImageTextRecognizer` into System actions: that custom branch retains its existing text-recognition lifecycle contract; this report does **not** claim that its earlier outer action now carries a clipboardOCR grant or that the entire production DI chain is covered.

Accepted unavailable requests still return `true` and report failure asynchronously. Duplicate admission, account/owner cancellation, source revision checks, text validation, blank `nil` and one-time commit behavior remain. Canceled work retains the action slot until actual return; native/recognizer/FD/private-copy/child/host leases are unchanged. No retry, producer rerun, clipboard write, paste, export, source deletion or recovery-triggered work was added. Tests use commit sinks only.

## Functional scope and history

**31/31 distinct methods passed on the first functional run**: 18 XCTest methods in three suites (0.820 seconds execution), plus 13 Swift Testing methods in two suites (0.202 seconds). Six new methods cover synchronous factory binding before queued work, pre-ready refusal and no readiness replay, ready-request revocation, fresh explicit action, valid native completion followed by final authority revocation, canceled uncooperative native collection, duplicate admission, custom actor/blank text independence, and denied/missing source behavior. All held gates were released and tasks joined.

The exact prebuilt inventory is in `clipboard-action-authority-methods.json`. Selected existing tests cover original recognizer grants, source mutation, OCR protocol bounds/refusals, account/owner cancellation, physical retirement and independent health budgets. Every selected body was reviewed. The pre-existing module cancellation fixture uses a 0.03-second cleanup timeout; no production timeout was relaxed.

The first build failed because a new test nested `#expect` inside another `#expect` closure, causing recursive macro expansion. Only that fixture was changed to store the accepted result before asserting it; product sources were unchanged. The final build passed without warnings in changed files; unrelated existing warnings and native-build deprecation remain. There were no functional retries or changes after the final build.

## Coverage and provenance

Changed executable lines versus the baseline: **20/23 (86.96%)**. The read-only request factory/custom default and action ownership logic are **20/20**. The three unhit lines are the System instance forwarding method (`ClipboardContentActions.swift:96–98`). The full change misses the 90% goal. We did not construct a System actions object merely to cover that bridge: this scope forbids pasteboard access, including named pasteboards, and System construction also has Downloads/home defaults. The tests exercise the exact production factory through fake actions and actual `startText`, not a frozen per-image substitute. This is not full System-object/DI/runtime, all-branch, race, errno or device coverage.

Only three fresh HOST profiles from one matching binary were used: XCTest discovery, XCTest execution and Swift Testing. Every raw was validated individually; sparse merge was warning-free. `llvm-cov show` and export used the matching app object with empty stderr; `llvm-profdata show --all-functions` also completed with empty stderr. Both live binaries contain `__llvm_covmap` and `__llvm_prf_cnts`. All **1,143 Source + 840 test Swift inputs** match the final PREBUILD snapshot, archive and live tree after extraction. Live/archived binary hashes and original/copied raw hashes match. Zero Swift function hashes do not establish layout compatibility. Prior live/root-default profiles were excluded; no old/cross-layout/child coverage claim.

Final hashes:

- Tests: `c2e98f2165074f0e4f6c64623d3cee407d682ae11b6ac529d74e08f3631bb39e`
- App: `8ef2bd0b7fcc10f152b871f18455ef0e9d44bed2bc3b9dc76d078a0d3b598847`

Wall times: initial build 240.09 seconds (fixture compile failure), final build 47.96, prebuilt inventory 5.340, focused command 32.01, archive 27.665. Build/inventory/test core: **325.400 seconds**; with archive: **353.065 seconds**, excluding extraction, audit and platform operations. Each build, inventory, test, archive and extraction was completed and collected before dependent reads or edits. All run-owned jobs were collected.

## Boundaries and remaining work

Only private 1–3-byte files, metadata, injected OCR JSON/runners, private FIFO/sparse fixtures and commit sinks were used. No SystemClipboardContentActions instance, pasteboard, Downloads, actual OCR/Vision, codec/helper process, screenshot/capture, window, external app, network/provider/paid call, audio, TCC, real model or full suite was used. No presentation/helper ABI/entry/packaging change, so no screenshot or copied probe was required. The baseline includes RTF/HTML/DOCX/PDF OCR and indexing-budget changes from other issues; compilation is not independent functional validation of those features.

Original source/account/selection transitions before accepted entry, custom native recognizer outer grants, image-copy outer entry, reentrant authorization callbacks and broader external condition ordering remain separate work. No FS/settings/permission transaction or rollback of entered effects is claimed. AskAttachment/AskSmallIcon and remaining feature consumers require further audit. OS Quick Look, capture/live meter and audio ownership remain separate; audio/TCC/signing/performance validation precedes microphone work. Real CoreML/model performance, full Xcode, Developer ID/notarization, macOS 13 Intel and actual quit-recording behavior remain unverified. Host FS/JSON/SQLite/raw memory/UI/AppKit/GPU/system memory remain boundaries; no arbitrary host/native crash, OOM or power-loss immunity is promised.
