# Typeflux Release Guide

This document explains how to build, sign, package, notarize, and distribute Typeflux for macOS.

For a command-by-command overview, see [MAKE_COMMANDS.md](./MAKE_COMMANDS.md).

## Recommended Release Path

For official GitHub releases, publish a GitHub Release. The `Release` workflow
then builds the macOS app, signs it with a Developer ID Application certificate,
notarizes it with Apple, packages it into a DMG, and uploads `Typeflux.dmg` and
`Typeflux.zip` as release assets.

For local release validation, use the one-step notarized release command:

```bash
make release-notarize
```

## GitHub Actions Release Workflow

The workflow in `.github/workflows/release.yml` runs when a GitHub Release is
published. It requires the repository secrets below.

### Required GitHub Actions Secrets

| Secret | What it is | Format |
| --- | --- | --- |
| `APPLE_CERTIFICATE_BASE64` | Base64-encoded `.p12` export of the Developer ID Application certificate and private key used for macOS distribution signing. | Single-line base64 text |
| `APPLE_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` certificate from Keychain Access. | Plain secret value |
| `APPLE_TEAM_ID` | Apple Developer Team ID for the account that owns the certificate and notarization credentials. | 10-character team ID |
| `CODESIGN_IDENTITY` | Exact signing identity name used by `codesign` (mapped into the workflow as `TYPEFLUX_CODESIGN_IDENTITY`). | `Developer ID Application: Name (TEAMID)` |
| `NOTARYTOOL_APPLE_ID` | Apple ID email address used for notarization. | Apple ID email |
| `NOTARYTOOL_PASSWORD` | App-specific password for the Apple ID used by `notarytool`. | App-specific password |

### Creating the Certificate Secret

1. In Apple Developer, open **Certificates, Identifiers & Profiles**.
2. Create or select a **Developer ID Application** certificate for the target team.
3. Install the certificate on a trusted Mac so it appears in Keychain Access with
   its private key.
4. In Keychain Access, select the certificate and private key together.
5. Choose **File > Export Items...** and save as `developer-id-application.p12`.
6. Set a strong export password. Save this password as
   `APPLE_CERTIFICATE_PASSWORD`.
7. Encode the `.p12` file:

```bash
base64 -i developer-id-application.p12 | pbcopy
```

8. Save the copied single-line value as `APPLE_CERTIFICATE_BASE64`.

### Finding the Signing Identity

On the Mac that has the certificate installed, run:

```bash
security find-identity -v -p codesigning
```

Copy the exact Developer ID Application identity, for example:

```text
Developer ID Application: Example Company, Inc. (ABCDE12345)
```

Save that value as the `CODESIGN_IDENTITY` repository secret. The workflow exposes it to the build scripts as `TYPEFLUX_CODESIGN_IDENTITY`.

### Creating Notarization Credentials

1. Confirm the Apple account has access to the same Apple Developer team.
2. Find the team ID in Apple Developer under **Membership details**. Save it as
   `APPLE_TEAM_ID`.
3. Create an app-specific password at
   `https://account.apple.com/account/manage`.
4. Save the Apple ID email as `NOTARYTOOL_APPLE_ID`.
5. Save the app-specific password as `NOTARYTOOL_PASSWORD`.

The workflow stores those credentials in a temporary runner keychain profile
named `typeflux-release` before calling `scripts/release_notarize.sh`.
The temporary keychain password is generated inside the workflow run and does
not need to be configured as a repository secret.

## Local Release Path

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
export TYPEFLUX_APPLE_DISTRIBUTION="Developer ID Application: Your Name (TEAMID)"
export TYPEFLUX_NOTARY_PROFILE="your-notarytool-profile"
```

Optional overrides:

```bash
export TYPEFLUX_CODESIGN_IDENTITY="$TYPEFLUX_APPLE_DISTRIBUTION"
export TYPEFLUX_NOTARY_SUBMIT_RETRIES=3
export TYPEFLUX_NOTARY_POLL_INTERVAL_SECONDS=15
export TYPEFLUX_NOTARY_KEYCHAIN="/path/to/custom.keychain-db"
```

Notes:

- `TYPEFLUX_CODESIGN_IDENTITY` takes priority over `TYPEFLUX_APPLE_DISTRIBUTION`
- `TYPEFLUX_NOTARY_KEYCHAIN` is optional and only needed when the notary profile lives in
  a non-default keychain
- the release script retries transient notarization submission failures
- if Apple returns a submission ID and the local client times out afterward, the script continues tracking that submission instead of restarting blindly
- see [BUILD_CONFIGURATION.md](./BUILD_CONFIGURATION.md) for the full step-by-step setup of certificates, Developer IDs, provisioning profiles, and notarization credentials

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
  --keychain-profile "$TYPEFLUX_NOTARY_PROFILE" \
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
xcrun notarytool log <submission-id> --keychain-profile "$TYPEFLUX_NOTARY_PROFILE"
```

Common causes:

- hardened runtime was not enabled on the app executable
- the app or DMG was signed incorrectly
- a nested binary or framework was left unsigned

### Notary submission times out

The one-step release script already retries submission failures and keeps tracking a submission if Apple already issued an ID.

If you need to inspect the queue manually:

```bash
xcrun notarytool history --keychain-profile "$TYPEFLUX_NOTARY_PROFILE"
xcrun notarytool info <submission-id> --keychain-profile "$TYPEFLUX_NOTARY_PROFILE"
```
