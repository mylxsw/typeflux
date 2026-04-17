# Typeflux Release Guide

This document explains how to build, sign, package, and distribute Typeflux as a macOS `.app` bundle using a DMG installer.

---

## Prerequisites

- macOS 13 or later
- Xcode with Swift 5.9+ toolchain
- A valid Apple Developer ID certificate for notarized distribution (recommended)
- `create-dmg` installed (see installation below)

### Install `create-dmg`

\`\`\`bash
brew install create-dmg
\`\`\`

---

## 1. Build the Release App Bundle

Use the provided release script to build a production-ready `.app` bundle:

\`\`\`bash
make release
\`\`\`

Or run the script directly:

\`\`\`bash
./scripts/build_release.sh
\`\`\`

Output:
- `.build/release/Typeflux.app` — the signed app bundle
- `.build/release/Typeflux.zip` — a ZIP archive for quick distribution

### Code Signing

The release script will automatically sign the bundle if a signing identity is available.

- **Ad-hoc signing** (local testing): the script signs with `-` automatically.
- **Developer ID signing** (distribution): export your identity before building:

\`\`\`bash
export CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
make release
\`\`\`

---

## 2. Create a DMG Installer

Run the DMG build script after the release app bundle is ready:

\`\`\`bash
./scripts/build_dmg.sh
\`\`\`

Output:
- `.build/release/Typeflux.dmg` — the final distributable DMG

### What the DMG script does

1. Creates a temporary staging folder.
2. Copies the signed `Typeflux.app` into it.
3. Creates a symbolic link to `/Applications` for drag-and-drop installation.
4. Uses `create-dmg` to produce a polished DMG with:
   - Window title and icon size
   - Drag-and-drop layout (app on the left, Applications alias on the right)
   - Code signing of the DMG itself (if `CODESIGN_IDENTITY` is set)

### Customizing the DMG appearance

Edit `scripts/build_dmg.sh` to change:

- Window size and position
- Background image or color
- Icon arrangement

---

## 3. Notarization (Recommended for Distribution)

If you are distributing outside the Mac App Store, notarize the DMG with Apple:

\`\`\`bash
xcrun notarytool submit .build/release/Typeflux.dmg \
  --keychain-profile "AC_PASSWORD" \
  --wait
\`\`\`

After successful notarization, staple the ticket:

\`\`\`bash
xcrun stapler staple .build/release/Typeflux.dmg
\`\`\`

> **Note:** Replace `"AC_PASSWORD"` with your actual notarytool keychain profile name.

---

## 4. Distribute the Release

### GitHub Releases (Automated)

The repository includes `.github/workflows/release.yml`. Pushing a version tag triggers the workflow:

\`\`\`bash
git tag v1.0.0
git push origin v1.0.0
\`\`\`

The workflow currently uploads `Typeflux.zip`. To also upload the DMG, extend the workflow to run `build_dmg.sh` and attach the resulting `.dmg` file.

### Manual Distribution

Upload the final artifacts to your chosen distribution channel:

- **GitHub Releases**: attach both `Typeflux.dmg` and `Typeflux.zip`
- **Direct download**: host `Typeflux.dmg` on your website or CDN
- **Homebrew Cask** (optional): submit a cask formula pointing to the DMG URL

---

## 5. Release Checklist

- [ ] Version bumped in `app/Info.plist`
- [ ] `CHANGELOG.md` updated
- [ ] `swift build` passes
- [ ] `swift test` passes
- [ ] Release app bundle signed (`Typeflux.app`)
- [ ] DMG created and tested on a clean macOS install
- [ ] DMG notarized and stapled (if distributing externally)
- [ ] Git tag pushed (`vX.Y.Z`)
- [ ] GitHub Release drafted and published
- [ ] Download links updated in `README.md`

---

## Quick Reference

| Step | Command | Output |
|------|---------|--------|
| Build release app | `make release` | `.build/release/Typeflux.app` |
| Create DMG | `./scripts/build_dmg.sh` | `.build/release/Typeflux.dmg` |
| Notarize DMG | `xcrun notarytool submit ...` | — |
| Trigger GitHub Release | `git push origin v1.0.0` | Release artifact uploaded |
