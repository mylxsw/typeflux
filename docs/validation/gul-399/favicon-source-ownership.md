# Favicon source callback ownership

The favicon cache now rechecks Task cancellation, its generation and scope after synchronous access callbacks. A denied entry clears owned state only when that state's original access is revoked; a stale same-epoch or foreign denial cannot erase a newer authorized image or reset its failure cooldown. Entry, getter and terminal publication require the exact scope/epoch and sample original access last. A callback that cancels or invalidates the cache cannot authorize later pending admission, return stale pixels or restore a retired negative-cache entry.

The private cache-specific access predicate does not grant permission or start work. Explicit new scopes/reopen operations remain supported; nil access retains the unscoped contract and cannot display scoped images. Native pending authorization from #615, custom/actor decoder independence, two-slot physical collection, shared clients, origin URL policy and existing cache bounds are unchanged. No new native wrapper, pool, dispatcher, full DI, per-view handle, global bypass, helper ABI or packaging change was added.

## Scope and review

Baseline: `07a5bcf91f129f07cc606318ff829d356cb8ce99`, read immediately after branch creation. Reviewed cache bind/getter/pending/publication/release, access/scope implementation and view/callers, and compared the context/remote ownership contracts before choosing the repair. Implementation and self-review preceded focused functional validation.

Checks cover synchronous access-callback boundaries. They do not promise arbitrary Published/Combine/AppKit or custom-clock reentrancy, earlier UI/account transitions, an atomic filesystem/settings/account permission transaction or rollback of entered work. Earlier custom context/native application-icon fallback batches remain caller-owned. OS QuickLook and actual app icons were not changed or exercised.

The 60-second negative cache, completed valid pixels, 16-client sharing, 128-image/256-failure bounds and native/download budgets remain. Recovery never clears failure identity or replays input. There is no automatic download, probe, decoding, producer/workflow/tool/command/paid-generation request, clipboard/copy/export/write retry or deletion. Earlier indexing and other main features compile in this binary but are not independently functionally validated here.

## Focused validation

**28/28 distinct methods passed on the first functional run:** seven XCTest methods in one suite (0.077 s execution), plus 21 Swift Testing methods in three suites (0.162 s). Exact names/exclusions are in `favicon-source-ownership-methods.json`.

Seven new methods include eleven cases. They cover success and failure preservation after stale denial/precanceled entry; cancellation inside incoming access; original-authority callbacks during dedupe and denial; callback retirement after binding but before pending admission; original-access and exact-scope getter checks with zero preparation; owner/scope/Task retirement after completed image or nil result with no stale cache/cooldown; held old success/failure versus a fresh scope and explicit subsequent loading. Legitimate revoke/hide/reopen, failure expiry and byte-independent custom decoding remain supported. All held continuations were released and tasks joined. No executor freeze or exhaustive interleaving proof is claimed.

Existing selected methods exercise actual default favicon native authorization/collection, source/cache sharing and bounds, plus context source ownership. Native fixtures validate JSON, echo the requested image type and construct only small raw RGBA rasters. The existing terminal-native fixture asserts successful collection and current permission before revocation. No invalid-protocol refusal is used as evidence of successful native completion.

No actual image encoder/codec/helper, HTTP/URLSession, provider/paid call, pasteboard (including named), System clipboard action, home/Downloads, production conversation-model/app/file-index object, window, capture/audio/TCC or full suite ran. Unsafe methods that call image encoding later in their body were excluded despite injected runners elsewhere. No presentation/ABI/entry/package change required screenshots or copied-helper probes.

**Changed executable coverage: 26/26 (100%)** in `AskBrowserFaviconCache.swift` against the baseline. The 90% goal is met; this is not every branch, race, errno, device or production DI boundary.

| Foreground stage | Wall seconds |
| --- | ---: |
| Native coverage build, jobs 4 | 83.740 |
| Prebuilt native inventory | 6.460 |
| Explicit no-parallel skip-build coverage test | 34.930 |
| Evidence archive | 37.093 |
| Build + inventory + test | 125.130 |
| Including archive | 162.223 |

Extraction, source review and platform delivery are additional, not separately timed. Build passed with no changed-file warnings; unrelated warnings and SwiftPM native-build deprecation remain. No retry, fixture correction or timeout relaxation occurred. Source/test inputs were unchanged after the build. Archive remained running through several polls and was fully collected before extraction. Each build/inventory/test/archive/extraction job completed before its dependent stage.

## Evidence integrity

Only three fresh matching HOST profiles from one binary were used: XCTest discovery, XCTest execution and Swift Testing execution. Every raw was validated individually; sparse merge, matching-app-object show/export and all-functions inspection had empty stderr. Both binaries contain LLVM coverage sections. **1,145 Source + 848 test = 1,993 Swift inputs** match the PREBUILD snapshot, live tree and archive after extraction. Live/archived binaries and original/copied raw hashes match. Prior live/root default profiles were excluded; no old/cross-layout or child coverage claim is made. All 837 reported function hashes are zero; zero Swift hashes do not prove layout compatibility.

Private evidence: `.build/favicon-source-ownership-validation/final`.

- Test binary SHA256: `be72b9772fe841f04717ff81bfa6306224f4cd17c515db1069d168ec4cb56e6e`
- App binary SHA256: `af51dac360d6bd81d82951387c472ffa4c39725d9ad183c5924e27dd80cc3aaa`

GUL-399 remains in progress: outer clipboard image-copy/custom native OCR requests, artifact denied-entry/source projection, earlier UI/native-fallback boundaries and external condition ordering remain. Real model/device/performance/signing/full-Xcode/macOS-13-Intel/actual quit-recording checks remain unverified. Host filesystem, JSON, SQLite, raw memory, UI/AppKit, GPU and system-memory boundaries provide no arbitrary crash/OOM/power-loss guarantee.
