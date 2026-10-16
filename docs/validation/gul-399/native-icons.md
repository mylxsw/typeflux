# GUL-399: native launcher icons

This increment is stacked on #532, branch `agent/arch-gpt-astra/gul-399-small-icons`, commit `d4e308c0`. At the start of this run #532 was open and its actual base remained `agent/arch-gpt-astra/gul-399-context-images`. Prior stack merges have not all propagated to main; no earlier PR base was changed.

## Changed boundary

Finder file icons, plugin file-type icons and launcher application rows now use the existing independent media helper. The child performs NSWorkspace lookup and lazy NSImage rasterization; the host validates and constructs a fixed RGBA bitmap without PNG encoding or original-image decoding. No new executable or packaging path is added.

The versioned request has a native-icon operation and a mutually exclusive file/type target. File paths must be absolute, nonempty, NUL-free and at most 4096 UTF-8 bytes; type identifiers are bounded to 256 bytes and a restricted identifier character set. Native-icon preview options reject page, passage, timestamp, container and image-type fields. Requests use the existing 32 KiB preview envelope, responses the 16 KiB metadata limit. One raw raster is bounded to 112 pixels per axis; production views request 56 pixels (12,544 bytes). UUID/version, dimensions, stride, exact length, fixed filename and no-follow file checks precede host allocation.

Native lookup intentionally sees the original file path: Finder custom icons and bundle metadata cannot be reproduced by treating the file as ordinary encoded media. It does not open or execute the application. The path is sent on private stdin, never logged or put in command arguments. External changes during lookup can change the resulting icon; no immutable filesystem snapshot or file-content validation is claimed. Missing files retain Finder's generic icon behavior. Unsupported types fail locally.

Two admissions are acquired before detached host work, with no queue. They remain occupied through uncooperative cancellation. The existing preview pool independently enforces two child slots, a three-second deadline, rolling failure budget and confirmed-reaping leases. Private output files remain owned through both child retirement and host extraction. Crashes/timeouts do not rerun workflows, Agent actions or lookup automatically.

Views use the existing scoped raw-pixel model and reserve their pixel budget before dispatch. Source, scope epoch, plugin generation and file revision form view identity. Replacing a result, revoking access or hiding its owning scope rejects late results and clears pixels. There is no application-lifetime native-icon/path cache. Old production cache prefetch/image entrypoints refuse native icons, so search assembly cannot leave unbounded native prefetch clients behind. Injected legacy loaders retain their test contract. Optional icons refused by admission keep a generic fallback until a new view/request identity; no implicit retry loop is introduced.

## Validation

Implementation and ownership/privacy self-review preceded tests. Direct builds used `scripts/test_runtime.child_environment()` and:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
```

Both the test executable and helper were verified to contain `__llvm_covmap` and `__llvm_prf_cnts`. No discovery rebuild was inserted before:

```sh
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '<explicit scope below>'
```

Initial scope:

```text
^Typeflux(?:Focused)?Tests[./](?:(?:NativeIconIsolationTests|AskResultImageCacheTests|SmallIconIsolationTests)[./]|AskPluginListViewTests[./]`icons come from symbols files and types`|AskQuickSearchSessionTests[./]searchBatchesPrefetchIconsBeforeRowsAreCreated|AskContextImageTests[./](?:testPixelLeasePrecedesWorkAndSurvivesUncooperativeCancellation|testOldResultAndOldDeniedAccessCannotOverwriteNewSelection|testAuthorizationIsRecheckedAfterAwaitAndOnEveryProjection|testFailureDoesNotRetryFromGettersAndInvalidRastersFailClosed|testProductionAccessFencesLocalAccountSelectionVisibilityAndLoginChanges)|MediaPreviewTests[./](?:testRejectsUnboundedOptionsAndMixedProtocols|testRasterDimensionsStrideAndPageIdentityAreValidatedBeforeAllocation|testHostRejectsMissingTruncatedSymlinkDirectoryAndOversizedRasterFiles|testRetainedPreviewFilesAndSlotsWaitForActualReaping))
```

The **42 distinct methods** comprise 29 XCTest and 13 Swift Testing methods; the display-scale method has two argument cases:

- Nine new `NativeIconIsolationTests`: request/response bounds and operation separation; injected native lookup failures and small rasterization; real helper file/folder/type/missing-file output; retained admission through uncooperative cancellation; harmless child crash/hang; production cache refusal; actual scoped view rendering/generation/revocation and denied result/application callers.
- Eleven `AskResultImageCacheTests`: changed default-cache behavior and native facade sizes, plus directly affected injected-loader cancellation/deduplication/alias compatibility.
- Eleven `SmallIconIsolationTests`: compatibility of the shared preview worker and scoped icon presentation with the preceding increment.
- Five `AskContextImageTests`: shared pixel reservation, stale selection, original authorization, failure-without-retry and production account/window lifetime.
- Four `MediaPreviewTests`: shared request/raster validation, malformed output files and confirmed-reaping leases.
- One `AskPluginListViewTests` backtick-named icon method and one `AskQuickSearchSessionTests` injected-prefetch method: changed synchronous projections and search compatibility.

First pass: all 29 XCTest methods passed; two Swift Testing methods failed with three assertions because the compatibility facade's `NSImage(cgImage:size:)` produced a 28-pixel representation for a 56-pixel source. The helper's dimensions were correct. The fix constructs an explicit raw `NSBitmapImageRep`, preserves its pixel dimensions and assigns only the display point size. The correction build first caught a local variable redeclaration, fixed before retry. The original build's new actor-conversion warning was also fixed before any tests.

The correction scope contains the nine new native-icon methods plus the two failed facade methods. **11/11 methods passed**, including both scale cases, with this filter:

```text
^Typeflux(?:Focused)?Tests[./](?:NativeIconIsolationTests[./]|AskResultImageCacheTests[./](?:finderIconsRasterizeOnlyTheDisplaySize|ordinaryFileIconsUseTheFinderImagePath))
```

| Command | Wall time | Result |
| --- | ---: | --- |
| Preparation build | 187.29 s | Passed |
| Actor annotation/caller fixture build | 42.55 s | Passed |
| Initial focused test | 37.31 s | 40/42 methods passed; two dimension regressions |
| Correction build | 19.53 s | Failed: duplicate local variable name |
| Final correction build | 41.96 s | Passed |
| Focused correction test | 35.61 s | 11 methods passed |
| `python3 -m unittest scripts.tests.test_media_packaging` | 0.150 s | 2 passed |
| Copied app-bundle native-type helper probe | 0.168 s | 56×56 RGBA, UUID and length verified |

Tracked total **364.57 seconds**, excluding inspection/instrumentation/coverage extraction. No full suite, live network, application launch, workflow side effect, screen/microphone capture, TCC or signed release was exercised. The synthetic UI screenshot `native-icons.png` was inspected: it uses an injected raster in the actual scoped component and tests generation refresh and pixel clearing. Real native API behavior is independently exercised in disposable helpers, not by that blue-square fixture.

Changed executable-line coverage: **106/113 = 93.81%**, per-file attribution in `native-icons-coverage.json`. Seven lines remain uncovered: five legacy-thumbnail wrapper lines in `AskQuickActions`, a defensive native-refusal return in the legacy generator, and the generic decoder's wrong-operation rejection. Native adapter and core line hits do not prove every branch, allocation, Finder extension or watchdog expiry.

Coverage uses the final correction's **nine profiles** (three host, five direct helper, one copied helper) ONLY for `AskFinderIcon.swift`. All other changed production files were unchanged after the first pass and use its **15 profiles** (three host, twelve helper) and saved matching binaries. No profiles from different counter layouts were merged. Every raw profile was individually validated and both merges completed without warnings. An initial extraction command ran before its profile-copy/merge process had completed and failed; after that process was collected, extraction succeeded without dropping profiles. Matching artifacts are in `.build/native-icon-validation/initial` and `final`; no prior increment's profiles were reused. The helper was supplied to `llvm-cov` with `--object` so child-only source is counted.

Final SHA-256:

- XCTest: `7003f7807b6f3c6a054607ae1281e0bfa03419e45c3f6c467073c79f089be755`
- Media helper: `4f88abcf9f6db47b2de7c70b8d0303cd841bde4ee12130804959279eeeae2cfa`

The host has zero `TypefluxMediaRuntime` symbols; the helper has 301. Helper minimum deployment target remains macOS 13.0. The existing XCTest toolchain's macOS 14.0 minimum does not validate macOS 13 hardware. No release/Xcode packaging target changed.


## Remaining boundaries

This is a coherent launcher-result slice, not all NSWorkspace use. `AskContextChips.appIcon` still resolves bundle IDs and holds its own host icon cache, with consumers in attachment strips, source-context, launcher context-token and voice views. `AskFilePreviewView` still resolves and draws its header's file-type icon; its separate panel lifetime must be wired before migration. These are the next explicit native-icon surfaces.

Quick Look thumbnail generation, its legacy cache/prefetch ownership and system Quick Look panels remain separate existing paths. Ordinary thumbnail content is not secretly routed through the native-icon contract. Full app-icon fidelity on release-signed macOS 13/Intel hardware, custom resource-fork icons, Finder extension behavior and real AppKit quit/recording integration remain unverified.

Further stage-2 adapters and condition-driven/persisted health integration remain required; registry IDs still cover three stores while media/native/inference have independent domains. Audio/TCC/signing/performance verification is required before deciding microphone capture isolation. Real CoreML performance, full Xcode build and Developer ID/notarization remain unverified. Host filesystem/JSON/raw bitmap/UI/SQLite/import-export boundaries and AppKit/GPU/system memory are not fully contained. GUL-399 remains in progress.
