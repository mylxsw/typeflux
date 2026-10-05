# GUL-199 iOS design v4 validation

Validated on 2026-10-04 with Xcode 27.0 on an iPhone 17 Pro simulator (iOS 26),
using the offline synthetic fixture. No live account, model or physical device.

| Check | Result |
| --- | --- |
| `swift test --package-path Packages/TypefluxChat` | 38 tests passed |
| `scripts/test_ios.sh` unit tests | 123 tests in 9 suites passed |
| `scripts/test_ios.sh` UI flows | 17 of 17 passed |
| iOS app target line coverage (unit + UI, includes DEBUG fixture) | 94.16% (6858/7283) |
| iOS Release simulator build | Succeeded (one AppIntents metadata notice) |
| `typeflux-api` `go test ./internal/oauth/` | Passed (Sign in with Apple accepts several client IDs) |

## Issues found on the simulator and fixed

- Glass top-bar buttons used interactive Liquid Glass, which swallowed taps; they
  now use static glass with a circular hit shape.
- The history sidebar glass let the conversation and orb show through; it is now a
  nearly opaque panel.
- A long-press context menu on answers blocked text selection; Quote moved to the
  answer's action row.
- UI tests updated for the new navigation and for content that scrolls beneath the
  floating top bar.

The landscape flow failed once because the simulator kept a stale orientation;
it passed after rebooting the simulator and in the final full run.

## Screenshots

`docs/images/ios/v4/`: new conversation, reasoning card, model list, sidebar,
conversation, streaming, settings, welcome, email sign-in, dark reasoning, dark
photo conversation, tool details, sidebar delete, password reset.

## Not covered

Sign in with Apple needs the capability enabled for `app.typeflux.ios` and the ID
added to the API's `APPLE_OIDC_CLIENT_ID`; it was not exercised against Apple.
Dictation and camera capture need a physical device. Account deletion and
conversation rename have no backend API yet.
