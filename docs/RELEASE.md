# Typeflux Release Guide

This document explains how to build, sign, package, notarize, and distribute Typeflux for macOS.

For a command-by-command overview, see [MAKE_COMMANDS.md](./MAKE_COMMANDS.md).

## Recommended Release Path

The preferred release flow is the one-step notarized release command:

```bash
make release-notarize
```

This command automatically:

1. builds the release app bundle
2. signs the app with hardened runtime
3. creates the ZIP archive
4. creates and signs the DMG
5. submits the DMG to Apple notarization
6. waits for notarization to complete
7. staples the notarization ticket to both the app and the DMG
8. validates the stapled artifacts

## Prerequisites

- macOS 13 or later
- Xcode with Swift 5.9+ tooling
- `create-dmg`
- a valid Developer ID Application certificate
- a configured `notarytool` keychain profile

Install `create-dmg` with:

```bash
brew install create-dmg
```

## Required Environment Variables

Before running the one-step release command, export:

```bash
export APPLE_DISTRIBUTION="Developer ID Application: Your Name (TEAMID)"
export NOTARY_PROFILE="your-notarytool-profile"
```

Optional overrides:

```bash
export CODESIGN_IDENTITY="$APPLE_DISTRIBUTION"
export NOTARY_SUBMIT_RETRIES=3
export NOTARY_POLL_INTERVAL_SECONDS=15
```

Notes:

- `CODESIGN_IDENTITY` takes priority over `APPLE_DISTRIBUTION`
- the release script retries transient notarization submission failures
- if Apple returns a submission ID and the local client times out afterward, the script continues tracking that submission instead of restarting blindly

## One-Step Notarized Release

Run:

```bash
make release-notarize
```

Successful output artifacts:

- `.build/release/Typeflux.app`
- `.build/release/Typeflux.zip`
- `.build/release/Typeflux.dmg`

## Manual Release Steps

If you need more control, you can still run the steps individually.

### Build the release app

```bash
make release
```

Outputs:

- `.build/release/Typeflux.app`
- `.build/release/Typeflux.zip`

### Build the DMG

```bash
make dmg
```

Output:

- `.build/release/Typeflux.dmg`

### Submit to notarization manually

```bash
xcrun notarytool submit .build/release/Typeflux.dmg \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait
```

### Staple manually

```bash
xcrun stapler staple .build/release/Typeflux.app
xcrun stapler staple .build/release/Typeflux.dmg
```

## Distribution

You can distribute the final artifacts through:

- GitHub Releases
- direct download from a website or CDN
- an optional Homebrew Cask

If you publish a release manually, prefer attaching both:

- `Typeflux.dmg`
- `Typeflux.zip`

## Release Checklist

- [ ] Version updated in `app/Info.plist`
- [ ] `CHANGELOG.md` updated
- [ ] `swift test` passes
- [ ] `make release-notarize` completes successfully
- [ ] `Typeflux.dmg` is tested on a clean macOS machine
- [ ] Release artifacts are uploaded to the chosen distribution channel
- [ ] Release notes are published

## Troubleshooting

### Notarization returns `Invalid`

First fetch the Apple log:

```bash
xcrun notarytool log <submission-id> --keychain-profile "$NOTARY_PROFILE"
```

Common causes:

- hardened runtime was not enabled on the app executable
- the app or DMG was signed incorrectly
- a nested binary or framework was left unsigned

### Notary submission times out

The one-step release script already retries submission failures and keeps tracking a submission if Apple already issued an ID.

If you need to inspect the queue manually:

```bash
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE"
xcrun notarytool info <submission-id> --keychain-profile "$NOTARY_PROFILE"
```
