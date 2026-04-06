# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Typeflux** is a macOS menu bar voice input app (Swift, macOS 13+). It implements a "hold to talk, release to insert" workflow: hotkey → record audio → transcribe → inject text into the focused app. It also supports voice-driven text rewriting via LLM.

## Commands

```bash
# Build
swift build

# Run all tests
swift test
# or
make test

# Run a single test class
swift test --filter TypefluxTests.LLMRouterTests

# Run a specific test method
swift test --filter TypefluxTests.LLMRouterTests/testMethodName

# Launch dev app (builds, bundles into ~/Applications/Typeflux Dev.app, opens)
make run

# Launch dev app with terminal logs attached (most useful for development)
make dev

# Generate code coverage report (HTML output in coverage-report/)
make coverage

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
4. Optionally rewrites via `LLMService` or runs `AgentWorkflowRunner`
5. Injects text via `TextInjector` (AX accessibility API) with clipboard fallback
6. Saves results to `HistoryStore`

`WorkflowController` is split into focused extension files to manage complexity: `+Agent.swift` for the ask/answer mode, `+Processing.swift` for LLM rewrite/generation logic, `+Persona.swift` for persona handling, and `+AutomaticVocabulary.swift` for vocabulary monitoring. Add new concerns as similarly named extensions rather than expanding the core file.

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

**Agent Framework** (`LLM/Agent/`): A multi-turn agentic loop used for the "ask answer" voice Q&A feature:
- `AgentLoop.swift` — core execution engine, iterates up to `maxSteps` (default 10)
- `AgentToolRegistry.swift` — actor-based tool registry
- `AgentSkillRegistry.swift` — higher-level skill registry
- `BuiltinAgentTools.swift` / `BuiltinTools.swift` — built-in tool implementations
- `AgentToolCallMonitor.swift` — records intermediate steps for UI display

**MCP Support** (`LLM/MCP/`): Model Context Protocol integration:
- `StdioMCPClient.swift` — local process transport
- `HTTPMCPClient.swift` — HTTP/SSE transport
- `MCPRegistry.swift` — manages configured MCP servers
- `MCPToolAdapter.swift` — adapts MCP tools to the `AgentTool` protocol

### Data Storage

| Store | Implementation | Persistence |
|-------|---------------|-------------|
| History records | `SQLiteHistoryStore` (WAL mode) at `~/Library/Application Support/Typeflux/history.sqlite` | Persistent |
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

- `Hotkey/` — global hotkey capture via `EventTapHotkeyService` (CGEventTap)
- `Audio/` — `AVFoundationAudioRecorder`, `AudioDeviceManager`, audio format handling
- `TextInjection/` — `AXTextInjector` uses Accessibility API; falls back to clipboard paste
- `Clipboard/` — system clipboard read/write
- `Settings/` — `SettingsStore` plus settings UI views
- `History/` — history models, stores, export
- `Stats/` — `UsageStatsStore` with backfill logic
- `Onboarding/` — first-launch permission flow
- `Privacy/` — `PrivacyGuard` for permission checks
- `Networking/` — `RequestRetry`, `NetworkDebugLogger`

### App Bundle Packaging

The app must run as a `.app` bundle (not a bare CLI binary) for macOS privacy permissions and menu bar behavior to work correctly. `scripts/run_dev_app.sh` builds the binary, assembles `~/Applications/Typeflux Dev.app`, code-signs it, and opens it. Set `DEV_CODESIGN_IDENTITY` to a stable Apple Development identity to avoid repeated Accessibility permission prompts across rebuilds.

## Testing

Tests live in `Tests/TypefluxTests/`. The test target imports the main `Typeflux` executable target directly. All new and modified code must include sufficient unit tests, with a target of 90% unit test coverage. Run `swift test --filter <TestClassName>` to run a subset. Use `@Sendable` closures with the `Recorder` actor pattern (see `RequestRetryTests`) for concurrency-safe test helpers.

## Development Standards

- All code and code comments must be written in English (internationalized project).
- Follow existing Swift style: 4-space indentation, `UpperCamelCase` types, `lowerCamelCase` methods/properties, one top-level type per file when practical.
- Prefer protocol-backed services with dependency injection through `DIContainer` over singletons.
- SwiftLint is configured; use `// swiftlint:disable file_length` at the top of intentionally large files.
- Commit subjects should be short and imperative (e.g. `feat(ax): improve editable target detection`). PRs should note user-visible impact and include screenshots when changing overlay, settings, or menu bar UI.
