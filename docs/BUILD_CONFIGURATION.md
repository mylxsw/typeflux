# Typeflux Build & Signing Configuration

This document explains, end-to-end, how to obtain and configure every piece of credential the Typeflux build pipeline needs:

- Apple Developer account and Team ID
- Apple Development certificate (for the dev build)
- Developer ID Application certificate (for distributable release builds)
- macOS provisioning profile (required for "Sign In with Apple")
- App-specific password and `notarytool` keychain profile (for notarization)
- All `TYPEFLUX_*` build environment variables and where each one is used

If you only want to learn the high-level release commands, see [RELEASE.md](./RELEASE.md) and [MAKE_COMMANDS.md](./MAKE_COMMANDS.md). This document is the deep dive.

---

## 1. Why all these credentials?

macOS distribution has four moving parts that the Typeflux scripts coordinate:

| Concern | Mechanism | Required for |
| --- | --- | --- |
| Local debug runs | Apple Development certificate (or ad-hoc) | A stable identity so macOS Privacy/TCC does not re-prompt for permissions on every rebuild |
| Sign In with Apple in dev | Apple Development cert + matching macOS provisioning profile | The "Sign in with Apple" button in dev builds |
| Distributable signing | Developer ID Application certificate | Distribution outside the Mac App Store |
| Gatekeeper acceptance | Apple notarization (via `notarytool`) | macOS allowing end users to launch the downloaded app |

The Typeflux scripts read these via environment variables. Every variable is prefixed with `TYPEFLUX_` so it cannot collide with build configurations of other apps you might develop on the same machine.

---

## 2. Apple Developer account prerequisites

1. Enroll in the [Apple Developer Program](https://developer.apple.com/programs/) (paid, individual or organization).
2. Sign in to https://developer.apple.com/account.
3. Note your **Team ID**: open **Membership details**. The Team ID is a 10-character string such as `N95437SZ2A`. You will need it for `notarytool` and to identify your signing identity.
4. Decide whether you sign on behalf of an individual or an organization team. The certificate's Common Name will reflect this choice.

> Tip: The Team ID is also embedded in every signing identity name returned by `security find-identity`, in parentheses at the end (e.g. `Developer ID Application: YIYAO GUAN (N95437SZ2A)`).

---

## 3. Issuing the Apple Development certificate (for `make run` / `make dev`)

The dev scripts (`scripts/run_dev_app.sh`, `scripts/run_dev_attached.sh`) auto-detect a local `Apple Development:` identity. You can also pin one explicitly via `TYPEFLUX_DEV_CODESIGN_IDENTITY` to avoid losing macOS Privacy permissions on rebuilds.

### 3.1 Create the certificate

Easiest path (recommended):

1. Open **Xcode → Settings → Accounts**.
2. Add your Apple ID, select your team, click **Manage Certificates...**.
3. Click the **+** button, choose **Apple Development**.
4. Xcode generates the private key in your login keychain and downloads the matching certificate.

Manual path (if you don't have Xcode signed-in):

1. Open **Keychain Access → Certificate Assistant → Request a Certificate From a Certificate Authority...**.
2. Enter your email and Common Name, choose **Saved to disk**, and save the `.certSigningRequest` (CSR) file.
3. In https://developer.apple.com/account/resources/certificates → **+ Add → Apple Development**, upload the CSR.
4. Download the resulting `.cer` file and double-click it to install into your login keychain.

### 3.2 Read the identity name

```bash
security find-identity -v -p codesigning
```

Look for a line like:

```
1) ABCDEF1234... "Apple Development: YIYAO GUAN (N95437SZ2A)"
```

The string between the quotes is what you set as `TYPEFLUX_DEV_CODESIGN_IDENTITY`:

```bash
export TYPEFLUX_DEV_CODESIGN_IDENTITY="Apple Development: YIYAO GUAN (N95437SZ2A)"
```

> Pin this in your shell profile (`~/.zshrc` or similar) so dev rebuilds always use the same identity. macOS TCC tracks Accessibility/Microphone/etc. permissions per signing identity — switching identities means re-granting permissions.

---

## 4. Issuing the Developer ID Application certificate (for releases)

This is the certificate that public macOS distribution uses. Apple issues it once per team; you reuse it for every notarized release.

### 4.1 Create the certificate

1. Sign in to https://developer.apple.com/account/resources/certificates.
2. Click **+ Add**, then choose **Developer ID Application**.
3. Generate a CSR via **Keychain Access → Certificate Assistant** as in 3.1.
4. Upload the CSR, download the resulting `.cer`, and double-click it to install.
5. Verify it is present:

   ```bash
   security find-identity -v -p codesigning
   ```

   You should see, in addition to the dev identity:

   ```
   2) FEDCBA9876... "Developer ID Application: YIYAO GUAN (N95437SZ2A)"
   ```

### 4.2 Set the release signing identity

Use the full quoted string as `TYPEFLUX_APPLE_DISTRIBUTION` (preferred) or `TYPEFLUX_CODESIGN_IDENTITY`:

```bash
export TYPEFLUX_APPLE_DISTRIBUTION="Developer ID Application: YIYAO GUAN (N95437SZ2A)"
```

> `TYPEFLUX_CODESIGN_IDENTITY` overrides `TYPEFLUX_APPLE_DISTRIBUTION` when both are set. The two names exist so you can keep your distribution identity stable in shell profiles while temporarily overriding it (e.g. in CI).

### 4.3 Export the cert for CI (`.p12` file)

If you sign on a CI runner (the GitHub Actions workflow does), you need to export the certificate plus its private key as a password-protected `.p12`:

1. Open **Keychain Access**, expand the certificate to reveal the private key beneath it, then **shift-click** to select both rows.
2. **File → Export Items...**, format **Personal Information Exchange (.p12)**.
3. Save as `developer-id-application.p12`. Set a strong export password — this becomes `APPLE_CERTIFICATE_PASSWORD` in CI.
4. Encode it for storage as a GitHub Secret:

   ```bash
   base64 -i developer-id-application.p12 | pbcopy
   ```

5. Save the clipboard contents into the `APPLE_CERTIFICATE_BASE64` secret.

The GitHub Actions workflow recreates a temporary keychain from these secrets on every release run.

---

## 5. Creating the macOS provisioning profile (for Sign In with Apple)

A macOS provisioning profile is **required** when the app uses restricted entitlements such as `com.apple.developer.applesignin`. Without it, macOS AMFI will reject the app at launch.

### 5.1 Register the App ID

1. Sign in to https://developer.apple.com/account/resources/identifiers.
2. Click **+ Add**, choose **App IDs → App**.
3. **Bundle ID:** `ai.gulu.app.typeflux` (this matches `app/Info.plist`).
4. **Capabilities:** enable **Sign In with Apple**.
5. Save.

### 5.2 Create the provisioning profile

1. Go to https://developer.apple.com/account/resources/profiles.
2. Click **+ Add**.
3. **Distribution → Developer ID** for release builds, or **Development → macOS App Development** for the dev build. (You may want one of each.)
4. Pick the `ai.gulu.app.typeflux` App ID.
5. For the development profile, pick the certificates and devices it should embed (you only need your Mac).
6. Name it descriptively, e.g. `Typeflux Dev` or `Typeflux Distribution`.
7. Download the resulting `.provisionprofile` file and store it somewhere stable on disk.

### 5.3 Point the build scripts at the profile

For dev builds:

```bash
export TYPEFLUX_DEV_PROVISIONING_PROFILE="/absolute/path/to/Typeflux_Dev.provisionprofile"
```

For release builds:

```bash
export TYPEFLUX_PROVISIONING_PROFILE="/absolute/path/to/Typeflux_Distribution.provisionprofile"
```

The scripts copy this file into `Contents/embedded.provisionprofile` and re-sign the bundle with the entitlements. If the variable is unset, Sign In with Apple is disabled but the app still launches.

> Provisioning profiles expire (typically after one year). Re-download from the Apple Developer portal when expired and replace the file at the same path; no other configuration changes are required.

---

## 6. Configuring `notarytool` for release notarization

Apple Notary Service authenticates with an Apple ID + app-specific password tied to a team that owns the Developer ID certificate. `xcrun notarytool` can store this in the macOS keychain so you don't pass credentials on every invocation.

### 6.1 Generate an app-specific password

1. Sign in to https://account.apple.com.
2. Under **Sign-In and Security → App-Specific Passwords**, click **+** and create a password labeled e.g. "Typeflux Notarization".
3. Copy it once. You cannot retrieve it later — only revoke and recreate.

### 6.2 Store the credential as a notary profile

Pick any profile name you like (it is local to your keychain). Typeflux examples use `typeflux-profile`:

```bash
xcrun notarytool store-credentials "typeflux-profile" \
  --apple-id "you@example.com" \
  --team-id "N95437SZ2A" \
  --password "abcd-efgh-ijkl-mnop"
```

After this you only need to reference the profile by name:

```bash
export TYPEFLUX_NOTARY_PROFILE="typeflux-profile"
```

### 6.3 Optional: non-default keychain

If the profile is stored in a non-default keychain (typical in CI), point to it explicitly:

```bash
export TYPEFLUX_NOTARY_KEYCHAIN="/path/to/custom.keychain-db"
```

The release script passes `--keychain` automatically when this variable is set.

---

## 7. The full `TYPEFLUX_*` environment variable reference

| Variable | Required for | What value it takes | Where it is used |
| --- | --- | --- | --- |
| `TYPEFLUX_DEV_CODESIGN_IDENTITY` | Optional, recommended for dev | Full string from `security find-identity`, e.g. `Apple Development: YIYAO GUAN (N95437SZ2A)` | `scripts/run_dev_app.sh`, `scripts/run_dev_attached.sh` |
| `TYPEFLUX_DEV_PROVISIONING_PROFILE` | Optional; required for Sign In with Apple in dev | Absolute path to a `.provisionprofile` file | `scripts/run_dev_app.sh`, `scripts/run_dev_attached.sh` |
| `TYPEFLUX_CODESIGN_IDENTITY` | Required by `release-notarize` | Full string from `security find-identity`, typically the Developer ID Application identity | `scripts/build_release.sh`, `scripts/build_dmg.sh`, `scripts/release_notarize.sh` |
| `TYPEFLUX_APPLE_DISTRIBUTION` | Optional alias for `TYPEFLUX_CODESIGN_IDENTITY` | Same value as above | `scripts/release_notarize.sh` (used as fallback when `TYPEFLUX_CODESIGN_IDENTITY` is unset) |
| `TYPEFLUX_PROVISIONING_PROFILE` | Optional; required for Sign In with Apple in release | Absolute path to a Developer ID `.provisionprofile` file | `scripts/build_release.sh` |
| `TYPEFLUX_NOTARY_PROFILE` | Required by `release-notarize` | Local notarytool keychain profile name (e.g. `typeflux-profile`) | `scripts/release_notarize.sh` |
| `TYPEFLUX_NOTARY_KEYCHAIN` | Optional | Path to a non-default keychain file containing the notary profile | `scripts/release_notarize.sh` |
| `TYPEFLUX_NOTARY_SUBMIT_RETRIES` | Optional | Integer; default `3` | `scripts/release_notarize.sh` (retries on transient submission failure) |
| `TYPEFLUX_NOTARY_POLL_INTERVAL_SECONDS` | Optional | Integer; default `15` | `scripts/release_notarize.sh` (sleep between status polls) |

> Variables that are **not** prefixed are intentionally Apple-defined or third-party names: `NOTARYTOOL_APPLE_ID`, `NOTARYTOOL_PASSWORD`, `APPLE_TEAM_ID`, `APPLE_CERTIFICATE_BASE64`, `APPLE_CERTIFICATE_PASSWORD` exist only inside the GitHub Actions workflow.

---

## 8. Putting it all together

### 8.1 Day-to-day local development

One-time setup in `~/.zshrc`:

```bash
export TYPEFLUX_DEV_CODESIGN_IDENTITY="Apple Development: YIYAO GUAN (N95437SZ2A)"
export TYPEFLUX_DEV_PROVISIONING_PROFILE="$HOME/secure/typeflux/dev.provisionprofile"
```

Then:

```bash
make dev    # build + launch + tail logs
```

### 8.2 Local notarized release

One-time setup:

```bash
xcrun notarytool store-credentials "typeflux-profile" \
  --apple-id "you@example.com" \
  --team-id "N95437SZ2A" \
  --password "abcd-efgh-ijkl-mnop"
```

Per release:

```bash
export TYPEFLUX_APPLE_DISTRIBUTION="Developer ID Application: YIYAO GUAN (N95437SZ2A)"
export TYPEFLUX_PROVISIONING_PROFILE="$HOME/secure/typeflux/release.provisionprofile"
export TYPEFLUX_NOTARY_PROFILE="typeflux-profile"
make release-notarize
```

Outputs in `.build/release/`:

- `Typeflux.app`
- `Typeflux.zip`
- `Typeflux.dmg`

### 8.3 GitHub Actions release

Configure these repository secrets in **Settings → Secrets and variables → Actions**:

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_BASE64` | `base64 -i developer-id-application.p12` output |
| `APPLE_CERTIFICATE_PASSWORD` | `.p12` export password |
| `APPLE_TEAM_ID` | 10-character team ID |
| `CODESIGN_IDENTITY` | Full Developer ID Application identity string |
| `NOTARYTOOL_APPLE_ID` | Apple ID email |
| `NOTARYTOOL_PASSWORD` | App-specific password from Step 6.1 |

The workflow exposes `secrets.CODESIGN_IDENTITY` to the build scripts as the env var `TYPEFLUX_CODESIGN_IDENTITY` (and similarly maps `TYPEFLUX_NOTARY_PROFILE`, `TYPEFLUX_NOTARY_KEYCHAIN`, retries, and poll interval). Publish a GitHub Release to trigger a build.

---

## 9. Verifying the result

After any signed build:

```bash
codesign --verify --deep --strict --verbose=2 .build/release/Typeflux.app
spctl --assess --type execute --verbose=4 .build/release/Typeflux.app
xcrun stapler validate .build/release/Typeflux.dmg
```

For an end-user smoke test, copy the DMG to a Mac that has never had Typeflux installed and confirm Gatekeeper allows it without warnings.

---

## 10. Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `Missing required environment variable: TYPEFLUX_CODESIGN_IDENTITY` | `make release-notarize` invoked without setting the identity | Export `TYPEFLUX_APPLE_DISTRIBUTION` or `TYPEFLUX_CODESIGN_IDENTITY` |
| Dev app crashes immediately on launch | Restricted entitlement (Sign In with Apple) without matching profile | Set `TYPEFLUX_DEV_PROVISIONING_PROFILE` or remove the entitlement temporarily |
| macOS keeps re-prompting for Accessibility / Microphone after rebuild | Ad-hoc signing changes identity each build | Set a stable `TYPEFLUX_DEV_CODESIGN_IDENTITY` |
| Notarization returns `Invalid` | Hardened runtime missing or unsigned nested binary | Run `xcrun notarytool log <id> --keychain-profile "$TYPEFLUX_NOTARY_PROFILE"` and resign |
| `notarytool` cannot find the profile | Profile is in a non-default keychain | Set `TYPEFLUX_NOTARY_KEYCHAIN` |
| `Sign In with Apple is disabled for this release build` warning | `TYPEFLUX_PROVISIONING_PROFILE` unset or path missing | Provide a valid macOS provisioning profile path |
| `find-identity` shows the cert but `codesign` errors with `no identity found` | Login keychain locked or private key not exported with the cert | Unlock with `security unlock-keychain login.keychain-db`; re-export the `.p12` including the private key |

---

## 11. Related documents

- [RELEASE.md](./RELEASE.md) — high-level release flow and checklists
- [MAKE_COMMANDS.md](./MAKE_COMMANDS.md) — what each `make` target does
- [USAGE.md](./USAGE.md) — end-user installation and usage
