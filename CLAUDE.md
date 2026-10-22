# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Typeflux** is a macOS menu bar voice input app (Swift, macOS 13+). It implements a "hold to talk, release to insert" workflow: hotkey → record audio → transcribe → inject text into the focused app. It also supports voice-driven text rewriting via LLM.

## Commands

```bash
# Build
swift build

# Final validation: run only changed behavior and affected dependencies
make test SUITE="LLMRouterTests"
make test FILTER="LLMRouterTests/testMethod"
make test-plan SUITE="LLMRouterTests" # discovery/selection, no test execution

# Full validation is opt-in; announce the reason before running
make test-full REASON="explicitly requested cross-feature regression check"

# Run a single test class
swift test --filter TypefluxTests.LLMRouterTests

# Broader scopes only when relevant; discovery and script-only checks
make test-unit         # tests without recognized UI/integration fixtures
make test-integration  # storage, network, process, and timer fixtures
make test-ui           # main actor and shared UI/localization state
make test-screen-capture # explicit native capture; needs screen recording access
make test-groups       # audit complete discovery and show assignments
make test-scripts      # Python development scripts; no Swift build

# Run a specific test method
swift test --filter TypefluxTests.LLMRouterTests/testMethodName

# Launch dev app (builds, bundles into ~/Applications/Typeflux Dev.app, opens)
make run

# Launch dev app with terminal logs attached (most useful for development)
make dev

# Focused coverage replaces plain validation; HTML in coverage-report/
make coverage SUITE="LLMRouterTests"

# Format code (runs scripts/format.sh)
make format
```

## Architecture

### Entry Points & Dependency Injection

- `main.swift` — app entry point
- `App/DIContainer.swift` — constructs and wires all services; the single source of truth for production instances
- `App/AppCoordinator.swift` — top-level app lifecycle coordinator

### Core Workflow

`Workflow/WorkflowController.swift` is the central orchestrator. It:
1. Listens for hotkey events from `HotkeyService`
2. Triggers audio recording via `AudioRecorder`
3. Routes transcription through `STTRouter` → appropriate `Transcriber`
4. Optionally rewrites via `LLMService`
5. Injects text via `TextInjector` (AX accessibility API) with clipboard fallback
6. Saves results to `HistoryStore`

`WorkflowController` is split into focused extension files to manage complexity: `+Processing.swift` for LLM rewrite/generation logic, `+Persona.swift` for persona handling, and `+AutomaticVocabulary.swift` for vocabulary monitoring. Add new concerns as similarly named extensions rather than expanding the core file.

### STT Layer (`Sources/Typeflux/STT/`)

`STTRouter` selects a `Transcriber` implementation based on settings:
- `WhisperAPITranscriber` — remote Whisper/OpenAI-compatible API
- `LocalModelTranscriber` + `WhisperKitTranscriber` — on-device via WhisperKit
- `AppleSpeechTranscriber` — Apple Speech framework (also used as fallback)
- `MultimodalLLMTranscriber` — vision-capable LLM for transcription
- `AliCloudRealtimeTranscriber`, `DoubaoRealtimeTranscriber` — realtime streaming ASR
- `FreeSTTTranscriber` — free model transcription
- `Qwen3ASRTranscriber`, `SenseVoiceTranscriber` — additional model implementations

`LiveTranscriptionPreviewer` handles streaming preview display during recording.

### LLM Layer (`Sources/Typeflux/LLM/`)

`LLMRouter` dispatches to `OpenAICompatibleLLMService` or `OllamaLLMService` based on settings.

**Chat** (`Ask/`): the Chat conversation window. Each conversation is kept in Typeflux Cloud or, as a private conversation, on this Mac with the user's own models (`Ask/Local/`); `AskConversationModel` routes every call per conversation (see `docs/ASK_CONVERSATIONS.md`). Local tools implement `AgentTool` (`LLM/Agent/AgentTool.swift`); `AskReasoningEffort` and `AskReasoningRequest` carry the user's reasoning choice, and Ask never sends "thinking off" parameters (only rewrite and transcription do).

**MCP Support** (`LLM/MCP/`): Model Context Protocol integration:
- `StdioMCPClient.swift` — local process transport
- `HTTPMCPClient.swift` — HTTP/SSE transport
- `MCPRegistry.swift` — manages configured MCP servers
- `MCPToolAdapter.swift` — adapts MCP tools to the `AgentTool` protocol used by Ask

### Data Storage

| Store | Implementation | Persistence |
|-------|---------------|-------------|
| History records | `SQLiteHistoryStore` (WAL mode) at `~/Library/Application Support/Typeflux/history.sqlite` | Persistent |
| Clipboard history | `SQLiteClipboardHistoryStore` at `~/Library/Application Support/Typeflux/clipboard.sqlite`; copied images as PNGs in `clipboard-images/` | Persistent |
| Settings | `SettingsStore` via `UserDefaults` (`com.typeflux.plist`) | Persistent |
| Vocabulary | `VocabularyStore` via `UserDefaults` | Persistent |
| Usage stats | `UsageStatsStore` via `UserDefaults` | Persistent |
| Audio files | Filesystem at `~/Library/Application Support/Typeflux/audio/` | Persistent |
| App state | `AppStateStore` in memory | Runtime only |
| Error logs | `ErrorLogStore` in memory (max 100 entries) | Runtime only |

`HistoryStore` is a protocol — `SQLiteHistoryStore` is the production implementation; `FileHistoryStore` is the legacy JSON implementation kept for migration.

History changes are broadcast via `NotificationCenter` using `.historyStoreDidChange`.

### UI Layer

- `Overlay/` — floating recording status overlay (shown during recording/processing)
- `UI/` — SwiftUI settings, history, and other windows
- `App/StatusBarController.swift` — menu bar item and menu
- `App/AskAnswerWindowController.swift` — floating window for agent Q&A results

### Other Modules

- `Hotkey/` — global hotkey capture via `EventTapHotkeyService` (CGEventTap for voice gestures; `SystemHotkeyPool` registers the plain key chords of feature and keyword shortcuts). Every shortcut is a `HotkeyTarget`; `HotkeyConflictChecker` is the one conflict check, and Settings → Shortcuts (`HotkeySettingsView`) lists them all
- `Audio/` — `AVFoundationAudioRecorder`, `AudioDeviceManager`, audio format handling
- `TextInjection/` — `AXTextInjector` uses Accessibility API; falls back to clipboard paste
- `Clipboard/` — system clipboard read/write, plus the clipboard panel opened by the history hotkey: `ClipboardMonitor` records copies into `ClipboardHistoryStore`, `ClipboardFeed` merges them with voice history, and `ClipboardPanelController` shows `ClipboardPanelModel` in a non-activating key panel. `ClipboardCaptureSuppression` keeps Typeflux's own selection probes out of the history.
- `BackgroundActivity/` — the menu bar's background tasks: `BackgroundActivityCenter` merges what each `BackgroundActivitySource` reports (speech model, content search and Ollama model downloads, the file name and content indexes, agent runs) for the task section at the top of the status menu and the background tasks window. The menu bar icon itself never changes with background work. New long-running work reports through a source rather than its own menu item
- `Settings/` — `SettingsStore` plus settings UI views
- `History/` — history models, stores, export
- `Stats/` — `UsageStatsStore` with backfill logic
- `Onboarding/` — first-launch permission flow
- `Privacy/` — `PrivacyGuard` for permission checks
- `Networking/` — `RequestRetry`, `NetworkDebugLogger`

### App Bundle Packaging

The app must run as a `.app` bundle (not a bare CLI binary) for macOS privacy permissions and menu bar behavior to work correctly. `scripts/run_dev_app.sh` builds the binary, assembles `~/Applications/Typeflux Dev.app`, code-signs it, and opens it. Set `TYPEFLUX_DEV_CODESIGN_IDENTITY` to a stable Apple Development identity to avoid repeated Accessibility permission prompts across rebuilds.

## Testing

Tests live in `Tests/TypefluxTests/`. The test target imports the main `Typeflux` executable target directly. All new and modified code must include sufficient unit tests, with a target of 90% unit test coverage for the changed code. Run `swift test --filter <TestClassName>` to run a subset. Use `@Sendable` closures with the `Recorder` actor pattern (see `RequestRetryTests`) for concurrency-safe test helpers. Swift Testing suites that host windows, send native events, switch or read `AppLocalization.shared` (including through `L()`), or otherwise run on the main actor must carry `.exclusiveUIState` (see `Tests/TypefluxTests/ExclusiveUIStateTrait.swift`); `.serialized` alone does not stop other suites from changing that shared state mid-test, and an `interface:` argument does not pin the language `L()` reads. `ExclusiveUIStateLanguageTests` audits this. Look up windows through the object that presented them, not by identifier alone, since windows from earlier tests can stay in `NSApp.windows`.

### Test Execution Policy for Agents

Follow this policy for the entire requested task, including tasks with multiple changes:

- Finish all requested implementation and self-review first, then perform one focused validation pass. Do not execute tests after each edit or subtask. Builds, discovery and `--plan` do not execute tests. A requested performance investigation may use a declared before/after comparison of the same focused scope.
- Choose suites/methods for every changed behavior, its directly affected callers and shared dependencies. Explain that mapping in the delivery. Resource groups are inventory aids, not automatic change-impact analysis; do not choose all UI tests for a single UI change.
- Use `make test SUITE="SuiteA SuiteB"`, `make test FILTER="regex"`, or repeated `--suite`/`--filter` options on `scripts/test_groups.py`. An empty or unmatched scope is an error, never a fallback to all tests.
- Do not proactively run full tests, full coverage or full UI/iOS validation. If full validation is warranted by a cross-cutting change or requested by the user, state the reason and scope before execution, then use `make test-full REASON="..."` or `make coverage-full REASON="..."`. A passing focused scope is sufficient for an ordinary PR; full validation is not a default PR gate.
- If validation fails, fix the cause and retry only failed methods or the smallest containing suite. For build/runner failures, retry the same focused command. Never retry the full suite to fix a failure.
- Coverage replaces the plain test pass for the same scope; do not run both. Report changed-code coverage separately from project-wide coverage.
- Use audited parallel phases from the runner. Unknown suites and shared UI/localization tests remain serial. Do not launch simultaneous local SwiftPM/UI runs against the same build directory or desktop. Review isolation when adding or changing a registered parallel suite, including its helpers and called production code.
- Use the normal runner first: it verifies reusable build/discovery metadata, never cached passing results. Known calculator, scroll, overlay and retry suites automatically use reviewed compact source closures. For method retries, retain the original `--profile`; use `--rebuild` to refresh metadata or `--swiftpm` for compatibility. Update a profile when its fixture dependencies change.
- Report total command wall time, including preparation, discovery, runner startup and execution; phase timings alone are insufficient. Separate first use/rebuild from verified cache hits, and report failed-test retries and unverified behavior honestly.

## Development Standards

- All code and code comments must be written in English (internationalized project).
- Follow existing Swift style: 4-space indentation, `UpperCamelCase` types, `lowerCamelCase` methods/properties, one top-level type per file when practical.
- Prefer protocol-backed services with dependency injection through `DIContainer` over singletons.
- SwiftLint is configured; use `// swiftlint:disable file_length` at the top of intentionally large files.
- Commit subjects should be short and imperative (e.g. `feat(ax): improve editable target detection`). PRs should note user-visible impact and include screenshots when changing overlay, settings, or menu bar UI.
