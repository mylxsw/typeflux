# Typeflux Usage Guide

This document explains how to install, launch, configure, and use Typeflux in daily work.

For development and release commands, see [MAKE_COMMANDS.md](./MAKE_COMMANDS.md).

## What Typeflux Does

Typeflux is a macOS menu bar app for voice-first text input.

The normal interaction loop is:

1. Press and hold a hotkey.
2. Speak naturally.
3. Release the hotkey.
4. Wait for transcription or rewrite processing.
5. Let Typeflux insert the result into the focused app.

Typeflux supports both plain dictation and voice-driven rewriting of selected text.

## Requirements

- macOS 13 or later
- Microphone permission
- Accessibility permission for text insertion
- Speech Recognition permission when using Apple Speech or Apple fallback

Depending on your provider setup, you may also need:

- API keys for remote STT providers
- API keys or endpoint URLs for LLM providers
- local model files for local speech or local LLM backends

## Installation

### Install from a release build

1. Download the latest release artifact from the project release page.
2. Unzip `Typeflux.zip` or open `Typeflux.dmg`.
3. Drag `Typeflux.app` into `/Applications`.
4. Launch the app.

### Run from source during development

Use one of the development launch commands:

```bash
make run
```

or

```bash
make dev
```

`make run` launches the packaged development app.

`make dev` does the same, but keeps logs attached to the terminal, which is more convenient for debugging.

## First Launch Checklist

When Typeflux starts for the first time, make sure the following are configured:

1. Grant Microphone permission.
2. Grant Accessibility permission.
3. Grant Speech Recognition permission if your selected backend needs it.
4. Open Typeflux settings from the menu bar.
5. Choose your speech provider.
6. Configure your LLM provider if you want voice-based rewriting.
7. Set a hotkey that is comfortable to hold and release frequently.

## Core Usage Patterns

### Dictation Mode

Use this mode when you want to insert new text into the current app.

1. Put the cursor where text should be inserted.
2. Press and hold the Typeflux hotkey.
3. Speak your text.
4. Release the hotkey.
5. Wait for Typeflux to transcribe and insert the result.

If direct insertion fails, Typeflux also copies the result to the clipboard as a fallback.

### Voice Editing Mode

Use this mode when you want to transform existing text with speech.

1. Select text in the current app.
2. Press and hold the hotkey.
3. Speak an instruction such as "make this shorter" or "rewrite this in a more friendly tone".
4. Release the hotkey.
5. Wait for the rewritten result to be inserted.

This mode depends on an available LLM provider.

### Long Recording Mode

Typeflux also supports longer sessions through a locked recording flow. This is useful when holding a hotkey is inconvenient for extended speech input.

If you use longer recordings often, verify the selected speech backend can handle the expected audio length and latency.

## Common Settings

The most important settings for day-to-day use are:

- Hotkey
- Speech provider
- LLM provider
- Selected model
- Persona or rewrite behavior
- Clipboard fallback behavior
- History and retry preferences

Provider-related settings usually need to be configured only once unless you change vendors or rotate credentials.

## Permissions and macOS Behavior

Typeflux depends on macOS system permissions and app identity.

If something appears broken, check these first:

- Microphone access is enabled
- Accessibility access is enabled
- Speech Recognition access is enabled when needed
- the app is running as a bundled `.app`, not just as a bare binary

The development scripts in this repository intentionally wrap the app in a stable bundle so macOS permissions are less likely to reset between launches.

## Common Troubleshooting

### No text is inserted

Check:

- whether Accessibility permission is granted
- whether the target app allows accessibility-based input
- whether the text was copied to the clipboard as fallback

### Recording starts but no transcription appears

Check:

- whether the microphone is available
- whether the selected STT provider is configured correctly
- whether the provider credentials or endpoint are valid

### Voice editing does not work

Check:

- whether text is selected before you start speaking
- whether an LLM provider is configured
- whether the selected model and endpoint are reachable

### Permissions keep reappearing during development

Use `make run` or `make dev` instead of launching raw build output directly. Those commands package the app into a stable development bundle before launch.

## Release Usage

For notarized distribution builds, use the one-step release command:

```bash
make release-notarize
```

Before running it, export the required environment variables:

```bash
export APPLE_DISTRIBUTION="Developer ID Application: Your Name (TEAMID)"
export NOTARY_PROFILE="your-notarytool-profile"
make release-notarize
```

This command builds, signs, packages, notarizes, and staples the release artifacts automatically.

## Related Documentation

- [README.md](../README.md)
- [MAKE_COMMANDS.md](./MAKE_COMMANDS.md)
- [RELEASE.md](./RELEASE.md)
