# GUL-399: source application icons

This increment is based on #538 (`70c5587f`), whose real base remains the clipboard-thumbnails branch. #535–#538 were still open at delivery. #534 already landed the older stability chain on main; this change does not reconstruct that chain or merge any PR.

## Behavior and ownership

- `ClipboardAppIconProvider` now produces validated descriptors only. The unbounded bundle-ID cache and synchronous Launch Services/native image calls are removed. Voice entries use the current app bundle path when bundled, so an unregistered development app still has an icon; unbundled execution uses the Typeflux application identifier.
- History leading icons and both clipboard settings lists use the existing `AskNativeIconImage`. Missing/invalid sources retain the kind/generic fallback. The existing history scope checks full entry membership, epoch and account/window lifetime; capture pause still permits viewing retained history.
- `AskPluginItem.Icon.application` defers browser application discovery to the media child. Both plugin search and direct search produce descriptors without `NSWorkspace` queries. Favicon URLs remain origin-only. Explicit file-icon fallbacks remain supported.
- Favicon and application fallback preparation share one owned image model: a failed favicon read can select the native fallback once, rather than mounting fallback tasks during each loading transition. Identity includes the fallback descriptor, so changing browsers at the same origin replaces the icon. Browser settings changes withdraw the old row's image work and show a generic symbol.
- Settings use `SettingsImageSession` and `SettingsImageWindow`. Native order-out, close and miniaturize retire the scope synchronously even when SwiftUI remains mounted. Account/token notifications retire it too. Reopening creates a new epoch; old access cannot authorize late pixels. Row disappearance owns cancellation on navigation/removal. The settings controller bridge supplies this scope without constructing new services for each row.

The existing helper application contract allows at most 256 ASCII bytes; native file targets allow 4 KiB. Existing native icon admission remains two operations before detached work, the preview pool remains two children/three seconds with confirmed retirement, and display reserves 56×56×4 bytes before work in the shared 64 MiB budget. Each scope permits 16 weak image observers. There is no new cache, queue, worker, executable or packaging contract. Refusal keeps a fallback; no producer, workflow, search, clipboard write or Agent action is replayed.

## Focused validation

Implementation and self-review preceded testing. Four direct instrumented builds passed. The first test pass executed **28 distinct methods** (24 XCTest + 4 Swift Testing). One new browser fallback method failed: it observed three native fallback reads for one initial row. Production was corrected to prepare favicon/fallback sequentially, then self-review added fallback identity and moved its snapshot to the main actor before the sendable decoder closure. A preparation build exposed an actor-isolation warning, fixed before the retry. The visual fixture height was increased after inspection showed a clipped heading; this was test-only.

The final affected scope passed **11/11 methods** (9 XCTest + 2 Swift Testing), including the original failure, same-origin browser changes, legacy file fallback, settings revocation and real favicon helper rendering. Across both passes, **29 distinct methods** were validated. No full suite ran.

Initial scope and change mapping:

| Scope | Methods | Purpose |
| --- | ---: | --- |
| `ClipboardAppIconProviderTests` | 9 | Descriptor bounds/voice app bundle, browser contracts, real Finder/missing application helper, settings native visibility/account/deinit, retained late-work pixel lease, raw UI pixels and denied access |
| `NativeIconIsolationTests` | 4 | Allowlist, retained cancellation admission, crash/hang with no replay, scoped generation/revocation |
| `ClipboardThumbnailIsolationTests` | 4 | Same-ID entry changes, deletion/late output, scope capacity, actual panel hiding/account changes |
| `AskContextImageTests` | 2 | Authorization after await/display and failure/invalid raster without getter retry |
| `ClipboardRowRenderingTests` | 4 | Direct history row callers |
| `ClipboardDataSettingsTests.testPaneDrawsIgnoredAppsAndUsage` | 1 | Both settings lists and layout |
| `AskBrowserFaviconTests` | 1 | Origin stripping and typed fallback contract |
| `AskBrowserSearchTests` | 3 | Plugin toggles/selection, direct-results UI, browser actions |

Final scope: all nine `ClipboardAppIconProviderTests`, plus `AskBrowserFaviconTests` methods `origins exclude paths queries credentials and non web tabs` and `native icon renders cached image and fallback without changing row size`. The latter is the 29th distinct method. Browser fixtures use injected history/loaders; no real browser search, website request or application launch occurs. `source-app-icons.png` is the actual scoped component with injected magenta raw rasters, not a screenshot of the full app or real application artwork. Its pixels and post-hide clearing were tested, and the final screenshot was visually inspected.

Commands used the sanitized `scripts/test_runtime.child_environment()`:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
# Verify __llvm_covmap and __llvm_prf_cnts in host test bundle and helper; save matching binaries.
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '^Typeflux(?:Focused)?Tests[./](?:ClipboardAppIconProviderTests[./]|NativeIconIsolationTests[./](?:testAllowlistAndBoundsRejectBeforeDispatch|testAdmissionSurvivesUncooperativeCancellation|testChildCrashAndHangFailOnceWithoutReplaying|testScopedViewRefreshesGenerationAndClearsOnRevocation)|ClipboardThumbnailIsolationTests[./](?:testSessionRejectsChangedEntryWithSameIDAndOldWindowEpoch|testDeletedEntryAndSessionClosureRejectLatePixels|testScopeCapacityIsBoundedBeforeDecoding|testActualOrderOutCloseAndAccountChangeRevokePanelScope)|AskContextImageTests[./](?:testAuthorizationIsRecheckedAfterAwaitAndOnEveryProjection|testFailureDoesNotRetryFromGettersAndInvalidRastersFailClosed)|ClipboardRowRenderingTests[./]|ClipboardDataSettingsTests[./]testPaneDrawsIgnoredAppsAndUsage|AskBrowserFaviconTests[./]`origins exclude paths queries credentials and non web tabs`|AskBrowserSearchTests[./]`(?:plugins list without selection and respect feature and browser toggles|browser settings and results render at compact and regular widths|bookmark actions use source selected or default browser and copy URL)`)'
# After correction and another verified instrumented build:
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '^Typeflux(?:Focused)?Tests[./](?:ClipboardAppIconProviderTests[./]|AskBrowserFaviconTests[./]`(?:origins exclude paths queries credentials and non web tabs|native icon renders cached image and fallback without changing row size)`)'
python3 -m unittest scripts.tests.test_media_packaging
# Copy the built helper using scripts/copy_media_helper.sh, then request nativeIcon/application/com.apple.finder.
```

Task-local `gul-399-source-icons-test.py` and `gul-399-source-icons-retry.py` contain the exact regexes, including literal backticks for Swift Testing names. No discovery rebuild was inserted. Every build/test was collected before editing inputs. Two packaging tests passed; the copied-helper probe returned the expected 56×56, stride-224, 12,544-byte raw raster and matching request identity.

| Command | Wall time |
| --- | ---: |
| Initial instrumented build | 257.79 s |
| Sequential fallback preparation build | 89.47 s |
| Main-actor snapshot/identity build | 55.33 s |
| Screenshot fixture-only build | 36.13 s |
| Initial focused test command | 22.34 s |
| Final affected test command | 10.83 s |
| Packaging runner / copied-helper probe | 0.163 / 0.193 s reported by runners |

Tracked build/test command total: **471.89 s**, plus packaging/probe, review, coverage extraction and screenshot inspection. The packaging numbers do not include Python startup. No compiler failures; one functional first-pass failure, fixed and retested. No paid provider, live network, clipboard capture/copy/paste, microphone/TCC, signing or hardware exercise.

## Coverage and limits

Changed executable lines: **96/99 = 96.97%** (`source-app-icons-coverage.json`). Three uncovered lines are the actual settings controller construction/environment bridge. Standalone native settings-window visibility and component behavior were exercised without constructing unrelated audio/hotkey services. Line hits, including closure declarations, are not every-branch/native-allocation proof.

Coverage is attributed per file, never by merging different counter layouts:

- Initial saved binary with five profiles (3 host, 2 direct helper) for production files unchanged after that pass.
- Final saved binary with six profiles (3 host, 2 direct helper, 1 copied helper) **only for `AskBrowserFaviconView.swift`**, which changed after the first pass.
- Each raw profile was individually validated; both merges completed without warnings. New sources were included via `git add -N`; helper was supplied as `llvm-cov --object`. No earlier increment's profiles were reused. Matching evidence is retained task-locally under `.build/source-icon-validation/{initial,final}`.

Initial XCTest SHA-256: `a721562f7edf50e7f62371a8543a536dce3f8f39914418d750e480e0290305ee`.
Final XCTest SHA-256: `b4d92251b67bcbaa15c292947ab3c8be89aa1851ebff61bfa3d8a7aff2de944e`.
Unchanged helper SHA-256: `297e3de56201c064e8794b4d29976ecad51c8b45e11160d77b47af14da0a36ba`.
App and helper Mach-O minimum OS remains 13.0; the XCTest runtime target reports macOS 14, not macOS 13/Intel hardware validation.

Remaining clipboard native paths include explicit PNG-to-TIFF pasteboard conversion, Vision OCR and inline AVPlayer playback; user-invoked OS Quick Look is separate. Foundation bundle/filesystem reads, raw bitmap display, pasteboard, SQLite/JSON/import-export and UI remain host boundaries. Native icons are snapshots, not filesystem watches. Pixel reservations do not bound every AppKit/GPU/system allocation. Registry/persisted-health integration beyond the three stores, further lifecycle wiring, and audio/TCC/signing/performance verification before choosing capture isolation remain required. Real CoreML, full Xcode build, Developer ID/notarization, Intel/macOS 13 and actual quit/recording integration remain unverified. GUL-399 is not ready for overall acceptance.
