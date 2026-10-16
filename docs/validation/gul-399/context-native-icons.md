# GUL-399: context application badges and preview header icons

This increment targets main directly, based on `e4c18e0bbee8861142d967c192368ca59f1c262f`, the actual merge of #534. Before branching, the consolidated implementation commit `1f310837` was verified to be an ancestor of main and its tree identical to that landing point. All previously delivered increments are therefore retained; no old stacked PR needs to be merged again. Main was fetched and checked again before delivery.

## Changed boundary

Application badges in context chips, attachment strips, source details, launcher context tokens/panels and the voice panel now prepare icons asynchronously through the existing independent media helper. The primary cropped icon, lower-right application/provenance badge, existing dimensions, fallback symbols, restored indicator and consent controls remain. The synchronous `AskContextChips.appIcon` lookup and unbounded dictionary are removed. Excluding source context supplies no application identifier to these source views.

The file-preview header also uses helper pixels. Native bundle-ID discovery and file-extension-to-type resolution both happen inside the child, alongside NSWorkspace icon extraction and lazy NSImage rasterization. There is no host native-image fallback, blocking IPC in a getter, application launch or workflow/Agent replay.

The existing versioned native-icon protocol gains two allowlisted target kinds: application (at most 256 ASCII identifier bytes) and fileExtension (at most 64). Paths, URLs, NUL, unknown kinds and excessive values fail before dispatch. Unknown extensions retain the generic data icon; missing applications retain the UI fallback. Older helpers cannot decode the new enum cases and fail closed. The existing file/type targets, 32 KiB request, 16 KiB response, UUID/operation validation and exact raw-raster/file checks are unchanged.

Production views request one 56×56 RGBA raster (12,544 bytes). Two admissions are acquired before detached work, with no queue, using the existing two-child/three-second preview pool and confirmed-retirement file leases. Shared bitmap reservations precede dispatch and remain owned through uncooperative work and display. View identity includes target, original scope epoch, result generation and optional file revision. There is no new path/application bitmap cache or implicit retry from body recomputation. Busy/unavailable icons keep their fallback.

The separate preview controller now owns a bounded upstream scope registration and a local header-image scope. Selection changes, account/permission revocation, panel hiding, parent resign/close and controller release cancel work and clear pixels. Authorization is checked before delayed load, after completion and before display. An expired access value cannot bless old output. Actual `AskFloatingPanel.orderOut` emits a direct notification: AppKit occlusion notifications alone did not reliably arrive when hiding a non-key fixture window. Panel orderOut has its own hook. Existing content/debounce/grace behavior remains, with production requests explicitly supplying launcher authorization.

## Validation

Implementation and lifetime/privacy self-review preceded focused testing. All builds used the sanitized `scripts/test_runtime.child_environment()` and:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '<scope below>'
```

Both test/helper executables were verified to contain `__llvm_covmap` and `__llvm_prf_cnts`. No discovery rebuild was inserted. The scope contains **31 distinct methods** (22 XCTest, nine Swift Testing):

```text
^Typeflux(?:Focused)?Tests[./](?:(?:ContextNativeIconTests|NativeIconIsolationTests|AskFilePreviewControllerTests|AskFilePreviewIntegrationTests)[./]|AskContextImageTests[./](?:testPixelLeasePrecedesWorkAndSurvivesUncooperativeCancellation|testOldResultAndOldDeniedAccessCannotOverwriteNewSelection|testAuthorizationIsRecheckedAfterAwaitAndOnEveryProjection|testFailureDoesNotRetryFromGettersAndInvalidRastersFailClosed)|AskContextChipsTests[./](?:appIconTileIsOpticallySmallerThanTheChipWithoutInnerMargin|selectionProvenanceKeepsTheNameWhenTheAppIconIsUnavailable))
```

- Nine new tests cover identifier bounds, real helper application/extension/missing-app output, displayed-pixel invalidation, delayed authorization, scope exhaustion, actual panel/parent hiding and closing, controller release, all eight application-icon UI positions, and excluded-source refusal.
- Nine native-icon regression methods cover retained admission, harmless crash/hang children, malformed protocol/output, injected adapter failure, fallback and scoped view lifetime.
- Four shared context-image tests cover retained pixel leases, stale selection, original authorization and failure without retry.
- Seven preview controller/integration methods cover debounce/grace, selected evidence and real launcher selection/close wiring; two context-chip methods preserve optical sizing and unavailable-app provenance labels.

The first pass exposed a real lifecycle gap: parent orderOut invalidated authorization but did not promptly clear preview state through the occlusion notification. Two assertions failed; the fixture then indexed a callback that had not been created and trapped, interrupting XCTest. Four shared XCTest and nine Swift Testing methods passed; the remaining XCTest methods had not run. The direct owned-panel notification fixed the production gap, and the fixture no longer indexes that absent callback.

The full affected scope then completed: **30/31 passed**. Only the combined UI screenshot assertion failed. It correctly made eight decoder calls and cleared pixels on revocation, but its absolute RGB threshold rejected AppKit's color-managed fixture. A diagnostic-only retry saved the actual screenshot and confirmed eight visible icons; a second test-only retry using pure magenta still failed because conversion to device RGB produced a green component of approximately 0.397. The final fixture uses chroma differences, fixes light appearance and retains independent eight-call and post-revocation-zero-pixel assertions. Its isolated retry **passed**. No production change followed the successful lifecycle correction. All 31 methods have therefore passed across the correction and final UI retry; this was not a single all-green pass.

| Command | Wall time | Result |
| --- | ---: | --- |
| Three preparation builds | 272.86 / 54.84 / 27.59 s | Passed |
| Initial focused pass | 30.31 s | Lifecycle failure and fixture trap described above |
| Lifecycle correction build | 176.21 s | Passed |
| Corrected focused scope | 47.68 s | 30/31 methods passed |
| UI diagnostics build / retry | 49.99 / 57.86 s | Build passed; color threshold failed |
| Pure-color fixture build / retry | 39.32 / 28.30 s | Build passed; color threshold failed |
| Chroma fixture build / retry | 38.93 / 10.29 s | Build and one UI method passed |
| `python3 -m unittest scripts.tests.test_media_packaging` | 0.207 s | 2 passed |
| Copied app-bundle application-icon helper probe | 0.206 s | 56×56 RGBA, UUID and exact length verified |

The isolated UI filter was `^TypefluxTests[./]ContextNativeIconTests[./]testApplicationCallersRenderScopedPixelsAndClearOnRevocation`. Tracked build/test/packaging/probe time is **834.593 seconds**, excluding coverage extraction and visual/native-color inspection. No compilation failed. No full suite, live network, application launch, workflow side effect, screen/microphone capture, paid provider, TCC or signed release was exercised.

`context-native-icons.png` was visually inspected after the passing retry. It shows injected magenta rasters in actual UI components; it does not claim native app-icon fidelity. Native Finder application and text/unknown-extension behavior was separately exercised in disposable helpers, including the copied app-bundle executable.

Changed executable-line coverage is **146/156 = 93.59%**, recorded per file in `context-native-icons-coverage.json`. Ten uncovered lines are the unchanged count-badge rendering moved inside the asynchronous container. Core/lifecycle line hits do not prove every branch, allocation, system callback or arbitrary quit sequence.

Coverage uses only **13 profiles** with the saved lifecycle-correction production-final binaries: three host, nine direct helper, one copied-helper probe. The first interrupted pass and later test-only rebuild profiles are excluded. Every selected profile was individually validated; the merge completed without warnings. The helper binary was byte-identical after the fixture-only edits. No counter layouts or prior increment profiles were mixed. The helper was supplied as `llvm-cov --object`, so child-only source is counted. Matching local evidence is retained under `.build/context-native-validation/final`.

Matching coverage binary SHA-256:

- XCTest: `22c0937de7b1a63d77e572ba8b5db256eb844739f17b067c342a970d612bc21e`
- Media helper: `72fb4ff6eea3713a60061344920cc45399fad166f3e3edc1743746ed97861a69`

The host has zero media-runtime symbols and the helper has 303. The helper deployment target remains macOS 13; the existing XCTest toolchain's macOS 14 minimum is not macOS 13 hardware validation. No executable target or packaging path changed.

## Remaining boundaries

Two browser application-discovery calls still use host NSWorkspace: `AskBrowserSearchPlugin.swift` and `AskQuickResultsView.swift`. Their icons already use the isolated file-icon path, but discovery itself still needs migration. Quick Look thumbnails in `AskResultImageCache` retain their old pending/prefetch/cache ownership, and the document/SVG path in `AskFilePreviewRenderer` still invokes QLThumbnailGenerator in the host. These are the next coherent audit/isolation boundary; existing file-index/semantic workers must not be duplicated.

Original source metadata and file references remain unchanged. Preview content caches and native Quick Look panels are separate existing mechanisms; this increment does not claim to replace them. Application installation/icon changes can affect the child's snapshot; no immutable application filesystem snapshot is promised. Native custom icons, Finder extensions, signed macOS 13/Intel behavior and actual quit/recording integration remain unverified.

Further module adapters, condition-driven lifecycle and persisted health integration remain: the registry still covers three stores while native/media/inference use independent domains. Audio/TCC/signing/performance validation is required before deciding microphone capture isolation. Real CoreML/model performance, full Xcode build and Developer ID/notarization remain unverified. Host filesystem/JSON/base64/raw bitmap/pasteboard/SQLite/import-export/UI boundaries and AppKit/GPU/system memory remain. GUL-399 stays in progress; arbitrary host crashes, system-wide OOM and power-loss durability are not guaranteed.
