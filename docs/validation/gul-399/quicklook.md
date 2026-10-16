# GUL-399: isolated launcher and side-preview Quick Look thumbnails

Launcher file-row thumbnails and the side preview's document/SVG fallback now request Quick Look inside the existing disposable media helper. The host displays validated RGBA only. The explicit user-requested system Quick Look panel remains an OS/UI action, separate from background thumbnail extraction.

This increment depends on #535 (`agent/arch-gpt-astra/gul-399-context-native-icons`, `967c5718`). #535 was still open against main at validation. The earlier consolidated #534 is already on main; this increment does not recreate or alter that integration.

## Contract and ownership

- `MediaQuickLook` carries an absolute, non-NUL path of at most 4 KiB and an allowlisted representation choice: `.all` for list thumbnails, `.thumbnail` for side content. No arbitrary URL/network operation is accepted. Native providers receive the original file context, not a copied encoded image or an arbitrarily copied bundle.
- The child resolves the root link, rejects missing/special/nonresident files and non-local mounts, and bounds input to 512 MiB. Directory inputs are restricted to Pages/Numbers/Keynote/RTFD/Sketch package extensions, at most 4,096 entries including the root, with the same aggregate byte cap. Nested links and enumeration failures are refused. Metadata snapshots before and after native work reject changed originals. This is a conservative snapshot check, not an immutable filesystem transaction.
- QLThumbnailGenerator request creation, cancellation, representation decoding and rasterization run in the helper. List requests preserve 56-point sizing multiplied by a finite 1–4 screen scale; side requests retain their explicit pixel sizes. Returned provider images are bounded to 100 MP before raster conversion, then fit to requested pixels without upscaling. The existing protocol limits apply: 4,096 axes/4,194,304 output pixels, one raster at most 16 MiB, 32 KiB request and 16 KiB response. UUID/version/operation/dimensions/stride/byte count/page identity and fixed output files are validated before host bitmap construction.
- Two admissions occur before detached work, with pixel reservations before dispatch. The existing preview pool has two children and a three-second deadline, confirmed-reaping leases and no replay. Private outputs remain owned through child retirement and host extraction. The source is observed, never deleted or rewritten. No new helper target or packaging path is added.
- Visible rows own their projections and original authorization. Revision, scope epoch and result generation replace the view identity; cancellation and revocation clear pixels. Native file-icon fallback remains isolated. Production `AskResultImageCache` no longer starts native/thumbnail prefetch or loading; its old machinery remains only for explicitly injected test loaders. There is no production path-only thumbnail cache.
- Side-preview retirement now calls the loader's explicit `clearCache`: selection/visibility/authorization transitions cannot carry old private cache entries forward. Existing 32-entry/64 MiB loader limits and late-result cancellation remain. A real loader test proves revocation clears cached content and a fresh authorized request regenerates it.

No script, Agent action, write, paid generation, or other producing operation is rerun to recover a thumbnail. Original file references and existing metadata/file-worker contracts remain intact.

## Focused validation

Implementation and self-review preceded tests. The self-review added explicit preview-cache retirement and rejected remote/nonresident Quick Look inputs. Three direct instrumented preparation builds passed; there were no compiler failures, functional failures, test retries or timeout changes.

Commands used the sanitized environment from `scripts/test_runtime.child_environment()`:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '<explicit scope below>'
python3 -m unittest scripts.tests.test_media_packaging
python3 ../gul-399-quicklook-probe.py
```

The explicit regex in task-local `gul-399-quicklook-test.py` selected **34 distinct methods**: 20 XCTest and 14 Swift Testing. Every selected method executed and passed:

- All 12 `QuickLookIsolationTests`: malformed/mixed protocol, bounded raster fitting, source mutation, native failure/cancellation, oversized sparse input/FIFO/package count/nested links, original root-link/package context, invalid pixels before dispatch, admission retained through uncooperative cancellation, harmless crash/hang children, real-helper/list and document renderer, disabled production prefetch, real side-cache revocation, and visible row revision/revocation.
- Four `MediaPreviewTests`: `testRejectsUnboundedOptionsAndMixedProtocols`, `testRasterDimensionsStrideAndPageIdentityAreValidatedBeforeAllocation`, `testHostRejectsMissingTruncatedSymlinkDirectoryAndOversizedRasterFiles`, `testRetainedPreviewFilesAndSlotsWaitForActualReaping`.
- Four `AskContextImageTests`: `testPixelLeasePrecedesWorkAndSurvivesUncooperativeCancellation`, `testOldResultAndOldDeniedAccessCannotOverwriteNewSelection`, `testAuthorizationIsRecheckedAfterAwaitAndOnEveryProjection`, `testFailureDoesNotRetryFromGettersAndInvalidRastersFailClosed`.
- All four `AskFilePreviewControllerTests` preserve selection/debounce/grace/dismiss behavior.
- Nine injected `AskResultImageCacheTests`: prefetch survives cancellation, resolved-link coalescing, link retargeting, non-application original URLs, cancelled application loads, revision cache invalidation, shared-consumer cancellation, pre-cancelled refusal, missing-image retry. The two unrelated native-icon facade tests were excluded.
- `AskQuickSearchSessionTests.searchBatchesPrefetchIconsBeforeRowsAreCreated` preserves injected search-assembly compatibility.

The copied-helper probe installed the actual executable into `Fixture.app/Contents/Helpers`, sent a private synthetic PNG Quick Look request, and checked response identity, bounded raster geometry and exact raw file length. It passed. Both packaging tests passed. The actual `AskFileIconView` screenshot below was inspected; the fixture also changed the file revision, revoked its scope, verified cleared pixels, and refused reuse of expired authorization.

![Scoped Quick Look row with injected pixels](quicklook.png)

| Command | Wall time | Outcome |
| --- | ---: | --- |
| Preparation build 1 | 381.16 s | passed |
| Preparation build 2 | 179.17 s | passed |
| Final lifecycle build | 56.58 s | passed |
| Focused test command | 13.00 s | 34 methods passed |
| Packaging tests | 0.137 s | 2 passed |
| Copied-helper Quick Look probe | 0.142 s | passed |

Tracked build/test/probe time: **630.189 seconds**, excluding audit, coverage extraction and inspection. No full suite, live website/provider, workflow effect, screen/microphone capture, TCC, signed release or hardware matrix was exercised. The real helper used only private synthetic PNG input; the package and native-failure tests use injected providers. Real SVG/Office/third-party Quick Look providers were not validated.

## Coverage evidence

Both final XCTest and helper binaries contain `__llvm_covmap` and `__llvm_prf_cnts`; no discovery rebuild occurred between build and tests. Five fresh profiles (three host, one directly invoked helper, one copied-helper probe) came from this one final build. Every profile individually passed `llvm-profdata show`; the merge completed without warnings. No old profiles or counter layouts were mixed. The helper was included as `llvm-cov --object`, and new source files were included in the changed-line diff.

`quicklook-coverage.json`: **135/139 changed executable lines, 97.12%**. The four uncovered lines are the default view decoder/scale bridges and two defensive decoder routing rejections. The native decoder's 64/64 line hits are not proof of every branch, allocation failure, remote mount, cloud-provider behavior or watchdog expiration.

Matching binaries/profiles are retained task-locally in `.build/quicklook-validation/initial` (the first and only test pass, after all production edits):

- XCTest SHA-256: `136f9a7e0afa2bb7335829bb675fbba434f849b3bc46ba65e6778900acefc70c`
- Helper SHA-256: `143d91dc0fb4254234f5424cb7790fdf8b30e75c6c7f486351890a6315f4821e`

The host has zero media-runtime module symbols; the helper has 402. Both app and helper Mach-O deployment targets remain macOS 13. This is a binary configuration check, not macOS 13 hardware validation.

## Remaining boundaries

Quick Look may involve OS-managed provider services. Owning and killing this helper does not give ownership of those services or bound all provider/AppKit/GPU/system allocations. Original-file metadata can race external writers; no immutable filesystem or power-loss guarantee is claimed. The parent still constructs images from validated raw pixels. Host filesystem/JSON/SQLite/import-export and UI boundaries remain.

The next media work includes residual browser application discovery (`AskBrowserSearchPlugin`, `AskQuickResultsView`) and the separately audited `ClipboardThumbnailProvider`: that history-panel provider still uses in-process ImageIO/Quick Look and legacy cache/task ownership. Earlier clipboard capture isolation does not cover this presentation path. Explicit system Quick Look panel behavior is also a separate boundary.

Further approved stage-2 adapters/condition-driven lifecycle/persisted health integration remain; the registry covers three stores while native/media/inference remain independent domains. Audio/TCC/signing/performance verification must precede any microphone capture-isolation decision. Real CoreML/performance, full Xcode/release signing/notarization, macOS 13/Intel hardware and actual quit/recording integration remain unverified. The overall issue stays in progress.
