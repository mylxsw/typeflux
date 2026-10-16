# Favicon pending native authority

The default favicon cache now captures existing preview-worker authorization when accepting a new pending request, before its internal Task, loader or native preparation. All shared waiters retain that pending request's original stamp. The same stamp passes to the small-icon decoder and is rechecked before cache publication, including after the terminal access callback. A held old loader cannot adopt a recovered native generation or publish a newly authorized image.

Default native unavailability yields the existing unavailable result and 60-second negative cache without entering the loader. Readiness never clears failures or replays requests. An explicit request after normal expiry can capture current availability. Already completed valid pixels remain cached through later health changes.

The custom decoder override is optional, defaults to nil and remains independent of native health. Existing initializer labels and trailing decoder closures compile unchanged; the concrete worker defaults to the same previews domain. No new grant, pool, dispatcher, full DI, per-view handle, helper ABI or packaging change was added. Two download slots, independent native capacity and actual child/host/FD/private-copy collection remain intact. A canceled uncooperative loader or native call retains occupancy until actual return. Existing 16-client sharing, 128-image/256-failure bounds, source checks and fallback remain.

## Scope and review

Baseline: `162e72bda661f5df4c5c68cc34a35504e1b51011`, read immediately after branch creation. Reviewed cache pending/bind/getter/release behavior, view and row callers, direct small-icon decoding, all browser/favicon test bodies, selected small-icon fixtures and their dependencies before validation. Implementation and self-review preceded functional testing. No Source/test inputs changed after the build.

This boundary starts at a newly accepted cache request. Earlier view scheduling and native application-icon fallback remain their owners' contracts. Custom context/raw-pixel decoders are not forced onto the native lane. OS QuickLook and application-icon fallback were neither changed nor executed. Cache source/access callback ownership remains separate work: denied same-epoch entry and reentrant access checks are not solved by the native stamp. This is not an atomic filesystem/settings/account permission transaction, rollback of entered transport effects or all-UI-epoch guarantee. Native availability does not grant source/account permission.

The production loader still builds an origin-only, no-credential GET with its existing three-second/256-KiB bounds. No automatic redownload, probe, decoding replay, producer/workflow/tool/command/paid-generation request, copy/export/write retry or deletion was added. Earlier indexing and other feature increments compile in this binary but are not independently functionally validated here.

## Focused validation

**22/22 distinct methods passed on the first functional run:** seven XCTest methods in one suite (0.084 s execution), plus 15 Swift Testing methods in three suites (0.215 s). Exact names, including literal-backtick Swift methods, and exclusions are in `favicon-batch-authority-methods.json`.

Seven new methods exercise the actual cache default native branch with an injected managed worker: pre-ready refusal retains negative-cache expiry and does not replay on readiness; held shared loading across recovery keeps the original stamp for all clients, including a later joiner; canceled uncooperative loaders and native calls retain capacity until collection; a successful native result followed by terminal access-callback revocation cannot be published; old scope loading cannot overwrite a fresh default result; custom actor decoding remains independent on an unready worker and input/cancellation refusals preserve bounds. The terminal fixture asserts a validated response, zero active native calls and current permission before revoking its own admission. All held gates were released and tasks joined. This is not exhaustive executor scheduling proof.

Selected existing tests cover direct small-icon original authority and bounded preparation, sharing/client cancellation, source/scope revocation, cache/pixel capacity and fake transport request bounds. Unsafe tests that encode images or execute a real helper were excluded, even when part of their method uses an injected runner. Fixtures use private bytes, raw small CGImages, synthetic JSON/RGBA, private health stores and injected transport/loader/decoder objects. No actual HTTP/URLSession, codec/helper/encoder, provider/paid call, pasteboard (including named), System clipboard actions, home/Downloads, production conversation-model/app/file-index object, window, capture/audio/TCC or full suite ran. No presentation/ABI/entry/package change required a screenshot or copied-helper probe.

**Changed executable coverage: 16/16 (100%)** in `AskBrowserFaviconCache.swift` against the baseline. The 90% goal is met; this does not prove every branch, race, errno, device or production DI boundary.

| Foreground stage | Wall seconds |
| --- | ---: |
| Native coverage build, jobs 4 | 121.650 |
| Prebuilt native inventory | 8.266 |
| Explicit no-parallel skip-build coverage test | 30.370 |
| Evidence archive | 5.396 |
| Build + inventory + test | 160.286 |
| Including archive | 165.682 |

Extraction, source review and platform delivery time are additional, not separately timed. Build passed with no changed-file warnings; unrelated warnings and SwiftPM native-build deprecation remain. No build/functional retry, fixture correction or timeout relaxation occurred. Every build/inventory/test/archive/extraction job completed and was collected before its dependent step.

## Evidence integrity

Only three fresh matching HOST profiles from one binary were used: XCTest discovery, XCTest execution and Swift Testing execution. Each raw was individually validated; sparse merge, matching-app-object show/export and all-functions inspection had empty stderr. Both binaries contain LLVM coverage sections. **1,145 Source + 847 test = 1,992 Swift inputs** match the PREBUILD snapshot, live tree and archive after extraction. Live/archived binaries and original/copied raw hashes match. Prior live/root default profiles were excluded. There is no old/cross-layout or child coverage claim. All 771 reported function hashes are zero; zero Swift hashes do not prove layout compatibility.

Private evidence: `.build/favicon-batch-authority-validation/final`.

- Test binary SHA256: `7b0f9eca08e5ee299899fff5478a9a40c90810ee0b8d9aaf1796cb9a8f36fb48`
- App binary SHA256: `0b23c49c7e705e74c01f9e1125bf3593a58a9b5ce787299a3f7ef2f26493ae5a`

GUL-399 remains in progress: cache source/callback ownership, artifact denied-entry/source projection, outer clipboard image-copy/custom native OCR, earlier UI/native-fallback boundaries and external condition ordering remain. Real model/device/performance/signing/full-Xcode/macOS-13-Intel/actual quit-recording checks remain unverified. Host filesystem, JSON, SQLite, raw memory, UI/AppKit, GPU and system-memory boundaries provide no arbitrary crash/OOM/power-loss guarantee.
