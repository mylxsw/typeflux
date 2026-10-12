# macOS website sign-in (GUL-360)

This implementation depends on [typeflux-api PR #139](https://github.com/mylxsw/typeflux-api/pull/139),
head `bb0c9622423d5418829670fa219bbf9b03fc81ce`, and its
[frozen contract](https://github.com/mylxsw/typeflux-api/blob/bb0c9622423d5418829670fa219bbf9b03fc81ce/docs/web-app-auth.md).
The Homepage implementation is GUL-359. Do not enable the production entry until both are deployed and the
real-provider/browser acceptance tests pass. No iOS behavior changes.

## Rollout configuration

The feature is **off by default**. Environment values take precedence over identically named
Info.plist strings. Release packaging copies `app/Info.plist`; set release values there before
signing. Both development launch scripts copy the configuration into their bundle before signing.

| Key | Default | Purpose |
| --- | --- | --- |
| `TYPEFLUX_WEB_AUTH_ENABLED` | `false` | Only the exact string `true` enables the new entry. |
| `TYPEFLUX_WEB_AUTH_ORIGIN` | `https://typeflux.app` | Trusted website origin; API login URL must match HTTP(S) origin, `/login`, and the sole expected transaction query. |
| `TYPEFLUX_WEB_AUTH_API_ORIGIN` | First configured `AppServerConfiguration.apiBaseURLs` entry | Reachable, pinned API HTTP(S) origin; no endpoint rotation or retry for the one-use code. Set explicitly for staging. |
| `TYPEFLUX_WEB_AUTH_CHANNEL` | `production` | `development` selects the separate development client and callback. Dev scripts set it automatically. |

Origins must have no credentials, query, fragment or path prefix. HTTP and HTTPS are accepted without an extra transport flag. The development
launch scripts enable the existing ATS HTTP exception when either Web origin uses
HTTP; set `TYPEFLUX_API_URL` to the local API too for profile/refresh calls. No client secrets belong in the app.

Configure the API's `WEB_AUTH_CLIENTS` as a JSON object (there is no server default):

```json
{
  "typeflux-macos": ["ai.gulu.app.typeflux://auth/callback"],
  "typeflux-macos-dev": ["ai.gulu.app.typeflux.dev://auth/callback"]
}
```

`app/Info.plist` already registers the production `ai.gulu.app.typeflux` scheme, also used by
legacy GitHub login. `configure_dev_web_auth.sh` adds only the independent development auth
scheme to development bundles and selects `typeflux-macos-dev`. Both `run_dev_app.sh` and
`run_dev_attached.sh` invoke it; `swift run` relaunches through the former. Release packaging
does not register the development scheme. The existing stable bundle/signing identifier,
native OAuth schemes, billing scheme and Keychain namespace are preserved. Consequently,
this does **not** isolate legacy sessions or eliminate Launch Services collisions for the old
shared scheme when both app bundles are installed. The new development flow has an independent
callback, and cross-client callbacks are rejected. Test production/dev coexistence through
ASWebAuthenticationSession before enabling rollout; a misrouted production cold callback fails
closed and requires a fresh login in the intended app.

## State, storage and recovery

- `WebLoginProtocol` owns cryptographically random independent 32-byte state/verifier, S256,
  URL validation and strict single-value callback parsing. Callback code/state are the only
  accepted parameters. The frozen callback has no transaction ID: state correlates it with
  the sole active transaction. Unknown fields, wrong paths/clients and expired attempts fail.
- `WebLoginCoordinator` owns the retained authentication session and its lifecycle, with injectable
  API, browser, pending-state store, clock, proof generator and AuthState boundary. Only one
  login runs at a time. Cancel, logout, session replacement and late callbacks cannot restore an
  obsolete session. Browser `start()` failure is visible. Expiry clears the pending verifier.
- `WebLoginHTTPAPI` pins a trusted API origin, rejects HTTP redirects and disables cookies/cache.
  It sends no bearer token and makes one application request per exchange. It bypasses the old
  automatic endpoint failover executor and never logs raw URLs, codes, verifier or response bodies.
  Invalid grants, timeouts and ambiguous/lost responses all require a fresh transaction.
- `AuthState.acceptWebLogin` checks the captured session generation and verifies Keychain write
  success before entering the existing login/profile/notification path. Existing refresh rotation,
  logout, `sv`/`sid` and `CloudLoginSyncCoordinator` behavior remain in place.
- **No pending-login cold-start recovery in v1.** State/verifier live only in memory. Quitting the
  app discards them; an unsolicited/cold callback never exchanges a code and shows restart guidance.
  Completed sessions still persist/restore using the existing Keychain mechanism. Recreating a
  coordinator clears any injected stale pending state. Cancellation clears memory immediately.
- Reopen starts another retained authentication session for the same validated URL. The website
  can reject it if browser binding was lost; UI explicitly explains using the same browser or
  cancelling and starting again. It does not attempt to reissue a code or silently fall back.
- Five existing UI languages include waiting, reopen, cancel and failure recovery text. Closing
  the login window or leaving its view cancels an unfinished flow. Existing logged-in users are
  not signed out when the feature is enabled or disabled.

The integration uses the macOS 13-compatible AuthenticationServices API and retains the package's
macOS 13 deployment target. The shipped dependency/binary policy remains **macOS 13.4+**;
this change does not raise it. See [Apple's authentication session documentation](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession).

## Validation and rollback

Run `swift test --no-parallel --enable-code-coverage --filter WebLogin`, then the repository
suite and coverage command. New Swift Testing suites using the main actor or localization use
`.exclusiveUIState`. `TYPEFLUX_WEB_LOGIN_SCREENSHOTS=<directory>` enables screenshot output.
Tests cover protocol vectors, hostile URLs, expiry, duplicate callbacks, cancellation and late
responses, storage failure, existing AuthState notifications and completed-session restoration.
Pending cold callbacks are tested as rejection, not successful recovery.

Before rollout, verify email/Google/GitHub/Apple with real credentials and existing identities,
Safari/Chrome/Firefox session behavior, browser cookie loss, user cancellation, warm/cold URL
delivery, development/production coexistence, real Keychain permissions and macOS 13.4 hardware.
Mocked tests and rendered screenshots do not establish these real-world acceptance results.

Rollback by setting `TYPEFLUX_WEB_AUTH_ENABLED=false` and restarting the app (or distributing
a bundle with the flag disabled). The original login UI returns; existing Keychain sessions
are untouched. Preserve native API/provider configuration. API/Homepage rollback follows
the API document; no user, refresh token or session data needs deleting.

For local Docker, set both Web origins and `TYPEFLUX_API_URL` to
`http://localhost:5174`, enable Web auth, and run `make run`. Use the API
repository's `docs/web-app-local-http.md` and Compose override with the matching
Homepage `Dockerfile.local`. Pending state, PKCE and strict origin matching are unchanged.
