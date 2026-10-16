# GUL-399: clipboard thumbnail lifecycle and persistent health

This PR targets main directly at `6f838412bde3a8215b3974ea96c7eb99afd312fc`. During delivery, #559 merged at `88fa78b5cd0f161ea5113412ebc8d4b136679f5f`; the member retargeted #560 to main and merged it at `6f838412`. Its `2b84f959` implementation is an ancestor of main. The feature was first tested on #560, then locally integrated with actual main and validated afresh. No GitHub PR was merged by this agent; no CI wait occurred.

The merge preserved 32 main-only and 9 feature-only paths byte-for-byte. The only five shared paths were localization tables: all main values, intentional removals, and the one feature addition per language were checked. No executable conflict/resolution changes. Main's semantic indexing/details/pause, menu-bar color removal, and conversation storage recovery UI remain intact. `clipboard-thumbnail-health-tree-audit.json` records the inventory.

## Behavior and audit

`MediaWorker.clipboardThumbnails` now starts closed until its independent `clipboardThumbnails` registration is bound and ready. It reuses `MediaExtractionModule`, its generation gate, coalescing observer and persistent `clipboardThumbnails.json`; neither the attachment extraction nor preview health budget is charged for its failures. Reservations remain once per factory generation, never per thumbnail. Corrupt metadata remains intact until deliberate reset. Expected unreadable/oversized/source/configuration outcomes retain the existing classification; malformed protocol, invalid raw output, process failures and deadlines fault only their domain. Executable readiness is not format, signing or device validation.

`MediaExtractionModules` composes and retains the three managed adapters with a closed domain-to-worker/ID mapping. Its injectable composition is exercised without constructing full DI, AppKit services, audio devices or user stores. DI adds its registrations to the unchanged three storage registrations. No helper target, protocol, packaging path or global test bypass was added.

Audited `ClipboardThumbnailProvider`, environment decoder, `ClipboardThumbnailView`, PDF/preview rows, panel model/controller and session scope. The provider already accepts an explicit worker, and controller/view tests have decoder seams. Only one existing direct real-helper test needed an explicit standalone worker. Production defaults fail closed before binding. No path cache or automatic request retry was added.

Original typed image/Quick Look semantics and bounds remain: two host decoder admissions, two child leases, three-second child deadline, original image/Quick Look limits, pixel reservations, private input and raw output validation. Lifecycle cleanup awaits the SAME pool through actual child collection AND uncooperative host completion. A cleanup timeout does not free occupied slots or install a second pool. Readiness/recovery does not reread history, capture clipboard, copy, paste or replay a producer.

Per-entry authority remains owned by the feature: capture pause still permits history viewing; actual orderOut/close, selection/replacement/deletion, account changes, collapse and owner release invalidate the original session. A newly ready service cannot bless an old access epoch or publish a cancelled result. Existing already displayed, still-authorized pixels are not a new permission grant from module health.

Settings adds five localized labels and the existing state/recovery control. Screenshot `clipboard-thumbnail-health.png` is the actual 640×190 unavailable row; visually inspected. Its actual recovery button is driven with an injected process runner that fails the test if recovery executes a request.

## Focused validation

Implementation and self-review preceded functional tests. One feature build/pass and one fresh main-integration build/pass; no compile/test failures or correction retries. The 68 methods are distinct methods, not 136.

- Direct instrumented native builds: feature **220.07 s**, final integration **251.90 s** (inner builds 216.48/251.52 s).
- Prebuilt native inventory: **4.571 s**; no discovery rebuild or direct xctest execution. Initially 67 matched methods, then the source-verified `StorageModuleRegistryTests` compatibility suite added its one method before execution.
- Focused test command: **68/68 distinct methods passed**, 48 XCTest + 20 Swift Testing, feature **33.36 s**, final integration **17.85 s** wall time. Final XCTest 8.170 s; Swift Testing 0.510 s. Both 68/68 passed.
- Packaging: **2/2 passed**, unittest reported **0.225 s**. No new copied-helper probe: helper/protocol/packaging unchanged; real managed image/PDF, native icon/Quick Look and existing child-fault paths ran in the selected suites.
- Tracked build/inventory/test/unittest durations total **527.976 s**, excluding packaging interpreter startup, audit, profile archival/extraction and screenshot inspection. Compiler emitted existing unrelated Sendable/AppKit deprecation warnings; no new functional warning was treated as a passing test.

Scope mapping:

| Scope | Methods | Purpose |
| --- | ---: | --- |
| ClipboardThumbnailModuleTests | 7 | defaults, exact three-pool composition, independent budgets, corruption/reset with injected clock, expected refusal vs malformed raster, occupied cancellation/late result, real scoped PNG/PDF consumer and recovery without replay |
| ClipboardThumbnailHealthViewTests | 1 | localized actual row, recovery action, screenshot |
| ClipboardThumbnailIsolationTests | 12 | image/source changes, PDF, input bounds, crash/hang, retained admissions, deletion/epoch, panel hide/account/collapse/owner and actual pixels |
| MediaExtractionModuleTests | 13 | shared adapter recovery, permission/readiness conditions, sibling fault, actual reaping plus host completion, shutdown and old generation |
| MediaPreviewModuleTests | 5 | existing managed preview consumers and independent state remain compatible |
| MediaWorkerTests | 9 | private input/process ownership, bounds, cancellation and shutdown |
| ModuleRegistryTests | 12 | dependency/condition ordering and late-result/retirement behavior |
| ModuleHealthStoreTests | 6 | bounded persistence, quarantine/corruption, simulated stability, failure/reset |
| StorageModuleRegistryTests | 1 | existing three stores retain independent factories and health |
| ClipboardPanelRenderingTests | 1 | changed direct thumbnail fixture, real helper, no path cache |
| LocalizationResourceTests | 1 | all five tables parse |

Commands (using `scripts/test_runtime.child_environment`):

```text
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter <regex below>
python3 -m unittest scripts.tests.test_media_packaging
```

```text
'^Typeflux(?:Focused)?Tests[./](?:ClipboardThumbnailModuleTests[./]|ClipboardThumbnailHealthViewTests[./]|ClipboardThumbnailIsolationTests[./]|MediaExtractionModuleTests[./]|MediaPreviewModuleTests[./]|ModuleRegistryTests[./]|StorageModuleRegistryTests[./]|ModuleHealthStoreTests[./]|MediaWorkerTests[./]|ClipboardPanelRenderingTests[./]testThumbnailsUseValidatedPixelsWithoutPathCache(?:\(|$)|LocalizationResourceTests[./]testLocalizedStringTablesParseForAllSupportedLanguages(?:\(|$))'
```

Both screenshot environment variables were supplied. No full suite, user clipboard/copy/paste/wheel, real capture/TCC/audio output, network/provider/app launch, signing, full Xcode or hardware exercise occurred. Fixtures used private synthetic media, injected sinks/processes and harmless crash/hang children. All jobs were collected; no test/helper child remained at validation end.

## Coverage evidence

Changed executable lines against the actual PR base: **20/22 = 90.91%**. The two uncovered lines are DI construction/registry composition (`DIContainer.swift:159–160`); the injected production composition itself is covered. LLVM attributed no executable added lines to the static worker/enum declarations. No claim of a test hitting every branch or a real application quit follows from line coverage.

ONLY the final integration pass's **25 fresh profiles** (3 host + 22 direct-helper) were used with ONE final binary set. Every raw profile was checked individually with llvm-profdata before the warning-free merge; no earlier passing result/profile or counter layout was reused. The inventory-only root `default.profraw` was excluded and archived separately. `__llvm_covmap` and `__llvm_prf_cnts` were verified. Helper was supplied as llvm-cov `--object`; there are no changed helper lines. Production source hashes still matched the archived build after extraction.

Earlier feature profiles/binaries are archived separately in `final` and excluded from final coverage. Local matching final evidence: `.build/clipboard-health-validation/integration` (not a runtime artifact delivery).

- XCTest SHA-256: `4a74e5ca85a6680c52fd2ff429cb4d62e3b7fc593bd357c8c9b7d1e5214bec28`
- Helper SHA-256: `25072bcc62620da339441bbbf1c05d19f20e5c0fbb641b95eafc70fe5e1f09d2`
- App/helper `LC_BUILD_VERSION` minimum macOS 13; this is not macOS 13/Intel hardware validation.

## Remaining boundaries

Only attachment extraction, previews and clipboard thumbnails are registered media pools. Frame registration, shared text recognition/clipboard OCR, metadata/timeline and recording encoding still need independent adapters. Custom owned encoding streams/unknown outputs must not be treated as already classified by `MediaWorker.perform`. Native/inference/playback/feature adapters and broader condition-driven lifecycle remain unfinished. Account/source permissions remain feature-owned.

Storage, retained recording attempts/receipts and single authorized publication are unchanged. No write, paid generation, workflow, recording or shutdown replay. Host filesystem/JSON/base64/raw bitmap/pasteboard/SQLite/UI and AppKit/GPU/system memory remain boundaries; an uncooperative filesystem call retains capacity. Health metadata is bounded/content-free and off the UI request path, not a durability/fsync/power-loss guarantee. Real CoreML/performance, full Xcode/signing/notarization, macOS 13/Intel, actual quit/recording and audio/TCC verification before capture ownership remain required. GUL-399 is not ready for overall acceptance.
