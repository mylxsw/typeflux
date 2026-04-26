<div align="center">

# Typeflux

**Talk. We'll Type.**

Press `Fn` and speak naturally. Typeflux delivers lightning-fast, accurate voice-to-text directly into any macOS application. Free, open-source, and supports local models — your voice never has to leave your Mac.

[![Tests](https://github.com/mylxsw/typeflux/actions/workflows/test.yml/badge.svg)](https://github.com/mylxsw/typeflux/actions/workflows/test.yml)
[![codecov](https://codecov.io/gh/mylxsw/typeflux/graph/badge.svg)](https://codecov.io/gh/mylxsw/typeflux)

![Typeflux demo](./assets/preview-1.png)

</div>

## Download

**[⬇ Download latest release (.dmg)](https://github.com/mylxsw/typeflux/releases/latest)**

1. Download `Typeflux.dmg` from the latest release
2. Open the DMG and drag `Typeflux.app` to **Applications**
3. Launch and grant Microphone + Accessibility permissions

> **macOS 13+** · Free · No subscription · Fully local inference supported

---

## Why Typeflux

Most voice input tools force you to switch apps — dictating in one place, then copying and pasting into another. That context switch breaks flow.

Typeflux injects text directly into whichever app you're already using, at the cursor position, the moment you release the hotkey. It feels like typing, just **4× faster** (~200 WPM vs. ~50 WPM).

And when you need more than dictation, **Voice Agent** turns your voice into an AI assistant for Q&A, rewriting, translation, and complex workflows.

---

## How It Works

```
Hold Fn → Speak → Release → Text appears instantly
```

1. **Press and hold** `Fn` (default hotkey)
2. **Speak naturally**
3. **Release** — Typeflux transcribes and injects the text at your cursor
4. The result is also copied to clipboard as a fallback

---

## Features

### One-Click Voice Input
Hold `Fn` to start, release to stop. No switching input methods, no clicking buttons — works in any text field across browsers, code editors, terminals, and native apps.

### Voice Agent (`Fn + Space`)
More than just dictation. Press `Fn + Space` to chat with an AI agent using your voice:

- **Voice Q&A** — Ask questions and get instant answers
- **Content Rewrite** — Select text, then speak an instruction like "make this shorter" or "translate to English"
- **Complex Workflows** — Handle multi-step tasks through natural conversation

### Local-First, Privacy-First
Run entirely on your Mac with on-device models. No API keys needed, no data leaves your machine. We don't collect, store, or analyze any of your voice or text data.

### Custom Personas
Create named instruction sets for different scenarios — work emails, study notes, casual chat, code comments — and switch between them from the menu bar.

### Multiple Speech Backends
| Provider | Type | Best For |
|----------|------|----------|
| Typeflux Cloud | Cloud | Zero-config, balanced accuracy |
| Local Model | Local | Privacy, offline use |
| Alibaba Cloud ASR | Cloud streaming | Low latency, Chinese |
| Doubao Realtime ASR | Cloud streaming | Chinese optimization |
| Google Speech-to-Text | Cloud | Multi-language, enterprise |
| OpenAI (Whisper API) | Cloud | High accuracy |
| Multimodal LLM | Cloud | Vision + audio tasks |
| Groq | Cloud | Fast inference, low cost |
| Free Models | Cloud | No API key, open-source endpoints |

### Local Models
When you choose **Local Model**, Typeflux downloads and runs the model entirely on your Mac:

| Model | Size | Params | Best For |
|-------|------|--------|----------|
| SenseVoice Small | ~350 MB | 234M | Fast multilingual, strong Chinese/Japanese/Korean |
| WhisperKit Medium | ~1.5 GB | 769M | Balanced English and multilingual dictation |
| WhisperKit Large | ~3 GB | 1.55B | Highest accuracy offline transcription |
| Qwen3-ASR | ~1.3 GB | 0.6B | Strong context understanding, long-form recognition |

### Streaming Preview
See partial transcription results while still speaking, so you get immediate feedback before you release.

### History & Replay
Every session is saved locally. Review past sessions, replay audio, retry transcription with different settings, or export records to Markdown.

---

## Requirements

- macOS 13 or later
- Microphone permission
- Accessibility permission (for text injection)

For cloud providers: API keys and endpoint URLs.  
For local inference: model files are downloaded automatically on first use.

---

## Build from Source

```bash
git clone https://github.com/mylxsw/typeflux
cd typeflux
make run          # build + launch as .app bundle
make dev          # launch with terminal logs attached
make full-dev     # launch dev app with bundled SenseVoice resources
make full-release # build the full notarized production installer locally
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

## Community

Join the community to share feedback, ask questions, and follow development updates:

- [Join Discord](https://discord.com/invite/Vr5389YrN)
- WeChat group:

  <img src="./assets/wechat-group-20260426.jpg" alt="Typeflux WeChat group QR code" width="260">

---

## Contributing

Typeflux is a completely open-source project. We believe great tools should belong to everyone.

Contributions welcome — STT provider integrations, overlay UX, settings views, text injection edge cases, or history/export features are great starting points.

1. Read the module layout in [CLAUDE.md](./CLAUDE.md)
2. Run the app locally with `make dev`
3. Add or update tests for any logic changes
4. Open a PR with a description of user-visible impact

---

## License

AGPL-3.0. See [LICENSE](./LICENSE).
