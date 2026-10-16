Remote image source ownership (GUL-399)
======================================

Baseline: `5b411c99f3f100e2449163c7ff731e59a625f470` (#597). This increment changes remote model entry and projection ownership; the existing native authorization and independent budgets remain unchanged.

`AskRemoteImageModel.load` checks cancellation before and after the incoming MainActor access callback, before replacing any state. A denied invocation only clears state whose own original access is no longer valid. Old epochs, foreign scopes and denied same-epoch closures cannot clear a still-authorized success or failure. Accepted explicit loads still replace the previous attempt, including the same asset/access after readiness. No deduplication or health observer starts work.

The model retains original access for its accepted attempt. `displayed` checks the source, scope identity, epoch, original authorization and current authorization. The view uses this method; a fresh access object cannot bless old account pixels. Failed presentation ownership remains registered until explicit replacement/cancel/scope revocation, so a stale denied call cannot reset its fallback. Existing generation guards fence late completion; original native authorization is still captured before the internal task and rechecked before publication.

No layout, helper ABI, entry or packaging changes: no screenshot or copied-helper probe. Link/asset references remain available under existing caller access. No workflow, tool, paid generation, export, clipboard write, download retry or recovery replay is added. Physical loader/native/pixel leases remain held until the actual entered work returns. Checks cannot undo entered effects and do not implement a linearizable source/FS/permission transaction. Earlier UI/source/account transition scheduling remains the caller contract.

Validation
----------

50/50 distinct methods passed on their FIRST functional execution: 36 XCTest methods in seven suites (0.519s execution), 14 Swift Testing methods in two suites (0.138s). Exact discovered inventory is in `remote-source-ownership-methods.json`.

Six new source-ownership methods exercise pre-canceled entry preserving success and failure, cancellation inside entry authorization, old epochs/foreign scopes/denied same-epoch calls, original-access revocation with a fresh allowed access, explicit same-asset reload and visibility reopen, denied empty entry with zero transport, and held old response completion after replacement. All held continuations are released and their tasks joined. Existing source/result revocation, two-slot/lease retention, fallback, raster limits and observer-cap tests pass. The changed existing failure test now expects a stale denied/canceled invocation to preserve the owned failed state, then verifies scope invalidation clears it.

Mapping: new source tests cover model/projection entry and terminal ownership; all eight `RemoteImageAuthorityTests` cover #597's managed native generations and physical collection; eight selected remote XCTest methods cover direct loader/model compatibility. Six context and six artifact methods cover related access/fallback contracts using custom decoders and injected write sinks; three generated-image DTO/URL methods, two pure raster/text protocol methods, eight injected-worker methods and three independent-budget/controlled-refusal module methods cover shared dependencies.

Only private bytes, raw small CGImage/NSImage memory, fake transport and injected runners/decoders are used. No actual HTTP/provider/download/paid request, codec/helper process, image encoding, windows/apps, pasteboard, capture/TCC/audio, real model, permission probe, network mount, home data or full suite. Existing selected raster-limit fixtures allocate synthetic memory only. Real helper/encoding, URLSession redirect, window and production account fixtures were explicitly excluded rather than opt-in skipped. Related source test bodies and access callers were inspected.

Changed executable coverage: **20/21 (95.24%)**, versus the baseline, from the same focused pass. Only line 218 (the view's `displayed` forwarding call) is unhit because no UI window is run; `displayed` itself is directly exercised. This is line coverage, not all branches/races/errno/devices or global DI/runtime proof.

Build and evidence history
--------------------------

Direct native coverage build with tests and jobs=4 through `scripts/test_runtime.child_environment`: initial 120.56s failed because the new fixture omitted `TypefluxMediaProtocol`; no functional tests ran. Added the test import, completed self-review, then final build 39.50s passed with no changed-file warnings (unrelated warnings and native-build deprecation remain). Production code was not changed for the build failure. Inventory via native environment/tools/testing helper took 5.732s; direct native skip-build/no-parallel explicit-filter test command took 30.84s; archive 19.315s. Core tracked time 196.632s; including archive 215.947s, excluding extraction/audit/platform delivery. No functional retry, timeout relaxation or Source/test edits after the final build.

Each build/inventory/test/archive completed and was collected before its dependent step. The archive was still running on initial return and was collected before extraction. A post-export statistics script mistakenly looked for a nonexistent JSON `hash` field and failed after export had succeeded; corrected the statistics read to `llvm-profdata show --all-functions`. This did not rerun tests or change profiles, binaries or inputs. Show/export stderr was empty; coverage extraction succeeded.

Only THREE fresh HOST profiles, one matching binary: XCTest discovery/execution and Swift Testing execution. Each raw was individually validated; sparse merge was warning-free. Matching archived test binary plus app `--object` used for show/export; both binaries contain `__llvm_covmap` and `__llvm_prf_cnts`. All 1138 Source + 832 test Swift inputs match the FINAL PREBUILD snapshot, archive and live files after extraction. Archived/live binary and original/copied raw hashes match. All 1209 reported function hashes are zero, which does NOT establish layout compatibility. Prior live/root-default profiles are excluded. No cross-layout/old/child coverage claim.

Private evidence: `.build/remote-source-ownership-validation/final`.

- Test SHA256: `da97b930d40773d3ef48d1d2f079a09526df43d051b8b409017b2d88bf39bbf8`.
- App SHA256: `d8bb8e3b74be219b0e796ca79ebd76f632982190869c636e1e7d12a6b2864495`.

Remaining work
--------------

This fixes the demonstrated remote model slice only. Context/artifact default native decoding and other legacy consumers still need their original accepted batch audit; custom decoders retain their own contracts. Concurrent settings writers versus bind, direct defaults, separate same-suite defaults, external account/preferences/OS FDA ordering remain outside earlier synchronous settings receipts. Broader native/feature/audio/TCC/signing/performance work remains; no real CoreML, full Xcode/signing/notarization/macOS13 Intel/actual recording quit proof. Host FS/JSON/SQLite/raw memory/UI/AppKit/GPU/system memory remain boundaries; no arbitrary host/native crash, OOM or power-loss guarantee.
