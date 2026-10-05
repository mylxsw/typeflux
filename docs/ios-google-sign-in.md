# iOS Google sign-in

The iOS application uses `ASWebAuthenticationSession` with PKCE and state validation.
It exchanges the authorization code for an ID token, then calls the existing
`POST /api/v1/auth/oauth/google` endpoint. Only the resulting Typeflux session is
saved in the existing Keychain store. Google access/refresh tokens are not persisted.

## Configuration

Debug and Release include the project's public iOS OAuth configuration for bundle
identifier `app.typeflux.ios`. Normal builds require no OAuth build-setting overrides:

```text
GOOGLE_IOS_CLIENT_ID = 567492048493-vc6r99q2hh0b158u3nvjn8i3asaunl3j.apps.googleusercontent.com
GOOGLE_IOS_CALLBACK_SCHEME = com.googleusercontent.apps.567492048493-vc6r99q2hh0b158u3nvjn8i3asaunl3j
```

These values are public identifiers, not secrets. To use another iOS OAuth client,
override both build settings together; the callback scheme must correspond to the
client ID, and the Google Cloud client must match the app's bundle identifier.
No client secret belongs in the app.

The API's comma-separated `GOOGLE_OIDC_CLIENT_ID` allowlist must also include the
iOS client ID, preserving every existing desktop/web client ID. The current API
already supports multiple audiences; no migration is needed. Client build settings
do not update the deployed server's allowlist.

After installing, verify sign-in, cancellation, profile/history loading, relaunch
and sign-out with a real Google account.

Example build using the checked-in configuration:

```sh
xcodebuild -project Apps/iOS/TypefluxIOS.xcodeproj -scheme TypefluxIOS \
  -configuration Release -destination 'generic/platform=iOS' build
```

See [Google's native OAuth documentation](https://developers.google.com/identity/protocols/oauth2/native-app).
Live Google authorization requires console/server configuration and is separate
from the automated tests, which never contact an identity provider. Synthetic
preview launches always use an unconfigured Google adapter, even in a configured build.

## Authorization succeeds but Typeflux rejects sign-in

A 401 response from `POST /api/v1/auth/oauth/google` means the Typeflux API rejected
the login. The API returns `AUTH_OAUTH_INVALID_TOKEN` when token verification fails
or required identity claims are missing. Older iOS builds incorrectly displayed
"Please check your email and password." for this response. Current builds preserve
the OAuth error code and show a social-sign-in rejection instead.

Check the effective `GOOGLE_OIDC_CLIENT_ID` on every API instance serving the app's
configured endpoint. It must include the iOS client above, separated from existing
desktop/web IDs by commas. Updating the Xcode settings does not update that list;
the API process must restart after its environment changes.

To establish the actual cause, inspect server logs for the failed request:

- `oidc audience not accepted`: compare `audience` with `configured_client_id`;
  append the iOS client ID to the allowlist without removing existing clients.
- `oidc verify failed`: inspect the verification error for expiry, issuer,
  signature or Google key-fetch failures.
- `request failed` with `AUTH_OAUTH_INVALID_TOKEN`: inspect the wrapped error for
  absent configuration or other verification failures.

Do not share raw ID tokens, authorization codes or refresh tokens in issue comments.
A generic 401 or screenshot alone cannot establish which verification check failed.

## Regression checks

- `swift test --package-path Packages/TypefluxChat --enable-code-coverage`
- `make ios-test` (unit and UI tests with coverage)
- `swift test` (macOS regression)

The new tests cover PKCE, malformed callbacks, denied authorization, token response
validation, API payloads, account lifecycle, Chinese accessibility labels, drawer
geometry and outside-tap keyboard dismissal. Manually inspect effort transitions
and the installed Home Screen icon as well.

## Icon asset

`Apps/iOS/TypefluxIOS/Assets.xcassets/AppIcon.appiconset/AppIcon.png` is an opaque
1024 × 1024 image; it no longer contains an inset rounded tile or transparent margin.
The existing icon was edited with the built-in image generation tool and resized
for the asset catalog. Prompt: extend the existing white/light-gray background to
all four square edges, preserve the central black infinity ribbon's shape, scale,
position and shading, and remove the outer border and pre-rounded tile silhouette;
no text, extra symbols or tile shadow.
