# GUL-399: optional encoded icons

This increment continues from the actual #531 merge commit `594c6275` on `agent/arch-gpt-astra/gul-399-context-images`. At the start of this run #531 and #530 were merged into their respective stacked bases, but `origin/main` did not contain #531's `90ac223c` implementation. Several intermediate PRs were closed without merge commits. The new branch therefore uses the concrete #531 landing point and preserves its dependencies; it does not duplicate the previous increments or claim they have all landed on main.

## Changes

- Custom plugin `.image(URL)` icons now use explicit async preparation, the existing independent media helper and validated raw RGBA. The synchronous icon getter returns no encoded image and performs no IPC. Finder/file-type icon branches remain separate native paths. The residual Finder/type NSCache has a count limit; it is not treated as a strict native-memory bound.
- `AskSmallIconDecoder` admits two operations before detached file reads/decoding. File input is limited to 4 MiB; favicon data to 262,144 bytes. Nonregular files and oversized reads fail before helper dispatch. The existing preview domain supplies two child slots, a three-second deadline and private copies retained until actual child retirement. There is no queued replacement after cancellation.
- The existing raster protocol requests at most 56×56 pixels and validates dimensions against that request before host bitmap construction. `AskContextImageModel` now accepts a bounded pixel edge (default 1600 unchanged), so an icon reserves 12,544 bytes rather than a large-image allocation. Reservations precede decoding and survive uncooperative cancellation until actual completion; displayed pixels retain their reservation.
- File icons are owned by their views, without an application-lifetime path cache. New plugin result generations force a fresh read even when a workflow overwrites the same path. Editor result identities use an explicit local scope. Account/selection/window scope invalidation clears display and rejects late results. Failed optional icons keep their existing fallback symbol and do not replay the producer.
- Favicon network work retains the existing HTTP/HTTPS origin-only URL contract: `/favicon.ico`, no tab path/query/fragment/credentials, no cookies or credentials storage, no redirects, 262,144-byte response and three-second resource deadline. Inputs additionally have a 16 KiB URL bound. The direct load entrypoint also refuses unnormalized URLs. Tests use injected transports; no live website was contacted.
- The favicon cache admits at most two downloads globally and at most two pending records per instance, with at most 16 clients per shared request. Loading and decoding are both within that owned task. Cancelling the last client cancels it but does not remove the pending record or free admission until it really returns. One cancelled row cannot cancel another row's shared request.
- Successful cache entries are strictly limited to 128 raw 56-edge rasters (at most 1,605,632 pixel bytes); negative entries remain limited to 256 with the existing 60-second expiry. This is separate from the shared display budget and does not bound AppKit/GPU overhead. Cache reuse checks the original access authorization as well as the current scope/epoch. A fresh authorization cannot bless an old account's pixels.
- Search-settings changes remove the old favicon component, clear its cache and cancel work. The old row stays on its fallback rather than issuing another origin request. A recreated row/new plugin generation/window can prepare it again. Optional icons refused by admission stay on fallback until a new view/request identity; body recomputation does not create retry loops.

No new executable, protocol operation, packaging path, provider call, Agent action or workflow execution is introduced. Original workflow files/results are unchanged. The helper protocol already supports small raster requests and ICO decoding; it is reused rather than duplicated.

## Validation

Implementation and ownership/privacy self-review preceded the focused tests. Direct builds use `scripts/test_runtime.child_environment()` and:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
```

Both the XCTest executable and media helper had `__llvm_covmap` and `__llvm_prf_cnts`. The focused pass used the prebuilt binaries without an intervening discovery rebuild:

```sh
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '<scope>'
```

The 34 distinct methods map to changed behavior as follows:

- `SmallIconIsolationTests`: 11 new methods. Real helper PNG/ICO decoding and mutable-file identity; malformed/truncated/oversized/FIFO inputs; retained decoder/download admission; bounded shared waiters and independent cancellation; strict cache capacity; stale authorization and late decoder rejection; small pixel reservations; actual custom-file/favicon pixels, settings revocation, result-generation refresh, editor scope and view cleanup.
- `AskBrowserFaviconTests`: seven existing methods migrated to the async raw-raster contract, including URL privacy, deduplication, negative-cache expiry, cancellation, HTTP bounds and native view sizing.
- `AskContextImageTests`: 11 methods for the directly changed shared model, default large-image behavior, admission, pixel lifetime, permission/generation checks and real helper/view compatibility.
- `MediaPreviewTests`: four methods for raster request validation, orientation/framing, harmless crash/hang children and actual-retirement ownership.
- `AskPluginListViewTests`: the existing backtick-named `icons come from symbols files and types` method, now using async file-icon preparation while keeping Finder/type fallback assertions.

Initial pass: all 33 actually selected methods passed (26 XCTest + seven Swift Testing). The intended workflow icon method was initially filtered using its filename's suite name rather than its real `AskPluginListViewTests` suite; it was then run alone without rebuilding. There were no functional failures. The supplementary method passed (0.316 seconds in Swift Testing; command wall time 31.00 seconds). All 34 distinct methods passed, with no source changes, rebuild or retry of an executed failure between these two commands.

The `small-icons.png` screenshot was visually inspected. It captures actual helper-prepared pixels in a synthetic hosting window, with injected favicon bytes. The UI test also changes the file at the same path under a new result generation, withdraws favicon display on a settings notification and verifies all private pixels clear on scope invalidation. It is not a full interactive launcher/browser permission exercise.


The exact corrected filter is:

```text
^Typeflux(?:Focused)?Tests[./](?:(?:SmallIconIsolationTests|AskBrowserFaviconTests|AskContextImageTests)[./]|AskPluginListViewTests[./]`icons come from symbols files and types`|MediaPreviewTests[./](?:testRasterDimensionsStrideAndPageIdentityAreValidatedBeforeAllocation|testImageOrientationAndRequestFrameLimits|testPreviewCrashAndHangReturnWithoutReplaying|testRetainedPreviewFilesAndSlotsWaitForActualReaping))
```

The first pass used the same expression with `AskWorkflowItemsTests` in place of `AskPluginListViewTests`. The supplement selected only `AskPluginListViewTests[./]` followed by the literal backtick-named method above. Both used the prebuilt command shown above and the sanitized child environment. No test-discovery rebuild intervened.

| Check | Wall time | Result |
| --- | ---: | --- |
| Four preparation builds | 227.77 / 62.79 / 69.50 / 47.51 s | All passed |
| Initial focused pass | 19.16 s | 33 distinct methods passed |
| Omitted-method supplement | 31.00 s | 1 passed |
| `python3 -m unittest scripts.tests.test_media_packaging` | 0.153 s | 2 passed |
| Copied app-bundle helper synthetic PNG probe | 0.225 s | 56-edge request and raw raster validation passed |

Tracked total: **458.11 seconds**, excluding coverage extraction, review and screenshot inspection. There were no compiler or functional test failures, no full-suite run, no real website request, workflow side effect, screen/microphone capture, TCC or signed-release exercise.

Changed executable-line coverage is **159/162 = 98.15%**. `small-icons-coverage.json` records per-file attribution. The three uncovered lines are the composer generation environment bridge, the plugin website-icon construction bridge and the workflow-editor parent scope bridge. The corresponding isolated components, epoch invalidation and editor scope are exercised. Full line hits in the decoder/cache do not prove every branch, native allocation or filesystem fault.

All **17 raw profiles** belong to one final binary: five host profiles (three initial, two supplement), eleven direct helper profiles and one copied-bundle helper profile. Every profile was individually validated before a warning-free merge. Initial profiles were saved before the supplement overwrote its test-start marker; only profiles created by this run were collected. There was no mixed counter layout, no discarded failing profile and no reuse of earlier increments' coverage. The unchanged media helper was supplied to `llvm-cov` as `--object`.

Matching validation binaries and profiles were saved under `.build/icon-validation/final`. SHA-256:

- XCTest: `c284c654daa883f6eeb411768384dac6e279d347cfc7beea2437313393d56d5f`
- Media helper: `81cc8f44462c1448f50b8af738ff26bf77dd1085b31e9f6742b2b81b5596785c`

The media helper retains Mach-O minimum macOS 13.0. The existing test toolchain emits a macOS 14.0 XCTest executable; this run does not validate macOS 13 hardware. No package or release-target source changed.

## Remaining boundaries

`AskFinderIcon` still calls `NSWorkspace.icon(forFile:)`, rasterizes/encodes PNG and calls `NSImage(data:)` in the host. File-type icons, launcher application icons and context-chip application icons also retain NSWorkspace/AppKit boundaries. They are not silently routed into the encoded-file contract. Existing file-index/semantic workers remain unchanged.

Media icons still share the existing preview-domain failure budget rather than a persisted registry/settings health entry. Further stage-2 adapters and condition-driven lifecycle/health integration remain required. Other remaining media/native boundaries and audio/TCC/signing/performance verification before deciding microphone capture isolation are unfinished. Real CoreML performance, a full Xcode application build, Developer ID/notarization, Intel/macOS 13 hardware and real quit/recording behavior remain unverified.

Host filesystem/URL/JSON/base64/raw bitmap construction/UI/pasteboard/SQLite/import-export remain in process. The limits above do not provide arbitrary native-crash, AppKit/GPU memory, system-wide OOM, filesystem-stall or power-loss guarantees. The overall issue remains in progress.
