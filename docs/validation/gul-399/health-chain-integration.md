# Worker health chain integration (GUL-399)

## Unified landing

Existing PR #579 is the single main landing entry for the completed #561–#579 dependency chain. Its original standalone progress scope is expanded to include the independently validated worker health/retirement increments. The earlier scope reports remain historical validation records. The user asked the agent to own review, integration and merging rather than leave these draft PRs for manual review.

All 19 actual GitHub head SHAs were inspected and proved ancestors of original #579 head `8ee9a5beca5871829a76fb3872b6eedea7abd13d`. Each was open/draft, with no reviews, comments or reported checks at inspection. Main `ceeaaef5bf4f2e5625a0654d6f3d31702821f174` was incorporated without conflicts in local commit `224f957110e020a1bb3706af2e67a393b00675e9`. No rebasing or force-pushing is required. Landing uses a merge commit so the actual constituent heads remain provable ancestors; intermediate branch merges alone are not delivery to main. Old drafts can be closed as superseded only after actual main ancestry is verified.

The tree audit verified 13 main-only paths byte-for-byte and initially all 125 feature-only paths. Seven shared paths were reviewed: AppCoordinator, ModuleHealthStore and the five localization tables. Every main localization value and every added/changed feature value survived. After the explicit startup repair below, 123 feature-only paths remain byte-identical; the only two intentional differences are AskFileIndex and its module regression test. Main's chat feedback, background activity window, stop script and storage-only automatic persistent-quarantine recovery are preserved. Worker policy defaults remain false for automatic persistent-quarantine reset; only StorageModules opts in.

Review covered registration/adapter lifetime and the 22 independent domains, availability-only factories, original generation admission, native/host/child retirement and mutation ownership, bounded health observers/metadata, controlled native refusal versus protocol faults, semantic original grants/cache/fallback and progress finalization. There is no request replay or new helper/pool/full DI path. See the constituent reports for their typed operation and resource boundaries.

## Startup repair found during integration review

Launcher construction/open calls refreshQuickApps, which explicitly starts the filename index. Registry startup runs asynchronously. A start that arrives before reader readiness previously recorded the scope as its target while marking the index suspended. Later explicit starts of that same scope then matched the recorded target and did nothing, even after capability became ready.

A never-admitted initial configuration now remains unconsumed while admission is closed. Readiness still performs no scan. A later explicit launcher start can process that configuration with current permissions. A previously admitted/faulted scope retains its target, so health recovery still cannot silently replay its scan: the existing cache/snapshot and explicit rebuild/scope-change behavior remain.

A new production-reader regression starts a private synthetic directory before binding, proves no reader was admitted, makes the capability ready and proves no automatic scan occurred, then explicitly starts the identical scope and finds its file. The existing managed-cache regression also confirms a previously faulted scope is not automatically rescanned after recovery.

## Focused validation

Implementation/self-review preceded the initial integration test. A later audit identified the startup gap above; the initial run and its profiles/extraction finished before any source edit. The final repair was reviewed and rebuilt before its affected test scope.

- Initial mapped integration: **303/304** methods passed (203 XCTest, 101 Swift Testing). The one failure was main's unchanged AskResponsiveWorkspaceTests.storageWarningOffersFeedbackAndImageRecoveryButtonIsAbsent: the expected native accessibility node for the feedback button was absent. Its unchanged single-method isolation retry passed. No production/UI fixture was altered to hide that failure, and its cause remains unconfirmed.
- After the filename startup repair: **18/18** affected methods passed (10 FileIndexModule XCTest methods, 7 AskFileIndexService methods and 1 actual semantic-launcher filename fallback consumer). This includes one new filename regression and a fallback method outside the initial inventory. The other initial passing methods were not repeated without a relevant source change.
- Across the initial, isolation and final affected scopes, **306 distinct methods** have passing results. This is not a claim that one unchanged 306-method run passed. Exact inventories are in health-chain-methods.json.
- **4/4** media/inference packaging checks passed. The existing copied inference-helper readiness/missing-resource/invalid-direction test ran in the initial scope without model preparation. After the final build, an actually copied media helper accepted an invalid private input only as a bounded `failed` terminal, without state or replay. That probe used no valid audio input and never sent play.

The initial scope deliberately covered the 13 new worker-domain/module suites; shared supervisor/registry/persistence; file/semantic reader and embedding ownership; mutation/install admission; native command protocol/refusal behavior; Whisper pool/client/protocol; media worker and playback capacity; semantic service/fallback/progress; and main's automatic storage recovery, draft-warning clearing, feedback action and background row rendering. It was 49 named suites, not a full project or UI group. Valid native audio metadata, real-model/event, live download and real permission-probe methods were excluded.

All input data was private and synthetic, or supplied through injected engines/readers/transfers/sinks. Native media compatibility used private PNG/PDF/text or no-audio video; Whisper paths used injected engines and a resource/protocol probe without preparing a model. No real weights/CoreML inference, network/download/provider, user folders/network mounts, TCC permission changes/probes, capture/microphone, native audio processing/output, user clipboard/paste/wheel, external app control, full suite/full Xcode, signing/notarization or hardware test ran. Test-host windows/accessibility and direct synthetic events remained inside the test application's owned fixtures. No product presentation changed; no new screenshot is claimed.

Commands used scripts/test_runtime.child_environment and the requested native build/test system:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '<explicit inventory>'
python3 -m unittest tests.test_media_packaging tests.test_inference_packaging
```

Prebuilt discovery used native_environment/native_tools and swiftpm-testing-helper, not xctest as a program. Both coverage sections were checked in test, app, media helper and inference helper executables before testing. No simultaneous own SwiftPM/UI jobs or source/test edits during active commands occurred.

## Coverage, provenance and timings

The **initial integrated chain** against main covered **1,482/1,501 added/modified executable lines (98.73%)**, using its own matching binary set. That result predates the startup repair and is not relabeled as final-binary coverage. The **final startup repair** against local integration commit `224f9571` covered **3/3 changed executable lines (100%)**, using only the final build's fresh profiles. The adjacent JSONs keep those attributions separate. No raw profiles from different binary layouts were combined; Swift function hashes do not establish cross-layout compatibility. Constituent reports also retain their original per-increment coverage and limits.

Initial archive: 29 fresh profiles; unchanged UI retry: 2 fresh host profiles with the identical initial binary, archived separately; final archive: 4 fresh profiles. Each raw was individually validated, merges/extraction were warning-free, and matching app/media/inference objects were supplied to llvm-cov. Initial and final source/test hashes were checked against their pre-test input snapshots (1,123 production Swift and 802 test files). No source/test input changed after the final build. All commands and owned children/copies/archive/extraction finished before subsequent edits/delivery. Persistent killed workers need not emit profiles; this is not all-child or all-native-branch coverage.

Local evidence directories under .build/health-integration-validation are initial, ui-retry and final. Final SHA-256:

| Binary | SHA-256 |
| --- | --- |
| Tests | b4897a03defeb29ed79b9a2bbf8359cfea2edff2b826e613b76ead41e9adbc3b |
| App | 96aea3fb8db155d07dc3a045efba1f9e65eb99437e7702c1b41331fc63b29a44 |
| Media helper | 57c51e187bbe82e2e2d30a67c5bddad177bce97b710f5ff0a0c627287f06f331 |
| Inference helper | 5ead3bd07eb5a8942f5f89f0ea93bb42288ac86b2e5ff03601c627f39bf35b46 |

Builds **254.39 s** initial and **49.66 s** repair; inventories **3.693 s** and **3.602 s**. Initial test command **96.58 s**, unchanged UI isolation **3.69 s**, final affected command **16.19 s**. Packaging **0.289 s**; copied helper **0.170 s**. Tracked build/inventory/test/packaging/probe wall total **428.264 s**, including runner preparation/startup. Separately measured archive work **36.724 s** (31.710 + 2.141 + 2.873). Coverage extraction, source/tree audits and git/platform delivery are outside those measured totals. Existing unrelated compiler warnings and the toolchain's native-system deprecation remain; no warning was introduced in the startup repair.

Line coverage is not all-branch/race, permission, device, allocation, immutable-filesystem, power-loss or real-quit proof. UI/AppKit/GPU, filesystem, SQLite and system memory remain host boundaries.

## Continuing GUL-399

This lands completed increments; it does not mark the whole stability task complete. Independent text-model download progress/attempt ownership and broader watcher/start/permission lifecycle still remain. Recovery must not prepare/download/query/scan/rebuild old input, delete models/databases or replay side effects. Further native/media audit and audio/TCC/signing/performance checks are required before microphone capture ownership. Capture/live meters and OS QuickLook remain separate; real-model performance, full Xcode/Developer ID/notarization, macOS 13 Intel and actual quit while recording are unverified. No arbitrary host-crash or system-wide resource-failure immunity is promised. The issue remains in_progress.
