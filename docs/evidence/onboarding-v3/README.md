# Onboarding v3 final integration evidence

Final native AppKit/SwiftUI captures are in `native/`. Open `comparison.html` locally to compare them side by side with the browser captures in `prototype/`. The prototype is Chinese; English captures use the same layout reference. `foundation/` is historical stage-one evidence and is not part of this final matrix.

The native flows use isolated test accounts, permission services, model catalogs and connection probes. The shipping web-auth rollout remains disabled. These captures do not certify a live OAuth exchange or physical microphone dictation. The practice success detector remains backed by successful applied history records.

Native model fields preserve their custom layout through real AppKit popup controls. Local speech is first, as in the prototype. The shipped free-LLM registry is empty: that state blocks continuation and connection testing; no endpoint or model was invented. Closing asks for confirmation and records unfinished permissions for recovery.

## Validation

All Swift commands run under `/usr/bin/lockf /tmp/typeflux-gul634-swift.lock` with a Python subprocess timeout. Compilation is capped at two jobs; wall times include waiting for the shared lock, preparation and discovery. The full suite is invoked once, with only failed or unexecuted scopes run afterward if necessary. No coverage target was requested.


Final affected-scope method counts: xctest: 22 passed, 0 skipped, 0 failed, 0 unexecuted, swift_testing: 126 passed, 0 skipped, 0 failed, 0 unexecuted. See `validation-ledger.json`.

| Command | Result | Total wall time |
| --- | --- | --- |
| [baseline-ios-script](baseline-ios-script.json): `python3 -m unittest discover -s scripts/tests -p test_ios_cli.py -k test_http_exception_is_only_in_debug_plist` | Baseline failure reproduced | 0.54 s |
| [baseline-script-tests](baseline-script-tests.json): `python3 -m unittest discover -s scripts/tests -p test_test_coverage.py` | Baseline failure reproduced | 5.24 s |
| [baseline-spotcheck](baseline-spotcheck.json): `swiftc '<pristine ClipboardCategory.swift>' '<original assertion inputs (standalone Swift comparison)>' -o baseline-probe` | Baseline failure reproduced | 454.00 s |
| [build-first](build-first.json): `swift build --jobs 2` | Failed (exit 1) | 727.74 s |
| [build-retry](build-retry.json): `swift build --jobs 2` | Passed | 728.47 s |
| [localization-parse](localization-parse.json): `plutil -lint 'Sources/Typeflux/Resources/*/{Onboarding*,Localizable}.strings'` | Passed | 0.88 s |
| [native-export](native-export.json): `/usr/bin/swift ../export-gul642-native.swift ../gul642-native-snapshots docs/evidence/onboarding-v3/native` | Passed | 65.04 s |
| [onboarding-lint-final](onboarding-lint-final.json): `swiftlint lint --quiet Sources/Typeflux/Onboarding` | Passed | 1.49 s |
| [png-export-final](png-export-final.json): `/usr/bin/swift ../normalize-gul642-png.swift ../gul642-native-snapshots` | Passed | 312.98 s |
| [test-full](test-full.json): `make test-full 'REASON=GUL-634 final validation after stage-2 merges'` | Failed (exit 2) | 3156.93 s |
| [test-onboarding-capture-final](test-onboarding-capture-final.json): `make test PROFILE=onboarding 'FILTER=native pages cover provider configuration'` | Passed | 241.50 s |
| [test-onboarding-controls-final](test-onboarding-controls-final.json): `make test … (exact arguments in linked JSON)` | Passed | 527.01 s |
| [test-onboarding-failed](test-onboarding-failed.json): `make test … (exact arguments in linked JSON)` | Failed (exit 2) | 166.26 s |
| [test-onboarding-final-retry](test-onboarding-final-retry.json): `make test PROFILE=onboarding` | Failed (exit 2) | 474.30 s |
| [test-onboarding-final](test-onboarding-final.json): `make test PROFILE=onboarding` | Failed (exit 2) | 125.00 s |
| [test-onboarding-menu-retry](test-onboarding-menu-retry.json): `make test PROFILE=onboarding 'FILTER=welcome language menu\|native pages cover provider\|rendered provider controls\|native model\|model picker'` | Failed (exit 2) | 523.06 s |

The one full run failed in 19 unrelated XCTest methods before serial Swift Testing began. `baseline-failures.md` lists those names and the pristine-main component spot check. Subsequent exploratory runs of unrelated suites were incomplete; their fixture edits were withdrawn. The passing counts above cover the final affected scope only, and do not claim the repository is globally green.

The script runner’s own 23 unit tests passed (0.444 s). `make test-scripts` ran 176 tests in 75.959 s with three failures, all reproduced in pristine main; see `baseline-failures.md`. `diagnostic-runs.json` summarizes the earlier incomplete diagnostic attempts whose unrelated fixture edits were withdrawn.

The first build exposed an accidentally removed configuration-signature dependency used by the new LLM page. The shared signature was restored before the successful build. Onboarding SwiftLint passes with 18 warnings; the touched AppCoordinator caller retains the same four pre-existing lint errors as main (`swiftlint-baseline.json`). All localization tables parse and all five languages have identical Onboarding table key sets. Each locale drops the same 198 obsolete Localizable keys, plus the five prototype-only page-table keys. Four close-confirmation strings come directly from the prototype and are supplied in all five languages.

PNG exports use 8-bit sRGB at the wizard’s point resolution (Retina source pixels downsampled 2×), matching the prototype’s 960 × 664 layout; menus can extend the canvas. No layout elements are synthesized in the native captures.

The export utilities used by the recorded runtime commands are preserved in `tools/`. To regenerate the native source captures, set `TYPEFLUX_GUL303_SNAPSHOTS` to an output directory and `TYPEFLUX_NATIVE_MENU_CAPTURE=1` when running the affected capture tests; `tools/export-native.swift` accepts that directory and an export directory.

## Native matrix

| Page | English light | English dark | Chinese light | Chinese dark |
| --- | ---: | ---: | ---: | ---: |
| welcome | 4 | 4 | 4 | 4 |
| route | 4 | 4 | 4 | 4 |
| cloud | 15 | 15 | 15 | 15 |
| speech | 21 | 21 | 21 | 21 |
| llm | 30 | 30 | 30 | 30 |
| permissions | 13 | 13 | 13 | 13 |
| shortcuts | 10 | 10 | 10 | 10 |
| try | 8 | 8 | 8 | 8 |

The comparison manifest contains 420 native captures and SHA-256 hashes. The browser reference contains 96 page/state captures across light and dark appearances.

## Self-review

Checked route completion, back/skip/resume behavior, close confirmation and deferred settings, late auth/model callbacks, task and recorder cancellation, localization references and credential handling. The shell uses page readiness and inline actions; old guide, editor and duplicate probe paths are removed. Unified permission counts and skip impacts with the visible page, including missing snapshots. The simulation control, sample output and Raycast guide row are absent. Existing native interaction and race tests cover the retained page models. The native close-confirmation fixture checks duplicate close requests, cancel preserving the session, and exit recording unfinished permissions and invoking completion once.

## GUL-637 handoff confirmation

The complete 19-method OnboardingRouteCloudTests suite passed. This includes the rendered route/browser controls, the native route/cloud state matrix, and native close cancellation. Rechecked subscription-refresh versus download-failure ordering, late entitlement results after leaving/replacing an account, stale-account download failure, Back callbacks and global callback ownership. The shared native titlebar/resume fixtures also passed after adopting the explicit close confirmation.

## Change-to-test mapping

| Behavior | Suites |
| --- | --- |
| Routing, readiness, recovery and permission counts | OnboardingNavigationTests, OnboardingViewModelTests, OnboardingComponentTests |
| Prototype controls and real dictation detection | OnboardingTryTests, OnboardingPermissionsTests |
| Credential signatures, cancellation and late callbacks | OnboardingSpeechLLMTests, OnboardingRouteCloudTests |
| Native pages, controls and state captures | OnboardingBehaviorTests, OnboardingComponentTests, OnboardingRouteCloudTests, OnboardingSpeechLLMTests, OnboardingPermissionsTests, OnboardingShortcutsTests, OnboardingTryTests |
