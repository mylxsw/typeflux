# Repository Guidelines

## Project Structure & Module Organization

`Typeflux` is a Swift Package Manager macOS app. Main code lives in `Sources/Typeflux`, grouped by feature: `App/` for startup and DI, `Workflow/` for the voice-input pipeline, `STT/` and `LLM/` for provider integrations, `Settings/`, `Audio/`, `Hotkey/`, `History/`, and `UI/` for supporting modules. App resources and localizations live under `Sources/Typeflux/Resources`. Tests are in `Tests/TypefluxTests`, typically mirroring production types with `*Tests.swift` names. Development scripts are in `scripts/`; app bundle assets are in `app/` and `assets/`.

## Build, Test, and Development Commands

Use the package manifest in `Package.swift` as the source of truth.

- `swift build`: compile the app target.
- `swift test` or `make test`: run the full test suite.
- `swift test --filter TypefluxTests.LLMRouterTests`: run one test class.
- `make run`: build, bundle, and launch `~/Applications/Typeflux Dev.app`.
- `make dev`: launch the dev app with terminal logs attached.
- `make coverage`: run coverage and write HTML output to `coverage-report/`.
- `make format`: format code via `scripts/format.sh`.

## Coding Style & Naming Conventions

Follow existing Swift style in the repo: 4-space indentation, one top-level type per file when practical, and small focused extensions such as `WorkflowController+Agent.swift`, `+Processing.swift`, `+Persona.swift`, and `+AutomaticVocabulary.swift`. Add new concerns as similarly named extensions rather than expanding the core file. Use `UpperCamelCase` for types, `lowerCamelCase` for methods and properties, and descriptive enum cases like `.openAICompatible`. This is an internationalized project, so all code and code comments must be written in English. Prefer protocol-backed services and dependency injection through `DIContainer` instead of hard-coded singletons. SwiftLint is configured; use `// swiftlint:disable file_length` at the top of intentionally large files. Keep changes consistent with nearby code.

## Testing Guidelines

Add tests in `Tests/TypefluxTests` for logic, routing, parsing, and provider behavior. Match production names where possible, for example `LLMRouter.swift` with `LLMRouterTests.swift`. Keep test names behavior-focused, such as `testCompleteRoutesToOpenAI`. All new and modified code must include sufficient unit tests, with a target of 90% unit test coverage. Run `swift test` before opening a PR; run `make coverage` for larger changes that touch core workflow paths.

## Commit & Pull Request Guidelines

Recent history favors short, imperative commit subjects such as `Fix compiler warning and 3 test failures` or `Merge pull request #5 ...`. Keep commits scoped and descriptive. PRs should explain user-visible impact, note any permission or provider setup changes, link related issues, and include screenshots when changing onboarding, settings, overlay, or menu bar UI.

## Security & Configuration Tips

Do not commit API keys, local model paths, or personal macOS signing identities. For local app stability, use the existing launch scripts and set `TYPEFLUX_DEV_CODESIGN_IDENTITY` only in your shell environment when needed.
