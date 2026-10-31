# GUL-638 review handoff

The inline speech and AI model pages are submitted for code review. Following the user's latest instruction on GUL-634, **tests and native screenshots move to GUL-642**. No passing Swift build, Swift test run, changed-code coverage percentage or updated native screenshot is claimed here.

## Implementation

- Speech cards use the existing provider order and configuration keys. Held microphone audio goes to the selected production transcriber; failures never become simulated successes or silent fallbacks. Successful transcription enables Continue.
- Google uses the existing OAuth flow followed by the approved Project ID field (`my-project-id`). Both authorization and a nonblank project are required for testing; an authorized account missing its project gets one inline field error.
- LLM configuration reuses the real model catalog and connection probe, preserves existing endpoints, and stores canonical library references. Empty catalogs never invent installed Ollama models. Multimodal speech follows the next step's selected connection.
- Five locale tables cover the prototype copy. Provider cards, configuration spacing and onboarding marks follow `docs/design/onboarding-v3/prototype.html`.

## Checks actually executed

| Check | Result | Wall time |
| --- | --- | --- |
| `xcrun swiftc -frontend -parse` on all 16 changed Swift sources/tests | Passed; syntax only | 0.139 s |
| `swiftlint lint --quiet` on nine onboarding production files and five new test files | Passed, no violations | 0.744 s |
| `git diff --check` | Passed | 0.060 s |
| Five-locale string-key parity and `plutil -lint` | Passed; 51 speech / 55 LLM keys per locale | 0.182 s |
| `python3 -m unittest scripts.tests.test_test_runtime scripts.tests.test_test_groups` after updating the compact source profile | 44 tests passed | 4.760 s |

Raw lint on `ModelProviderIcon.swift` still exits 2, exactly as on the main baseline `ae1fa2fa`: complexity 22/29 and the existing 60-line function warning. Baseline/current comparison took 0.445/0.323 s. The Soniox resource mapping adds no switch case or complexity.

Earlier coverage compilation attempts exited before Swift test execution: the first took 2471.90 s after acquiring the global lock; the compact retry took 175.26 s. Test-source import/actor annotations were corrected and the compact retry's missing analytics fixture was identified. The next queued retry and its newly started build were stopped on the user's instruction. No coverage data or native page captures were produced.

## Self-review and GUL-642 follow-up

Reviewed entry-to-exit configuration persistence, empty/error paths, cancellation, stale results, credential isolation, five-locale copy and resource cleanup. Fixed a late download-progress callback that could restore Downloading after completion/failure by invalidating its generation at either terminal result. Added regression cases for that race, permission-dialog release, OAuth cancellation, Project ID gating, canonical model references and multimodal handoff.

The new `OnboardingSpeechLLMTests` suite is split into fixture, speech behavior, LLM behavior, native controls and native capture files. It carries `.exclusiveUIState`. Native capture fixtures cover English/Chinese and light/dark, including provider/configuration/error/result states and open model/provider menus. These fixtures have **not executed**; GUL-642 must build and run them as part of the final integration pass and inspect the resulting captures. Real microphone/OAuth/network acceptance also remains unverified.

## Provider assets

Missing Google and Soniox marks are bundled from their public assets:

- [Google mark](https://www.gstatic.com/images/branding/product/1x/googleg_48dp.png)
- [Soniox mark](https://soniox.com/icons/favicon-96x96.png)
