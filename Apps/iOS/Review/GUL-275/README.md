# GUL-275 iOS experience review and App Store purchases

Every screen and dialog was captured on an iPhone 17 simulator (iOS 26.5) by
`ScreenTourTests`, which drives the shipped views with offline fixtures and
asserts each flow works. Chinese is the primary review language; English and
dark appearance are spot-checked. Images in this folder are the "after" state.

Reproduce: `TYPEFLUX_IOS_TEST_RESULT_BUNDLE_PATH=/tmp/tour.xcresult scripts/test_ios.sh`
(or `-only-testing:TypefluxIOSUITests/ScreenTourTests`), then
`xcrun xcresulttool export attachments --path /tmp/tour.xcresult --output-path out`.
Enable Reduce Motion on the simulator first; otherwise the animated orb keeps
XCUITest waiting for an idle app for 150 seconds per launch.

## Findings and fixes

| Screen / dialog | Problem a user would notice | Fix |
| --- | --- | --- |
| Any error (reset password, network, server) | Raw technical text, e.g. "未能完成操作。(TypefluxChat.ChatAPIError错误3。)", and English server diagnostics such as "credits exhausted" | `ChatStore.userMessage(for:)` maps API, network and known server codes (reset code, weak password, rate limit, missing conversation, conflict…) to translated sentences; unknown text falls back to a generic sentence |
| Conversation out of credits | A run the server paused for credits looked like it was still "thinking" forever and blocked the composer; a refused message showed "credits exhausted" | `paused_credits` is shown as "已暂停 · 积分不足" without a spinner or live stream; an "积分已用完" card offers 购买积分 and, for a paused run, 继续 (server resume) |
| Buying credits | No way to buy credits in the app | App Store credit shop (StoreKit 2) from Settings and the out-of-credits card; see below |
| Sidebar history | "加载更多" shown under a single conversation; tapping it did nothing | Only offered when the last page was full (server page size 50) |
| Failed answer | Only a red sentence; retrying meant finding a small ↻ icon | 重试 button under the error |
| Answer actions | Six unlabeled icons (copy, select, quote, regenerate, report, share); "字I" and quote glyphs are guesswork | Copy, regenerate and share stay as icons; select text, quote and report move into a labeled "更多操作" menu |
| Waiting for Mac | "等待原设备执行" does not say what to do | "这一步需要在 Mac 上完成，请保持 Mac 上的 Typeflux 打开并联网。" |
| Settings | Link rows in blue next to black rows with chevrons; Contact under "Data and privacy"; Privacy Policy in an unlabeled group; Delete account a loose link; guests get a small "登录" pill | Sections General / About / Account; one row style with ↗ for web pages; AI data sharing shows 已开启/未开启; Sign out and Delete account grouped; guests get a sign-in card explaining the benefit; Buy credits row under the balance |
| Guest sidebar | Examples rendered as default white list cells with separators, unlike history rows; "?" avatar | Rows match history rows; sign-in is an accent row; neutral person avatar |
| Guest example | The question bubble spanned the full width | Same bubble as a sent message |
| Model list | "视觉" badge is jargon | "可看图" (English "Photos") |
| Password reset | Half-height sheet: the keyboard hid the code and password fields; requirements (upper/lowercase, number) only discovered after a rejection; the error stayed on the sign-in page after closing | Full-height sheet; footer states the rule; errors cleared on close; server codes translated |
| Delete account | Did not mention purchased credits | States that unused purchased credits, including App Store packs, are lost |

Screenshots (after, unless prefixed `before-`): credit flow
`38-paused-out-of-credits`, `39-credit-shop`, `40-credit-shop-delivered`,
`41-resumed-after-purchase`, `42-settings-with-addon-credits`,
`43-send-refused-out-of-credits`, `44-credit-shop-unavailable`,
`45-credit-shop-pending-english`; fixes `05-guest-settings`, `04-guest-sidebar`,
`09b-password-reset-wrong-code`, `16b-answer-more-menu`, `18-sidebar-history`,
`21-failed-run`, `22-waiting-for-mac`, `28-settings-bottom`, `31-delete-account`.

Also found while verifying: the reset sheet's new-password field used
`.textContentType(.newPassword)`, and iOS strong-password AutoFill kept only the
last character typed; it now uses `.password`. The data and privacy page labels
its status and provider rows.

Checked without changes: welcome, email sign-in, AI consent, report answer,
model/effort card, attach menu, streaming, rich Markdown, dark appearance.

## App Store purchases

- Packs come from the server catalog (`GET /api/v1/me/billing/apple/products`),
  prices from StoreKit in the user's currency; products StoreKit cannot price are
  hidden, and a closed store shows an explanation instead of an empty list.
- Each purchase carries the account ID as `appAccountToken`. The transaction is
  finished only after the server answers `granted` or `revoked`; network errors,
  another account's purchase or a server rejection keep it in StoreKit, which
  offers it again. Unfinished transactions are delivered on sign-in and every
  return to the foreground, and `Transaction.updates` covers Ask to Buy.
- States shown to the user: delivered (amount), waiting for approval, belongs to
  another account, could not verify (contact support, no double charge), payment
  done but credits pending, and "all purchases delivered" for the manual check.

## Verification

- `swift test --package-path Packages/TypefluxChat`: 59 tests pass.
- iOS unit tests (`TypefluxIOSTests`): all pass, including the new
  `ChatPurchasesTests` (shop loading, purchase, pending/cancel/failure, delivery
  retry rules, background updates, credit pause and resume, error sentences).
- UI tests including `ScreenTourTests` on the iPhone 17 / iOS 26.5 simulator.
- Live App Store sandbox purchases were not run: they need App Store Connect
  products and a sandbox account. The server rejects Xcode StoreKit-file
  transactions by design (they are not signed by Apple).
