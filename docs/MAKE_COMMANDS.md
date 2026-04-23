# Make Commands

This document explains the purpose of each `make` command in the repository, when to use it, and what it produces.

## Quick Reference

| Command | Purpose | Typical Use |
| --- | --- | --- |
| `make run` | Build and launch the packaged development app | Normal local app testing |
| `make dev` | Build and launch the packaged development app with terminal logs | Debugging runtime behavior |
| `make full-dev` | Launch the dev app with SenseVoice bundled into the app | Test the full packaged local-model flow |
| `make build` | Compile the Swift package | Fast compile check |
| `make test` | Run the unit test suite | Logic and regression validation |
| `make coverage` | Generate code coverage output | Larger refactors or quality checks |
| `make release` | Build the signed release app bundle and zip archive | Prepare `.app` and `.zip` artifacts |
| `make dmg` | Build the signed DMG from the release app bundle | Prepare `.dmg` artifact |
| `make release-notarize` | Run the full release pipeline including notarization and stapling | One-step external distribution build |
| `make format` | Format the codebase | Cleanup before commit or review |

## Command Details

### `make run`

Command:

```bash
make run
```

What it does:

- builds the app in development mode
- assembles a stable `.app` bundle
- launches `~/Applications/Typeflux Dev.app`

Use it when:

- you want to test the app locally
- you do not need terminal logs attached

Notes:

- this is safer than launching the raw Swift binary directly because macOS permissions behave better with a stable app bundle

### `make dev`

Command:

```bash
make dev
```

What it does:

- launches the development app
- keeps logs attached to the terminal
- sets `TYPEFLUX_API_URL=http://127.0.0.1:8080` before launch

Use it when:

- you are debugging hotkeys, audio capture, provider calls, overlay behavior, or text insertion

### `make full-dev`

Command:

```bash
make full-dev
```

What it does:

- launches the development app with terminal logs attached
- sets `TYPEFLUX_API_URL=http://127.0.0.1:8080` before launch
- bundles SenseVoice into `~/Applications/Typeflux Dev.app` using the same app-internal layout as the `full` release variant
- downloads missing SenseVoice runtime/model files into the local cache on first use

Use it when:

- you want to test the real bundled-model behavior locally before building a release artifact
- you need the dev app to run the same bundled SenseVoice path as the `full` installer

Notes:

- `make dev` and `make full-dev` reuse the same `~/Applications/Typeflux Dev.app` path
- switching from `make full-dev` back to `make dev` removes the bundled model payload from the dev app
- this command validates the full local app behavior, not notarization, DMG packaging, or final release signing

### `make build`

Command:

```bash
make build
```

What it does:

- runs `swift build`

Use it when:

- you want the fastest compile-level validation
- you are checking whether a change still builds before running heavier workflows

### `make test`

Command:

```bash
make test
```

What it does:

- runs `swift test`

Use it when:

- you changed routing, parsing, settings, workflow logic, providers, or other testable code

### `make coverage`

Command:

```bash
make coverage
```

What it does:

- runs the coverage script
- generates a coverage report under `coverage-report/`

Use it when:

- you want to inspect coverage after a larger change
- you are validating critical workflow paths

### `make release`

Command:

```bash
make release
```

What it does:

- builds the release binary
- assembles `.build/release/Typeflux.app`
- signs the app bundle
- generates `.build/release/Typeflux.zip`

Artifacts:

- `.build/release/Typeflux.app`
- `.build/release/Typeflux.zip`

Environment:

- optional: `TYPEFLUX_CODESIGN_IDENTITY`

Behavior:

- if `TYPEFLUX_CODESIGN_IDENTITY` is set, it signs with that identity
- otherwise it falls back to ad-hoc signing

### `make dmg`

Command:

```bash
make dmg
```

What it does:

- packages `.build/release/Typeflux.app` into `.build/release/Typeflux.dmg`
- signs the DMG if a signing identity is available

Artifacts:

- `.build/release/Typeflux.dmg`

Requirements:

- run `make release` first
- install `create-dmg`

Environment:

- optional: `TYPEFLUX_CODESIGN_IDENTITY`

### `make release-notarize`

Command:

```bash
make release-notarize
```

What it does:

- builds the release app
- signs the app with hardened runtime
- builds and signs the DMG
- submits the DMG to Apple notarization
- waits for Apple to finish processing
- staples the notarization ticket to both the app and the DMG
- validates the stapled artifacts

Artifacts:

- `.build/release/Typeflux.app`
- `.build/release/Typeflux.zip`
- `.build/release/Typeflux.dmg`

Required environment:

```bash
export TYPEFLUX_APPLE_DISTRIBUTION="Developer ID Application: Your Name (TEAMID)"
export TYPEFLUX_NOTARY_PROFILE="your-notarytool-profile"
```

Optional environment:

```bash
export TYPEFLUX_CODESIGN_IDENTITY="$TYPEFLUX_APPLE_DISTRIBUTION"
export TYPEFLUX_NOTARY_SUBMIT_RETRIES=3
export TYPEFLUX_NOTARY_POLL_INTERVAL_SECONDS=15
```

Notes:

- `TYPEFLUX_CODESIGN_IDENTITY` takes priority over `TYPEFLUX_APPLE_DISTRIBUTION`
- the script automatically retries submission failures
- if Apple returns a submission ID and the client times out afterward, the script continues polling that submission instead of blindly starting over
- for full setup of certificates, Developer IDs, and notarization credentials, see [BUILD_CONFIGURATION.md](./BUILD_CONFIGURATION.md)

### `make format`

Command:

```bash
make format
```

What it does:

- runs `./scripts/format.sh`

Use it when:

- you want to normalize formatting before commit or review

## Recommended Workflows

### Day-to-day development

```bash
make build
make test
make dev
make full-dev
```

### Prepare a release app and DMG manually

```bash
make release
make dmg
```

### One-step notarized release

```bash
export TYPEFLUX_APPLE_DISTRIBUTION="Developer ID Application: Your Name (TEAMID)"
export TYPEFLUX_NOTARY_PROFILE="your-notarytool-profile"
make release-notarize
```

## Related Documentation

- [USAGE.md](./USAGE.md)
- [RELEASE.md](./RELEASE.md)
