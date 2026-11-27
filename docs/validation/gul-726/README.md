# GUL-726 macOS release validation

**Release decision: blocked.** Native Classic observations below used a locally signed debug preview of 0.5.0 at `5d6d3fed42`. Repeat them on the optimized package after Classic PR #7 lands. A pass in the table applies only to the stated build and scope. Screenshot names refer to the evidence archive attached to GUL-726.

## Environment

Apple Silicon, disposable macOS Tahoe VMs, isolated home directory, Keychain and privacy databases. Signed 0.4.0 and 1.0.0 app-only baselines came from the product releases. The local nginx frontend connected the guest to the local API, dedicated Postgres and Redis, synthetic accounts and test billing records. Feedback objects used local S3 emulation. The ASR gateway ran locally. VM snapshots preserve the baseline and test profiles independently of the shared host desktop.

| Component | Revision |
|---|---|
| Typeflux | 4f85af511e |
| Classic | 5d6d3fed42 |
| API | cd7ea489d4 |
| Homepage | e4aeafd4b3 |
| Dashboard | 530fe9a200 |
| Docs | 17232a1b89 |
| Realtime ASR | 5fc286e |

## Acceptance matrix

| # | Scenario | Result | Observation and remaining coverage |
|---|---|---|---|
| 1 | 0.4.0 automatic upgrade | Blocked | The installed updater replaced and relaunched the Classic preview. History, sound setting and the microphone grant survived. Repeat with a logged-in baseline, Accessibility granted and the final package. See local040-update, after040-upgrade, settings-en-light-history and microphone-permission. |
| 2 | 1.0.1 introduction | Blocked | The signed 1.0.0 baseline launched. Upgrade, second launch and clean-profile comparison are required. See baseline100. |
| 3 | One-click switch to Classic | Blocked | A local Classic release was registered. The native switch, mapped models, shared history and grants need verification with both candidates. |
| 4 | Return to 1.0.1 | Blocked | Set Typeflux Cloud and English Translator in Classic. Persistence across the return to 1.0.1 and onboarding suppression remain open. See cloud-rewrite-choice and persona-selected. |
| 5 | Update isolation | Pass (local API) | Four live checks: legacy 0.4.0 and 1.0.0 received 0.5.0 and 1.0.1 respectively. Each product-tagged current client received its own version with should_update=false. See update.json and routing-classic. |
| 6 | System product name | Fail (preview) | Finder, Activity Monitor, menu, login items and the Safari open-app prompt showed Typeflux Classic. The existing microphone permission entry retained Typeflux. Dock and app launcher remain unchecked. See finding A. |
| 7 | Account and checkout | Blocked | Native account UI showed 569.99 of 570 credits and usage charts. The local billing page opened. Receipt, membership/add-on purchase and return after payment need a configured sandbox. See credits-v2, prepaid-renewal and usage-v2.txt. |
| 8 | 15-minute access token | Pass (preview) | Native web login exchanged a token at 12:50:11 and refreshed at 13:00:11 (Singapore time). The account remained signed in past original expiry during repeated navigation, including ten close/reopen/account cycles in 19.77 s. See account-after-expiry and web-login.json. |
| 9 | Feedback upload origin | Pass (preview plus focused tests) | Native image attachment completed presign, relative PUT and feedback submission against local services. The client suite covered disallowed origins. See feedback-uploaded and feedback-sent. |
| 10 | Web sign-in | Blocked | Settings opened Safari. Completing sign-in opened the installed Classic through the system URL handler and restored the signed-in account. The onboarding start, cancel, timeout and app-quit branches still need native evidence. See settings-login, login-callback and login-return. |
| 11 | Prepaid membership | Pass (preview) | The Pro screen displayed the seeded expiry, offered web renewal and omitted the subscription-management action. Renewal opened the local billing page. See prepaid-live and prepaid-renewal. |
| 12 | Account data across products | Pass (preview / 1.0.0) | After replacing the Classic bundle in the same user profile, 1.0.0 recognized the existing Pro account. Both account pages showed 569.99/570 credits, the same billing period and usage counters (1 voice entry, 3 AI requests). See cross100-account, credits-v2 and usage-v2.txt. |
| 13 | Account switch | Blocked | Two synthetic accounts completed separate local login transactions. The native A→B switch with outstanding requests still needs observation. See web-login.json. |
| 14 | Speech input | Blocked | Local SenseVoice retried a synthetic history WAV and saved the expected transcript, “The blue notebook is on the table.” Gateway health and token issuance worked. Physical capture, streamed preview, remote recognition, polishing, vocabulary and insertion in target apps remain open. See retry-options and retry-result. |
| 15 | Performance | Blocked | Preview and baseline samples had different build configurations and window states. Paired cold-start, idle CPU/RSS and release-to-insert timings are still required. |
| 16 | Visual inspection | Blocked | Captured overview, general settings, vocabulary, history, models and personas in English and Simplified Chinese, both appearances. See settings-* images. Remaining work includes onboarding, overlay, prompts, other settings states and post-merge language checks. |

## Findings for triage

**A. Existing microphone permission retains the previous product name.** On the guest, grant microphone access to installed 0.4.0, update in place to the signed Classic preview, then open System Settings → Privacy & Security → Microphone. Expected the enabled entry to identify Typeflux Classic. Actual label was Typeflux and the grant stayed enabled. Finder and Activity Monitor showed Typeflux Classic for the same install. Compare microphone-permission, finder-name and activity-detail. Verify with the final signed candidate and a fresh grant to distinguish a cached system label.

**B. Fresh local API startup requires durable Redis settings.** Start the documented local Redis container with default configuration, prepare the billing database and start the API. Startup reported BILLING_STORAGE_UNSAFE, first requiring appendonly=yes and then appendfsync=always. Applying both to the dedicated test instance allowed API startup. Expected the local setup to start with the required storage policy. This affects reproducing the test environment.

## Focused test evidence

| Scope | Result | Measured time |
|---|---|---|
| Classic FeedbackAPIServiceTests | 28 passed | 0.280 s test execution, about 35 min initial build |
| ClassicCompatibilityContractTests, AuthStateBillingSessionTests, AuthStateBillingLinkSessionTests, PrepaidMembershipPresentationTests | 23 passed | 2.739 s test execution |
| Go TestAppReleaseProductRouting | Passed | 0.918 s package time |
| Go TestWebLoginPreservesSubscriptionCreditsAndLegacySession | Passed | 4.902 s package time, 9 min 27 s cold command |
| Go TestPrepaidPurchaseTermsAndMembershipConsumersPostgres | Passed, six term/channel combinations | 8.267 s package time |

Timing units above distinguish package/test execution from wall time where available. Payment fixtures exercise the billing contract. Native checkout requires separate sandbox evidence.
