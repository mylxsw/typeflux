# GUL-399: attachment extraction lifecycle and persistent health

Base: main `78c18c46ada60193adf820ae50b2d97cdd1e7038`, the actual merge of #557. All earlier increments were already on main. This increment does not rebuild the old PR chain or change helper packaging/protocols.

## Delivered boundary

`MediaExtractionModule` registers **only `MediaWorker.shared`**, the attachment image/PDF extraction domain, alongside the three existing storage modules. Its stable pool remains the typed execution endpoint. The registry/supervisor owns readiness, disable, shutdown, recovery and content-free persistent reservations. The settings service section adds a localized attachment extraction row and deliberate recovery action. Other media pools, native commands, inference and playback remain independent and are not claimed integrated by this change.

Production shared extraction starts closed until DI binds it and registry startup succeeds. Readiness verifies that the configured executable exists and is executable; it does not decode a probe or prove every format/device/signing path healthy. No synchronous lifecycle IPC, disk access or task creation occurs in an admission check. Isolated test callers can explicitly inject a worker into the attachment loader instead of constructing full DI or opening the application's persistent health files.

The existing `ModuleHealthStore` reserves **once per generation/factory**, not once per image/PDF. Its existing four-reservation quarantine, explicit reset, bounded 4 KiB read, stable-health accounting and clean-stop semantics remain unchanged for storage. The added `mediaExtraction.json` contains only version, attempt count and quarantine flag. Corrupt/unwritable metadata fails closed and remains untouched until deliberate reset. Disk work stays in the supervisor's one bounded detached factory/cleanup. Blocking filesystem work may outlive a timeout, but keeps that lifecycle slot occupied; there is no replacement factory expansion or data deletion.

One bounded, coalescing event stream/observer reports activity and failure. Its separately retained fault generation cannot be lost when a later activity signal replaces a buffered event. The synchronous gate immediately fences that generation, including sibling and late results; the supervisor ignores obsolete fault signals. It reuses its existing backoff/circuit policy and never receives the old request as an argument. Readiness recovery cannot replay extraction, user writes, encoding or other producers.

Malformed/oversized input, normal typed decoder refusals, pre-dispatch source errors, saturation and cancellation do not count as subsystem crashes. Process failure/timeout, bad framing/JSON/identity and protocol violations do. Executable permission/not-found/not-executable launch errors wait for explicit recovery instead of an automatic crash loop. A missing helper at readiness also waits for explicit recovery; this slice does not install filesystem watchers or automatically infer changed permissions.

Two operation/child leases and the existing 30 s child budget remain. The supervisor's 15 s generic operation deadline is not wrapped around extraction requests; each typed pool keeps its own actual deadline. Cleanup awaits a single continuation released only when **host completion AND actual child collection** have emptied the same pool. Its 2 s production cleanup budget can report degraded/unavailable while retaining ownership indefinitely. Cancellation of cleanup does not release that continuation or capacity. Quit synchronously closes admission, including the existing `MediaWorker.preventNewWork` path. No replacement pool, queued input, host original-image fallback or full-DI helper is introduced.

Existing feature-level cancellation/session/account checks still govern attachment source consent and publication. Module health is content-free and is not an account permission grant. Registry disable/re-enable/quit are integrated here; broad account/feature condition wiring for all modules remains a later approved stage.

## Validation

Implementation and self-review preceded functional tests. Direct sanitized build and test commands:

```sh
python3 ../gul-399-supervisor-build.py
# swift build --build-system native --build-tests --enable-code-coverage --jobs 4
python3 ../gul-399-media-health-test.py
# swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '<scope below>'
python3 ../gul-399-media-health-test.py '^Typeflux(?:Focused)?Tests[./]AskCommandVisualTests[./]renderAttachmentsAndCommandPalette'
python3 -m unittest scripts.tests.test_media_packaging
```

Exact initial filter:

```text
^Typeflux(?:Focused)?Tests[./](?:MediaExtractionModuleTests[./]|MediaExtractionHealthViewTests[./]|MediaWorkerTests[./]|RecordingEncodingIsolationTests[./]|ModuleSupervisorTests[./]|ModuleRegistryTests[./]|ModuleHealthStoreTests[./]|StorageModuleRegistryTests[./]|ModuleRecoveryBudgetTests[./]|AskAttachmentLoaderTests[./]|AskCommandVisualTests[./]renderAttachmentsAndCommandPalette|ModuleHealthSettingsTests[./](?:unavailableObservationFailsClosedAndStateCopyIsLocalized|openingAndReopeningOnlyObserveAndReleaseSubscriptions)|LocalizationResourceTests[./]testLocalizedStringTablesParseForAllSupportedLanguages)
```

Prebuilt inventory used `test_runtime.native_environment/native_tools`, `swiftpm-xctest-helper` and `swiftpm-testing-helper`, not xctest executed as an application or a discovery rebuild. It selected **83 distinct methods (36 XCTest + 47 Swift Testing)**. Both `__llvm_covmap` and `__llvm_prf_cnts` were verified on tests/helper. `TYPEFLUX_ASK_SNAPSHOTS` and `TYPEFLUX_GUL303_SNAPSHOTS` were explicitly set, so visual methods executed.

- Thirteen new lifecycle XCTest methods cover per-generation reservations, expected refusals, synchronous fault fencing, automatic readiness recovery without replay, stale signals, permission/configuration holds, corrupt/quarantined persistence, actual child retirement, uncooperative host completion, sibling invalidation, capacity, duplicate binding/owner release and real synthetic attachment decoding through the managed facade.
- One new actual settings component test invokes recovery through its accessibility button and verifies no attachment execution. Its unavailable-state screenshot was inspected: `media-extraction-health.png`.
- Existing storage supervisor/registry/persistence/budget suites verify default storage behavior. Attachment loader/visual callers verify the injected seam. All nine MediaWorker methods and eleven recording encoding methods verify shared lease behavior, including harmless fault children and retained producer outputs. Synthetic audio tracks are encoded only, never played.
- Two packaging checks passed. No new copied-helper probe was run: there is no helper/protocol/packaging change; real helper attachment and existing encoding/fault tests ran in the focused scope.

Initial pass: **82/83 passed**, with all 36 XCTest methods passing. The one failing existing command snapshot method had four assertions across two appearances: `/mo` matched several commands and the existing selected/hovered `meeting-notes` skill; Tab completed that skill, not `/model`. The test fixture now types the unique `/model` query before testing completion. No product source was changed after the initial functional pass. The affected method was rebuilt and retried alone: **1/1 passed**. Its light/dark screenshots were generated and the corrected model submenu screenshot inspected. No functional retry of the other 82 methods, no full suite.

Builds: **223.35 / 79.07 / 36.28 s**, all passed. The first build reported a new captured mutable-array warning in a test; ownership was moved into the locked fixture before any functional test. The second build also included the final sibling-retirement test and safe NSError code comparison. The third changed only the command snapshot fixture. Focused commands: **48.18 / 20.27 s**. Build/test total **407.15 s**; inventory **7.17 s**; packaging tests reported **10.697 s**. Tracked total **425.017 s**, excluding packaging interpreter startup, audit, archival, coverage extraction and image inspection. Existing unrelated compiler warnings remain.

## Coverage and evidence

Changed executable lines against the actual main base: **146/150 = 97.33%** (`media-extraction-health-coverage.json`). Four unhit lines: DI construction/retention/registry composition (159–161), and the supervisor's default external-count closure (46). New adapter/gate and changed worker paths have line hits; this is not every-branch, native-allocation, scheduler or real-quit proof.

Coverage uses only **13 fresh profiles (3 host, 10 direct helper)** collected with the initial functional pass's production-final binary. Every raw profile was individually validated; merge was warning-free. New Sources were included with `git add -N`, and the helper supplied with `llvm-cov --object`. Production source hashes were compared after the test-only correction and were identical. Matching binaries/profiles are locally archived at `.build/media-health-validation/initial`:

- XCTest SHA256: `9400dd5e6b61502c5b88dff1e0d04f16cdd147f5143220bfdc100d4690095bd9`
- Helper SHA256: `25072bcc62620da339441bbbf1c05d19f20e5c0fbb641b95eafc70fe5e1f09d2`

The corrected fixture's two fresh host profiles and binary are separately validated/archived at `.build/media-health-validation/final`, XCTest SHA256 `7aa38a0e12c18cc1b2b85a5fba3634305e7d5d01207725efca8e047ac6b9f9e1`; they are **not merged across test counter layouts**. A discovery-only `default.profraw` predating functional tests was validated and archived separately, excluded from coverage. No prior increment's profiles or results were reused.

App/helper binary deployment targets remain macOS 13; the test runtime reports macOS 14, which is not macOS 13/Intel hardware validation. No live user clipboard writes/paste/wheel, audio output, capture/TCC, providers/network/apps, full Xcode build, Developer ID/notarization or real quit/recording exercise. Host filesystem, raw rasterization, UI/AppKit/GPU and system memory remain boundaries. No arbitrary host crash, system-wide OOM or power-loss guarantee.

## Remaining approved work

Other MediaWorker domains (preview, clipboard thumbnails, OCR/text geometry, registration, metadata/timeline and recording encoding), native/inference/playback and feature modules still need independent lifecycle/condition/persistence integration. Do not collapse their limits, automatically replay producers, or treat a lifecycle reservation as a request counter. Broader native/media audit and audio/TCC/signing/performance verification before capture-ownership decisions remain. GUL-399 stays in progress and is not ready for overall acceptance.
