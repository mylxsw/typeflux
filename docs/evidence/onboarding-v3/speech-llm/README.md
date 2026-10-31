# GUL-638 validation status

This is a draft implementation. Compilation, focused tests, changed-line coverage and updated native screenshots are pending. No test-pass or coverage claim is made.

The browser reference is `docs/design/onboarding-v3/prototype.html`. All 10 speech and 8 AI model reference states were inspected in light and dark on this Mac. The new native capture test prepares every provider/configuration/result state in English and Chinese, in both appearances; it has not executed yet.

## Checks executed

- `xcrun swiftc -frontend -parse` on the changed onboarding sources, provider icon source and new tests: passed, 0.223 s. This checks syntax, not types or linking.
- Five-locale key parity plus `plutil -lint` on both page string tables: passed, 0.045 s.
- `git diff --check`: passed, 0.088 s.
- Raw SwiftLint on changed production files: exit 2, 0.472 s; two complexity errors in existing `ModelProviderIcon` switch functions and seven warnings. The baseline source also reports both complexity errors (22/29); the added Soniox branch changes the first count to 23.
- Focused coverage command queued under `/usr/bin/lockf /tmp/typeflux-gul634-swift.lock` for 736.44 s, then cancelled before acquiring the lock. No build or test child started. Scope: `OnboardingSpeechLLMTests`, `OnboardingNavigationTests`, `OnboardingComponentTests`, `OnboardingViewModelTests`, `ConnectionTestSupportTests`.

## Design decision required

`GoogleCloudSpeechConfiguration` rejects an empty Project ID, and `SettingsStore.googleCloudProjectID` defaults to empty. The prototype provides only a Google OAuth button. Existing configured projects continue to work; a new user cannot complete Google speech setup through that panel. The draft preserves the actual service error. The parent owner needs to decide whether to add the existing Project ID field or change the project-selection flow before this PR can become ready.

## Self-review

Removed simulated production replies and wired held audio to the selected engine. Checked credential persistence, cancellation, late-result guards, recording-file cleanup, model registry references and five-locale copy. Added focused tests for those paths and for existing endpoint preservation, empty catalogs and Ollama retry. These are source-level review findings; runtime verification remains pending.

## Provider assets

Missing Google and Soniox marks are bundled from the providers' public assets:

- [Google mark](https://www.gstatic.com/images/branding/product/1x/googleg_48dp.png)
- [Soniox mark](https://soniox.com/icons/favicon-96x96.png)
