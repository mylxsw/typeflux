# Artifact image callback attempt ownership

`AskArtifactImageModel` now rechecks its original attempt after synchronous access validation, source loading, terminal validation and copy callbacks. A callback that calls `cancel()` cannot let the retired continuation enter the next source/native/copy step or publish an image. Task cancellation after an entered copy also prevents publication. Existing generation checks keep old errors and cleanup from changing a newer attempt.

Copy remains an explicit, once-only action using the original encoded bytes after account/conversation/grant/expiry, source and digest checks. A write callback may already have changed its sink before canceling; that effect is retained and never retried or rolled back. Native authorization, custom/actor decoder independence and actual native/FD/private-copy/child/host collection are unchanged. No helper ABI, packaging, pool, grant, dispatcher or global bypass was added.

## Scope and review

Baseline: `c056cfece5d6b55a1644aec51cc8840524809ed2`, read immediately after branch creation. Main advanced from the handoff's `2c29e67e` before the new branch was created, adding #610 PPTX indexing. This build includes that source layout; these focused tests do not independently validate PPTX or the earlier document-indexing increments.

Reviewed the model, stored card/preview/copy callers, production account/conversation access closures, local-tools validation and the store's reference/grant/expiry checks. Implementation and self-review preceded functional testing. No Source/test inputs changed after the build.

This is a callback-boundary prerequisite. Initial denied access still follows the existing error/state replacement behavior. Cards still consume raw model images without a stored reference/access projection contract; denied-entry and source-projection ordering remain work. This does not cover arbitrary Published/Combine/AppKit reentrancy, earlier UI consent, a linearizable filesystem/settings/account permission transaction or rollback of entered effects. Recovery never reruns producers, decoding, copies, exports, commands or paid requests.

## Focused validation

**29/29 distinct methods passed on the first functional run:** 16 XCTest methods in two suites (0.101 s execution) and 13 Swift Testing methods in two suites (0.161 s). Exact names and exclusions are in `artifact-attempt-ownership-methods.json`.

Six new methods include ten cases: retirement inside initial validation prevents reads/decode; retirement inside source load prevents decode and permits a fresh explicit copy; retirement after successful decoding prevents publication/copy; an entered write is retained once but cannot publish after model or Task cancellation; canceled callback errors cannot restore failure state; held old success/error cannot clear a newer busy operation or its later image. All held continuations were released and tasks joined.

Selected existing coverage checks artifact validation/digest/expiry/fallback, original encoded copy bytes, custom actor independence, original native generation, cancellation and physical two-slot/native retirement. Fixtures use private bytes and in-memory bundles, small raw CGImages, injected decoders/write sinks, fake native JSON/RGBA, private health stores and private FIFO/sparse files. No actual codec/helper, Vision, pasteboard (including named), System clipboard actions, Downloads/home, conversation-model production defaults, windows, network/provider/paid calls, capture/audio or full suite ran. No presentation/ABI/entry/package change required screenshots or a copied-helper probe.

**Changed executable coverage: 6/6 (100%)** against the actual baseline, in `AskArtifactImageModel.swift`. This meets the 90% goal; it does not establish every branch, interleaving, errno, device or production DI boundary.

| Foreground stage | Wall seconds |
| --- | ---: |
| Native coverage build, jobs 4 | 277.530 |
| Prebuilt native inventory | 5.163 |
| Explicit no-parallel skip-build coverage test | 36.880 |
| Evidence archive | 3.546 |
| Build + inventory + test | 319.573 |
| Including archive | 323.119 |

Extraction, source review and platform delivery time are additional, not separately timed. Build passed with no changed-file warnings; unrelated existing warnings and SwiftPM native-build deprecation remain. No build/functional retry, fixture correction or timeout relaxation occurred. Every build/inventory/test/archive/extraction job completed and was collected before its dependent step.

## Evidence integrity

Only three fresh matching HOST profiles from one test binary were used: XCTest discovery, XCTest execution and Swift Testing execution. Every raw was individually validated; sparse merge and matching-app-object show/export had empty stderr. Both binaries contain LLVM coverage sections. All **1,145 Source + 845 test = 1,990 Swift inputs** match the PREBUILD snapshot, live tree and archive after extraction. Live/archived binary and original/copied raw hashes match. Prior live and root default profiles were excluded. All 875 reported function hashes are zero; this is not layout-compatibility proof. No old/cross-layout or child coverage claim is made.

Private evidence: `.build/artifact-attempt-ownership-validation/final`.

- Test binary SHA256: `3ec386ac6949f9585ea92a91dc0e02b1bcd2cc880d47bf394680e065d0bb8f19`
- App binary SHA256: `ce9aa22ff0451b9de8ed174f52a3da6c30421041e27968e2528eae964f9ba3fd`

Broader GUL-399 remains in progress: artifact accepted-source/projection ordering, small-icon preparation, outer clipboard image-copy/custom native OCR and external condition ordering remain. Real models, performance, full Xcode/signing/notarization, macOS 13 Intel and device/actual quit-recording validation remain unverified. Host filesystem, JSON, SQLite, raw memory, UI/AppKit, GPU and system-memory boundaries carry no arbitrary crash/OOM/power-loss guarantee.
