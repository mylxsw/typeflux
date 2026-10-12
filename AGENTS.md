# Repository Guidelines

## Project Structure & Module Organization

`Typeflux` is a Swift Package Manager macOS app. Main code lives in `Sources/Typeflux`, grouped by feature: `App/` for startup and DI, `Workflow/` for the voice-input pipeline, `STT/` and `LLM/` for provider integrations, `Settings/`, `Audio/`, `Hotkey/`, `History/`, and `UI/` for supporting modules. App resources and localizations live under `Sources/Typeflux/Resources`. Tests are in `Tests/TypefluxTests`, typically mirroring production types with `*Tests.swift` names. Development scripts are in `scripts/`; app bundle assets are in `app/` and `assets/`.

## Build, Test, and Development Commands

Use the package manifest in `Package.swift` as the source of truth.

- `swift build`: compile the app target.
- `swift test` or `make test`: run the full test suite once at final validation, after all requested changes are complete.
- `swift test --filter TypefluxTests.LLMRouterTests`: run one test class.
- `scripts/setup_dev_cert.sh` **(run once)**: create a local self-signed code-signing identity ("Typeflux Dev") in a dedicated passwordless keychain. Required for stable macOS privacy permission grants (microphone, accessibility) across rebuilds.
- `make run`: build, bundle, and launch `~/Applications/Typeflux Dev.app`.
- `make dev`: launch the dev app with terminal logs attached.
- `make coverage`: run full-suite coverage at final validation and write HTML output to `coverage-report/`.
- `make format`: format code via `scripts/format.sh`.

## Coding Style & Naming Conventions

Follow existing Swift style in the repo: 4-space indentation, one top-level type per file when practical, and small focused extensions such as `WorkflowController+Processing.swift`, `+Persona.swift`, and `+AutomaticVocabulary.swift`. Add new concerns as similarly named extensions rather than expanding the core file. Use `UpperCamelCase` for types, `lowerCamelCase` for methods and properties, and descriptive enum cases like `.openAICompatible`. This is an internationalized project, so all code and code comments must be written in English. Prefer protocol-backed services and dependency injection through `DIContainer` instead of hard-coded singletons. SwiftLint is configured; use `// swiftlint:disable file_length` at the top of intentionally large files. Keep changes consistent with nearby code.

## Testing Guidelines

Add tests in `Tests/TypefluxTests` for logic, routing, parsing, and provider behavior. Match production names where possible, for example `LLMRouter.swift` with `LLMRouterTests.swift`. Keep test names behavior-focused, such as `testCompleteRoutesToOpenAI`. All new and modified code must include sufficient unit tests, with a target of 90% unit test coverage. Complete final full-suite validation before opening a PR; for larger changes that touch core workflow paths, use `make coverage` as that final run. Follow the test execution policy below during implementation and failure retries. Swift Testing suites that host windows, send native events, switch or read `AppLocalization.shared` (including through `L()`), or otherwise run on the main actor must carry `.exclusiveUIState` (see `Tests/TypefluxTests/ExclusiveUIStateTrait.swift`); `.serialized` alone does not stop other suites from changing that shared state mid-test, and an `interface:` argument does not pin the language `L()` reads. `ExclusiveUIStateLanguageTests` audits this. Look up windows through the object that presented them, not by identifier alone, since windows from earlier tests can stay in `NSApp.windows`.

### Test Execution Policy for Agents

The full test suite takes a long time. Follow this policy for the entire requested task, including tasks with multiple changes:

- During implementation, prefer focused tests for the changed behavior and directly affected dependencies. Use `swift test --filter <TestClassName>` or `swift test --filter <TestClassName>/<TestMethodName>`; do not run the full suite after each edit or subtask.
- If tests fail, fix the cause and rerun only the failed tests with `--filter`. If exact test selection is unavailable, rerun the smallest containing suite. Do not rerun the full suite to retry failures, including failures discovered in the final full run.
- If a run fails before tests execute (for example, a build or test-runner failure), fix the cause and retry the focused command. Do not switch to the full suite.
- Only after all requested changes are complete and focused checks pass, run one final full test suite (`swift test` or `make test`). Do not repeat the full suite merely to confirm a failed-test fix.
- Treat full-suite coverage runs (`make coverage`) as final validation too. When coverage is required, use that run as the final full test pass instead of also running a duplicate `swift test` or `make test` pass.
- Report the focused checks, final full-suite result, and any failed-test retries separately. If full validation cannot finish, state the limitation clearly.

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
