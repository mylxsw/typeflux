<div align="center">

# [Typeflux](https://typeflux.app) — The open-source AI layer for your Mac

An AI agent that gets things done, a launcher, voice typing in any app, screenshots and screen recording, and clipboard history — all in one app, each one shortcut away. Free, open source, and works with local models.

[![Tests](https://github.com/mylxsw/typeflux/actions/workflows/test.yml/badge.svg)](https://github.com/mylxsw/typeflux/actions/workflows/test.yml)
[![codecov](https://codecov.io/gh/mylxsw/typeflux/graph/badge.svg)](https://codecov.io/gh/mylxsw/typeflux)

English | [简体中文](./README.zh-CN.md)

[![Watch the video](https://img.youtube.com/vi/ZxWWUOEgaJ4/maxresdefault.jpg)](https://youtu.be/ZxWWUOEgaJ4)

![product-image](./assets/product-image.png)

[View more screenshots](./docs/SCREENSHOTS.md)

</div>


## Download

**[⬇ Download latest release (.dmg)](https://github.com/mylxsw/typeflux/releases/latest)** · [Release notes](https://typeflux.app/releases)

1. Download `Typeflux.dmg` from the latest release (Apple silicon and Intel builds are available)
2. Open the DMG and drag `Typeflux.app` to **Applications**
3. Launch and grant the permissions you need (Microphone and Accessibility for voice typing; Screen Recording for screenshots)

> **macOS 13+** · Free · No account required to get started

## Why Typeflux

Asking an AI, finding a file, dictating a reply, grabbing a screenshot, pasting something you copied an hour ago — on most Macs these are five different apps. Typeflux puts them behind a handful of shortcuts, so you stay in whatever app you are already using.

It replaces a voice dictation app, a launcher, an AI chat app, a screenshot tool, a screen recorder, a clipboard manager and a translator.

## Four Ways In

| Entry | Default shortcut | What it does |
|-------|------------------|--------------|
| **Launcher** | `⌘ Space` | Find apps and files, run commands, get instant results, or ask AI |
| **AI Agent** | `⌘ Space`, type, then `⌘ ↩` | Hand off a question or a task; the agent can search, read, edit files and operate apps |
| **Voice Input** | Hold `Fn` | Speak, release, and the text appears at your cursor in any app |
| **Ring** | Hold `⌃ ⌥ Space` | A radial menu at the pointer — flick toward an action and release |

Every shortcut can be changed in **Settings → Shortcuts**. Other defaults: screenshot `⌥⌘A`, clipboard & history panel `⌥⌘O`.

## Features

Local files, including skills and conversation workspaces, live under
`~/.typeflux/`. See [local data directory](docs/DATA_DIRECTORY.md) for the
layout and upgrade behavior.

### AI Agent
More than chat — it can do the work for you:

- **Conversations** with history, attachments, screenshots, Mermaid diagrams and charts
- **Web search** with cited sources, and a **built-in browser** in the side panel that can read pages and fill forms
- **Files and commands** — read and write inside folders you grant, run terminal commands and scripts
- **Computer use** — look at the screen, click and type to operate other apps
- **Code** — run code, edit projects and preview the result
- **Image generation** through the image provider you configure
- **Memory and notes** — remembers your preferences and saves answers to the notebook
- **Skills** (installable from GitHub) and **MCP** servers for external tools and data
- **Permission modes** — *Strict* (approve every tool call), *Standard* (reads run automatically, changes ask first) or *Auto*

### Launcher
One input box for everything:

- Search files by name (with pinyin and path matching) and search inside PDFs, Markdown and text files (Apple silicon)
- Open, switch and quit apps; jump to open browser tabs and bookmarks (Safari, Chrome, Arc, Edge, Dia)
- Create Apple Notes and reminders with `note` / `remind`; search existing items with `notes` / `reminders`. Return previews, Esc returns to results, and ⌘O opens the original. Tab switches reminder scope.
- Run commands in a floating terminal, or hand them to Terminal / iTerm
- Instant results while you type: calculator, base conversion, translation, dates
- System controls and info: sleep, dark mode, Bluetooth, live system monitor, hardware details
- Built-in tools behind keywords: translation (multiple engines side by side), word book, calendar with holidays and lunar dates, world clock, notebook, emoji search
- Press `⌘ ↩` on anything to start an AI conversation

Window styles range from a Spotlight-like launcher to a slim search bar, inline quick answers, and a full workspace with history, web browsing and file previews.

### Voice Input
Hold the hotkey, speak naturally, release — the text is typed at the cursor in any app.

- **Edit by voice** — select text and say "make this shorter" or "translate to English" to replace it
- **Personas** — named instruction sets for different scenarios (work email, casual chat, code comments), each can have its own shortcut
- **Streaming preview** of partial results while you speak
- **History & replay** — review sessions, replay audio, retry with different settings, export to Markdown
- **Capsule styles** — bottom capsule, orb, top-corner card, or MacBook notch island

### Screenshots & Recording
- Region, window, full-screen and **scrolling** (long) screenshots
- Screen recording with system audio, microphone and camera picture-in-picture; pause and trim; export MP4 or **GIF**
- Annotate with arrows, shapes, step numbers and mosaic; auto-mask phone numbers; beautify backgrounds
- Pin to screen, screenshot to text (OCR), screenshot translation, ask AI about a screenshot

### Clipboard
- History of text, links, code, images and more, with full-text search and per-app filtering
- Retention from one day to forever; pin important items
- Snippets for frequently used text; `⌘1–9` to paste quickly

### Ring
Hold the ring shortcut and a radial menu opens at the pointer. Flick toward an action and release to run it; move back to the center to cancel. Up to 8 slots — defaults are voice input, chat, translate selection, screenshot, screenshot to text and clipboard history.

### Make It Yours
- **Workflows** — your own scripts behind launcher keywords, in Python, Node, TypeScript, shell, AppleScript or any program; output can use the Alfred Script Filter JSON format
- **Let AI write one** — describe the tool you want; the agent writes, tests and saves it
- **Workflow gallery** — ready-made tools such as timestamp conversion, JSON formatting and QR codes
- **Custom AI commands** — turn a prompt into a keyword (e.g. `rw` to polish, `sum` to summarize)
- **Keyword hotkeys** — bind a global shortcut to any keyword

### Models: Local or Cloud, Your Choice

**Speech recognition**

| Provider | Type | Best For |
|----------|------|----------|
| Local Model | Local | Privacy, offline use (default) |
| Typeflux Cloud | Cloud streaming | Zero-config, 60+ languages |
| Free Models | Cloud | No API key, open-source endpoints |
| Soniox | Cloud streaming | Multi-language realtime |
| Alibaba Cloud ASR | Cloud streaming | Low latency, Chinese |
| Doubao Realtime ASR | Cloud streaming | Chinese optimization |
| Google Speech-to-Text | Cloud | Multi-language, enterprise |
| OpenAI (Whisper API) | Cloud | High accuracy |
| Multimodal LLM | Cloud | Audio-capable LLMs |
| Groq | Cloud | Fast inference, low cost |

When you choose **Local Model**, Typeflux downloads and runs the model entirely on your Mac:

| Model | Size | Params | Best For |
|-------|------|--------|----------|
| SenseVoice | ~350 MB | 234M | Fast multilingual, strong Mandarin/Cantonese/English/Japanese/Korean |
| FunASR (Paraformer) | ~180 MB | 220M | Fast, accurate Chinese-focused offline ASR |
| WhisperKit Medium | ~1.5 GB | 769M | Balanced English and multilingual dictation |
| WhisperKit Large | ~3 GB | 1.55B | Highest accuracy offline transcription |
| Qwen3-ASR | ~1.3 GB | 0.6B | Strong context understanding, long-form recognition |

**Language models** — use Typeflux Cloud, or bring your own: OpenAI-compatible Chat Completions, Anthropic Messages, OpenAI Responses, or Ollama.

In **Settings → Models → Add Endpoint**, choose **Chat Completions**, **Anthropic Messages**, or **Responses**, then enter the endpoint, API key, and model ID. The protocol is saved with the provider and used for model discovery, connection tests, rewrite, and Chat, including streamed replies and tools. Existing custom providers keep Chat Completions until you change their protocol.

You can enter a base URL such as `https://api.example.com/v1` or a full inference URL. Typeflux preserves gateway path prefixes when selecting `/models`, `/messages`, `/responses`, or `/chat/completions`. Model discovery depends on the gateway exposing a compatible `/models` endpoint; otherwise add model IDs manually.

![Custom provider protocol selector](docs/screenshots/add-model-protocol.png)

### Privacy
- Local speech models run offline — your voice never has to leave your Mac
- Private conversations are stored only on this Mac (remote models still receive the content you send them)
- By default the agent asks before changing files or running commands, and is limited to folders you grant
- Fully open source under AGPL-3.0

### iPhone (coming soon)
An iOS Chat client lives in `Apps/iOS`: continue conversations, use voice input, and use Typeflux Cloud or your own models. See [iOS Chat Client](./docs/IOS_CHAT.md).

## Requirements

- macOS 13 or later (Apple silicon or Intel)
- Microphone and Accessibility permissions for voice typing and text insertion
- Screen Recording permission for screenshots, recording and computer use

For cloud providers: API keys and endpoint URLs, or a Typeflux Cloud account.

For local inference: model files are downloaded automatically on first use.

## Build from Source

```bash
git clone https://github.com/mylxsw/typeflux
cd typeflux

# One-time setup: create a local code-signing identity so macOS
# permissions (microphone, accessibility) persist across rebuilds.
scripts/setup_dev_cert.sh

make run          # build + launch as .app bundle
make dev          # launch with terminal logs attached
make dev-macbook  # use the MacBook API at mac-pro.local:8080
make dev-macmini  # use the Mac mini API at mac-mini.local:8080
make dev-macbook PLATFORM=ios # choose an iOS device/simulator and use the MacBook API
make dev-macmini PLATFORM=ios # choose an iOS device/simulator and use the Mac mini API
make full-dev     # launch dev app with bundled SenseVoice resources
make full-release # build the full notarized production installer locally
make release-continue # resume an interrupted local release
swift test        # run tests
```

The macOS `make run` and `make dev` commands build with optimizations by default,
while retaining development-only commands and defaults. For an unoptimized build
when debugging, use `TYPEFLUX_DEV_BUILD_CONFIGURATION=debug make run` (or `make dev`).

The Mac LAN targets select a single API endpoint even when `TYPEFLUX_API_URLS`
is inherited from the shell. Realtime ASR addresses are supplied by the selected
API, not by the app Makefile. Set `REALTIME_ASR_SERVER_ORIGINS` in each API's
environment to `http://mac-pro.local:8081` (MacBook) or
`http://mac-mini.local:8081` (Mac mini), then restart that API service.
Clients must be on a network that can resolve these names and reach both ports.
Do not advertise `127.0.0.1` to clients on other devices.
These targets default to `PLATFORM=macos`. With `PLATFORM=ios`, they list paired
iPhones/iPads and available simulators for selection; `DEVICE=<UDID>` skips the
prompt. Simulator launches need no developer team. Physical-device launches
automatically use the Xcode project's team or an available Apple Development
certificate; multiple certificate teams prompt for selection. Set
`TYPEFLUX_IOS_TEAM` to override the team. Local HTTP is enabled
only for the iOS Debug build. See [the iOS quickstart](docs/IOS_QUICKSTART.zh-CN.md).

CI tests are opt-in. On an open pull request, a repository owner, member, or
collaborator can comment `@autotest` to run the test workflow.

> ⚠️ If you skip `setup_dev_cert.sh`, `make run` still works but macOS will re-prompt for permissions on each build (ad-hoc signing).

See [CLAUDE.md](./CLAUDE.md) for the full development guide.

### Run the iOS Chat app

With full Xcode 26+ and an iOS Simulator runtime installed, run from the repository root:

```sh
make ios-doctor   # check the Xcode and simulator environment
make ios-run      # build, install, and launch in Simulator
make ios-preview  # launch an offline UI preview without an account
```

For a paired iPhone with development signing configured:

```sh
TYPEFLUX_IOS_DEVICE='<device-UDID>' TYPEFLUX_IOS_TEAM='<TEAMID>' make ios-deploy
```

The iOS app requires iOS 17+. See the [iOS run, installation, and deployment guide (中文)](./docs/IOS_QUICKSTART.zh-CN.md) for first-time setup, signing, API environments, local archives, and troubleshooting. These commands install the client; they do not deploy the backend or publish to the App Store.

## Documentation

- [iOS Run, Installation, and Deployment (中文)](./docs/IOS_QUICKSTART.zh-CN.md)
- [iOS Chat Client: Architecture and Development](./docs/IOS_CHAT.md)
- [Usage Guide](./docs/USAGE.md)
- [Make Commands](./docs/MAKE_COMMANDS.md)
- [Release Guide](./docs/RELEASE.md)
- [Release Notes](https://typeflux.app/releases)

## Community

Join the community to share feedback, ask questions, and follow development updates:

- [Join Discord](https://discord.com/invite/Vr5389YrN)
- [X](https://x.com/mylxsw)
- WeChat group:

  <img src="./assets/wechat-group-20260527.jpg" alt="Typeflux WeChat group QR code" width="260">

## Contributing

Typeflux is a completely open-source project. We believe great tools should belong to everyone.

Contributions welcome — agent tools, launcher plugins and workflows, speech providers, screenshot and recording tools, text insertion edge cases, and localization are all great starting points.

1. Read the module layout in [CLAUDE.md](./CLAUDE.md)
2. Run the app locally with `make dev`
3. Add or update tests for any logic changes
4. Open a PR with a description of user-visible impact

## License

AGPL-3.0. See [LICENSE](./LICENSE).
