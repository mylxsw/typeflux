# Typeflux

**Voice input for any macOS app — hold to talk, release to insert.**

[![Tests](https://github.com/mylxsw/typeflux/actions/workflows/test.yml/badge.svg)](https://github.com/mylxsw/typeflux/actions/workflows/test.yml)
[![codecov](https://codecov.io/gh/mylxsw/typeflux/graph/badge.svg)](https://codecov.io/gh/mylxsw/typeflux)
[![Release](https://img.shields.io/github/v/release/mylxsw/typeflux)](https://github.com/mylxsw/typeflux/releases/latest)
[![Stars](https://img.shields.io/github/stars/mylxsw/typeflux?style=social)](https://github.com/mylxsw/typeflux/stargazers)

Typeflux is a macOS menu bar app that lets you speak into any text field — email, code editor, terminal, browser — without switching apps or changing your workflow. Press a hotkey, talk, release, and your words appear at the cursor.

![Typeflux demo](./assets/preview-1.png)

## Download

**[⬇ Download latest release (.app)](https://github.com/mylxsw/typeflux/releases/latest)**

1. Download `Typeflux.zip` from the latest release
2. Unzip and drag `Typeflux.app` to **Applications**
3. Launch and grant Microphone + Accessibility permissions

> macOS 13+. No subscription. Fully local inference supported (no API keys required).

---

## Why Typeflux

Most voice input tools are separate apps. You dictate, copy the result, and paste it elsewhere. That context switch breaks flow.

Typeflux injects text directly into whichever app you're already using — at the cursor position — the moment you release the hotkey. It feels like typing, just faster.

It also handles the editing case: **select existing text, speak an instruction** ("make this shorter", "translate to English"), and the selection is rewritten in place using an LLM.

---

## How It Works

```
Hold hotkey → Speak → Release → Text appears in focused app
```

1. Press and hold your configured hotkey (default: `Option + Space`)
2. Speak naturally
3. Release — Typeflux transcribes and injects the text at your cursor
4. The result is also copied to clipboard as a fallback

---

## Features

### Voice Dictation
Insert transcribed speech into any macOS app via the Accessibility API. Works in browsers, code editors, terminals, Electron apps, and native apps — anywhere a text cursor exists.

### Voice Editing
Select text first, then speak an instruction. Typeflux sends the selection + your instruction to an LLM and replaces it with the rewritten result. No copy-paste needed.

### Local-First, Privacy-Friendly
Run entirely on your Mac with **WhisperKit** (on-device Whisper inference) and **Ollama** (local LLM). No API keys, no data leaving your machine.

### Multiple Speech Backends
| Backend | Type | Best for |
|---------|------|----------|
| Apple Speech | Built-in | Quick setup, fast |
| Whisper API / OpenAI-compatible | Cloud | High accuracy |
| WhisperKit | Local | Privacy, M-series Macs |
| Alibaba Cloud Realtime ASR | Cloud streaming | Low latency |
| Doubao Realtime ASR | Cloud streaming | Chinese optimization |
| Multimodal LLM | Cloud | Specialized use cases |

### Streaming Preview
See partial transcription results while still speaking, so you get immediate feedback before you release.

### Persona System
Create named instruction sets (personas) for different workflows — formal writing, code comments, quick notes, specific languages — and switch between them from the menu bar.

### History & Replay
Every session is saved locally. Review past sessions, replay audio, retry transcription with different settings, or export records to Markdown.

---

## Requirements

- macOS 13 or later
- Microphone permission
- Accessibility permission (for text injection)
- Speech Recognition permission (when using Apple Speech)

For cloud providers: API keys and endpoint URLs. For local inference: model files downloaded on first use.

---

## Build from Source

```bash
git clone https://github.com/mylxsw/typeflux
cd typeflux
make run          # build + launch as .app bundle
make dev          # launch with terminal logs attached
swift test        # run tests
```

See [CLAUDE.md](./CLAUDE.md) for the full development guide.

---

## Documentation

- [Usage Guide](./docs/USAGE.md)
- [Make Commands](./docs/MAKE_COMMANDS.md)
- [Release Guide](./docs/RELEASE.md)
- [Changelog](./CHANGELOG.md)

---

## Contributing

Contributions welcome. Good starting points: STT provider integrations, overlay UX, settings views, text injection edge cases, or history/export features.

1. Read the module layout in [CLAUDE.md](./CLAUDE.md)
2. Run the app locally with `make dev`
3. Add or update tests for any logic changes
4. Open a PR with a description of user-visible impact

---

## License

GPL-3.0. See [LICENSE](./LICENSE).
