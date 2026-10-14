# Repository Guidelines

## Project Structure & Module Organization

`Typeflux` is a Swift Package Manager macOS app. Main code lives in `Sources/Typeflux`, grouped by feature: `App/` for startup and DI, `Workflow/` for the voice-input pipeline, `STT/` and `LLM/` for provider integrations, `Settings/`, `Audio/`, `Hotkey/`, `History/`, and `UI/` for supporting modules. App resources and localizations live under `Sources/Typeflux/Resources`. Tests are in `Tests/TypefluxTests`, typically mirroring production types with `*Tests.swift` names. Development scripts are in `scripts/`; app bundle assets are in `app/` and `assets/`.

## Build, Test, and Development Commands

Use the package manifest in `Package.swift` as the source of truth.

- `swift build`: compile the app target.
- `make test SUITE="LLMRouterTests"` or `make test FILTER="LLMRouterTests/testMethod"`: run an explicit focused scope at final validation.
- `make test-plan SUITE="LLMRouterTests"`: build/discover and preview the scope without executing tests.
- `make test-unit`, `make test-integration`, or `make test-ui`: explicitly select a broader resource group when the change warrants it; see `docs/TESTING.md`.
- `make test-full REASON="..."`: explicitly request full validation after announcing why it is needed. Never run unfiltered `swift test` proactively.
- `make test-groups`: audit discovery and inspect group membership. `make test-scripts` validates Python development scripts.
- `make test-screen-capture`: opt in to real desktop capture, with screen recording permission. Run it when changing native capture behavior; ordinary UI tests cover synthetic window policies.
- `scripts/setup_dev_cert.sh` **(run once)**: create a local self-signed code-signing identity ("Typeflux Dev") in a dedicated passwordless keychain. Required for stable macOS privacy permission grants (microphone, accessibility) across rebuilds.
- `make run`: build, bundle, and launch `~/Applications/Typeflux Dev.app`.
- `make dev`: launch the dev app with terminal logs attached.
- `make coverage SUITE="LLMRouterTests"`: collect focused coverage instead of a duplicate plain test run; HTML goes to `coverage-report/`.
- `make format`: format code via `scripts/format.sh`.

## Coding Style & Naming Conventions

Follow existing Swift style in the repo: 4-space indentation, one top-level type per file when practical, and small focused extensions such as `WorkflowController+Processing.swift`, `+Persona.swift`, and `+AutomaticVocabulary.swift`. Add new concerns as similarly named extensions rather than expanding the core file. Use `UpperCamelCase` for types, `lowerCamelCase` for methods and properties, and descriptive enum cases like `.openAICompatible`. This is an internationalized project, so all code and code comments must be written in English. Prefer protocol-backed services and dependency injection through `DIContainer` instead of hard-coded singletons. SwiftLint is configured; use `// swiftlint:disable file_length` at the top of intentionally large files. Keep changes consistent with nearby code.

## Testing Guidelines

Add tests in `Tests/TypefluxTests` for logic, routing, parsing, and provider behavior. Match production names where possible, for example `LLMRouter.swift` with `LLMRouterTests.swift`. Keep test names behavior-focused, such as `testCompleteRoutesToOpenAI`. All new and modified code must include sufficient unit tests, with a target of 90% unit test coverage for the changed code. Complete focused validation before opening a PR; coverage must use the same relevant scope and replace the plain test run. Follow the execution policy below. Swift Testing suites that host windows, send native events, switch or read `AppLocalization.shared` (including through `L()`), or otherwise run on the main actor must carry `.exclusiveUIState` (see `Tests/TypefluxTests/ExclusiveUIStateTrait.swift`); `.serialized` alone does not stop other suites from changing that shared state mid-test, and an `interface:` argument does not pin the language `L()` reads. `ExclusiveUIStateLanguageTests` audits this. Look up windows through the object that presented them, not by identifier alone, since windows from earlier tests can stay in `NSApp.windows`.

### Test Execution Policy for Agents

Follow this policy for the entire requested task, including tasks with multiple changes:

- Finish all requested implementation and self-review first, then perform one focused validation pass. Do not execute tests after each edit or subtask. Builds, discovery and `--plan` do not execute tests. A requested performance investigation may use a declared before/after comparison of the same focused scope.
- Choose suites/methods for every changed behavior, its directly affected callers and shared dependencies. Explain that mapping in the delivery. Resource groups are inventory aids, not automatic change-impact analysis; do not choose all UI tests for a single UI change.
- Use `make test SUITE="SuiteA SuiteB"`, `make test FILTER="regex"`, or repeated `--suite`/`--filter` options on `scripts/test_groups.py`. An empty or unmatched scope is an error, never a fallback to all tests.
- Do not proactively run full tests, full coverage or full UI/iOS validation. If full validation is warranted by a cross-cutting change or requested by the user, state the reason and scope before execution, then use `make test-full REASON="..."` or `make coverage-full REASON="..."`. A passing focused scope is sufficient for an ordinary PR; full validation is not a default PR gate.
- If validation fails, fix the cause and retry only failed methods or the smallest containing suite. For build/runner failures, retry the same focused command. Never retry the full suite to fix a failure.
- Coverage replaces the plain test pass for the same scope; do not run both. Report changed-code coverage separately from project-wide coverage.
- Use audited parallel phases from the runner. Unknown suites and shared UI/localization tests remain serial. Do not launch simultaneous local SwiftPM/UI runs against the same build directory or desktop. Review isolation when adding or changing a registered parallel suite, including its helpers and called production code.
- Report scope, results, build/discovery and execution costs, failed-test retries and any unverified behavior honestly.

## Commit & Pull Request Guidelines

Recent history favors short, imperative commit subjects such as `Fix compiler warning and 3 test failures` or `Merge pull request #5 ...`. Keep commits scoped and descriptive. PRs should explain user-visible impact, note any permission or provider setup changes, link related issues, and include screenshots when changing onboarding, settings, overlay, or menu bar UI.

## Security & Configuration Tips

Do not commit API keys, local model paths, or personal macOS signing identities. For local app stability, use the existing launch scripts and set `TYPEFLUX_DEV_CODESIGN_IDENTITY` only in your shell environment when needed.

### macOS Code Signing for Dev Builds

A stable code-signing identity prevents macOS from re-prompting for microphone/accessibility permissions on every rebuild. The recommended setup:

1. Run `scripts/setup_dev_cert.sh` once after cloning. It creates a self-signed "Typeflux Dev" cert in `~/Library/Keychains/typeflux-dev.keychain-db` (passwordless, project-local). No admin privileges are required.
2. `make run` auto-detects the "Typeflux Dev" identity and signs the dev app bundle.
3. Without the identity, the script falls back to ad-hoc signing — permissions will reset each time the binary's hash changes (i.e., every rebuild).

Overrides are available via environment variables:
- `TYPEFLUX_DEV_CODESIGN_IDENTITY` — force a specific signing identity (e.g., "Apple Development: user@example.com (...)")
- `TYPEFLUX_DEV_PROVISIONING_PROFILE` — path to a macOS provisioning profile for Sign In with Apple support
