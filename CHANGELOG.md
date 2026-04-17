# Changelog

All notable changes to Typeflux will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-04-17

### Added

- Initial release of Typeflux, a macOS menu-bar voice input tool.
- Hold-to-talk workflow with a floating overlay and real-time status.
- Dictation mode: transcribe speech and insert text at the current cursor position.
- Editing mode: rewrite selected text using a voice instruction.
- Multiple STT backends: Apple Speech, Whisper API, OpenAI-compatible remote APIs, local WhisperKit, Alibaba Cloud realtime ASR, Doubao realtime ASR, and multimodal LLM transcription.
- Multiple LLM backends: OpenAI-compatible services and Ollama for local model serving.
- Streaming transcription previews for responsive feedback.
- Clipboard synchronization and automatic text injection with accessibility fallback.
- Session history with SQLite storage, audio replay, export to Markdown, and configurable retention policies.
- Settings UI for hotkeys, STT/LLM providers, personas, model options, and appearance preferences.
- Usage statistics and privacy-conscious local-first architecture.
- Onboarding flow for first-time users.
- Built-in agent loop with tool calling support and MCP client integration.
- Automatic vocabulary monitoring for per-app customization.

[1.0.0]: https://github.com/mylxsw/typeflux/releases/tag/v1.0.0
