# iOS Google sign-in

The iOS application uses `ASWebAuthenticationSession` with PKCE and state validation.
It exchanges the authorization code for an ID token, then calls the existing
`POST /api/v1/auth/oauth/google` endpoint. Only the resulting Typeflux session is
saved in the existing Keychain store. Google access/refresh tokens are not persisted.

## Configuration

1. Create an **iOS** OAuth client in the project's Google Cloud console for bundle
   identifier `app.typeflux.ios`. This is a public client; no client secret belongs
   in the app.
2. Supply these Xcode build settings for both Debug and Release, either through
   the build command or a private build configuration:

   ```text
   GOOGLE_IOS_CLIENT_ID = <client-id>.apps.googleusercontent.com
   GOOGLE_IOS_CALLBACK_SCHEME = com.googleusercontent.apps.<client-id>
   ```

   The callback scheme must correspond to that client ID. The checked-in defaults
   intentionally contain no client ID; the button reports a localized configuration
   error until a valid client is provided.
3. Append the iOS client ID to the API's comma-separated `GOOGLE_OIDC_CLIENT_ID`
   allowlist, preserving every existing desktop/web client ID. The current API
   already supports multiple audiences; no migration is needed.
4. Build and install the configured application, then verify sign-in, cancellation,
   profile/history loading, relaunch and sign-out with a real Google account.

Example build (replace the two public configuration values):

```sh
xcodebuild -project Apps/iOS/TypefluxIOS.xcodeproj -scheme TypefluxIOS \
  -configuration Release -destination 'generic/platform=iOS' \
  GOOGLE_IOS_CLIENT_ID='<client-id>.apps.googleusercontent.com' \
  GOOGLE_IOS_CALLBACK_SCHEME='com.googleusercontent.apps.<client-id>' build
```

See [Google's native OAuth documentation](https://developers.google.com/identity/protocols/oauth2/native-app).
Live Google authorization requires console/server configuration and is separate
from the automated tests, which never contact an identity provider. Synthetic
preview launches always use an unconfigured Google adapter, even in a configured build.

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
