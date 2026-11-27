# GUL-726 macOS release validation

**Review follow-up.** GUL-731 closed after interleaved startup measurements put the two releases within 5 ms. Local dictation can insert a spurious Korean syllable before English speech. The GUL-732 visual spot check passed on the signed SDK 27.2 Release. The GUL-733 leading-silence fix still needs a final-package retest with ABC and Korean input sources. The existing microphone label is an accepted release-note item. Hosted checkout and remote speech recognition require sandbox configuration.

## Builds and environment

Apple Silicon, disposable macOS Tahoe profiles, synthetic accounts and local services. The guest used nginx, the API, Postgres and dedicated Redis with AOF and synchronous fsync. Local S3 emulation handled feedback. Neither baseline install touched the shared host desktop. The API compose correction is tracked separately. Screenshot stems below identify native captures in the GUL-726 issue thread.

| Product | Build used | Verification |
|---|---|---|
| Classic 0.5.0 | Release, main at `9d014f7947`; initial functional pass used Debug at `5d6d3fed42` | Release build on idle mac-pro took 227.48 s including dependencies, 134.44 s in Swift build |
| Typeflux 1.0.1 | Debug, `4f85af511e`, including helpers | Swift build reported 107.82 s after dependency resolution |
| Baselines | Signed 0.4.0 and 1.0.0 release bundles | In-place upgrades using the native updaters |

Both candidate ZIPs were registered in the local API with their actual sizes and SHA-256. Both passed deep strict signature verification and the minimum-OS audit. Local packaging used the compiled artifacts and disabled timestamping. Classic: 14,779,677 bytes, `e4583b4494174f98cb49f555a4ad3420336167ec28f326509bd25e11fa3a7532`. Typeflux: 109,177,433 bytes, `b6142f1016527855a283d0bbb2befea9948f8214b9b02bca4f0dcf0319a263b1`.

Service revisions: API `cd7ea489d4`, homepage `e4aeafd4b3`, dashboard `530fe9a200`, docs `17232a1b89`, realtime ASR `5fc286e`.

## Acceptance matrix

| # | Scenario | Result and evidence |
|---|---|---|
| 1 | Legacy automatic upgrade | **Pass.** Signed in to 0.4.0, accepted the updater and opened Classic at the same path. Pro, history, sound preference and both TCC grants persisted. See native040-signedin, opted040-update, actual050. |
| 2 | Typeflux introduction | **Pass.** The 1.0.0 updater offered and installed 1.0.1. Opened the installed copy and saw the introduction once. A later launch skipped it. A clean profile showed regular onboarding on both launches and set the intro-ineligible flag. See update-101-offer, upgraded-101-intro, roundtrip101-return, fresh-101-first and fresh-101-relaunch. |
| 3 | Switch to Classic | **Pass.** The About button and confirmation downloaded the signed Classic ZIP, replaced the bundle and launched 0.5.0. Cloud speech and rewrite models, persona, history, Pro session and grants survived. The test proxy needed its download route corrected before this run. See switch-native-confirm, switched-classic-models, classic-shared-llm, switched-classic-history and switched-permissions.txt. |
| 4 | Return to Typeflux | **Pass.** In Classic changed Cloud recognition to local SenseVoice and English Translator to Typeflux. Reinstalled the registered 1.0.1 ZIP at the same path. The returning process retained both selections and Pro, and skipped onboarding and the introduction. See classic-new-stt, classic-new-persona, roundtrip101-return and return101-values.txt. |
| 5 | Product update isolation | **Pass.** Both installed legacy updaters reached the intended candidate. Four API cases covered both legacy clients and both product-tagged current clients. See update.json in the first evidence archive. |
| 6 | System name | **Pass with accepted exception.** Finder, Activity Monitor, menu, login items, Dock, Tahoe Apps grid and Safari open-app prompt showed Typeflux Classic. After a guest reboot the existing enabled microphone entry still showed Typeflux. See mic-before-toggle (post-reboot), apps-tahoe and dock-classic. |
| 7 | Account, checkout and credits | **Pass for local billing; hosted checkout pending sandbox keys.** Paid PostgreSQL fixtures exercised membership terms and add-on checkout/webhook posting. Separately, an audited local grant added 12.3456 to 569.9948. Both native apps showed 12.35 add-on and 569.99/570 base. The web account reflected the same balance. See grant-check.json, classic-post-grant, account101-open and web-A-dashboard. Provider-hosted payment, receipt delivery and post-payment return remain unverified. |
| 8 | Short token lifetime | **Pass (Debug).** A real 15-minute token refreshed after ten minutes. Account access continued beyond original expiry, including ten settings/account close-open cycles in 19.77 s. See account-after-expiry in the first archive. |
| 9 | Feedback origin | **Pass (Debug and focused tests).** Native image upload completed local presign, relative PUT and submit. The origin tests covered disallowed URLs. See feedback-uploaded and feedback-sent in the first archive. |
| 10 | Browser sign-in | **Pass.** Safari returned to the installed Classic from settings and onboarding. Cancel and a shortened 60-second transaction expiry showed the expected state. Quitting during login and finishing the old browser transaction reopened the app as a guest; fresh sign-in succeeded. See wizard-signedin, login-cancelled, login-expired-final and login-quit-guest. |
| 11 | Prepaid membership | **Pass.** Pro showed expiry and web renewal, with subscription-management hidden. The native action opened local billing. See prepaid-live and prepaid-renewal in the first archive. |
| 12 | Shared account totals | **Pass.** Classic and 1.0.0 showed the same period, balance and usage (one voice entry and three AI requests). Classic and 1.0.1 also agreed after the add-on grant. See credits-v2, cross100-account, classic-post-grant and account101-open. |
| 13 | Account change | **Pass for native switch and focused session tests.** Signed A out of Classic and the local web session, then signed B in via Safari. B showed Free, 5/5 and zero calls, without A’s Pro add-on. Async result isolation was covered by the focused session tests. See account-A-logout, B-callback-result and B-free-after-switch. |
| 14 | Speech input | **Insertion delivered to five targets; transcript accuracy failed on the leading-silence case below.** Remote providers await keys. Held the configured hotkey while playing a known WAV into the guest microphone via BlackHole. SenseVoice inserted the sentence in Notes, TextEdit, a Safari form, Terminal (unexecuted) and Obsidian (Electron) on signed Debug. Release repeated TextEdit insertion three times. History retry also recovered the expected transcript. Release showed a partial during recording and inserted into Safari’s address field. With English Translator selected and a seeded vocabulary entry, a loopback streaming fixture received recognized text and the term GulNotebook, and its deterministic response reached both TextEdit and Safari. This exercises the rewrite transport and insertion; model quality was outside the fixture. See live-safari-hold, live-safari-insert and voice-fixture-textedit. See voice-notes-typed, perf-release, voice-safari, voice-terminal and voice-obsidian. |
| 15 | Performance | **Pass on interleaved retest (GUL-731, closed).** Idle CPU and RSS were comparable. Median release-to-insert time improved, with a slower first Classic recognition. Measurements below. |
| 16 | Visual inspection | **Pass for the SDK-corrected spot check.** The four surfaces below were revisited on the signed Release from `c9d15dc62c`. Earlier five-language settings and six-step onboarding captures used the SDK 13.0 candidate and describe that build only. |

## Tahoe visual spot check after GUL-732

Rebuilt Classic 0.5.0 from the Classic #11 merge (`c9d15dc62c`). The release script selected the native Swift build system on Xcode 27.2. The optimized build took 130.93 s. The remote signing session returned `errSecInternalComponent`, so the assembled app-only bundle was signed and archived on the local Mac using the same Developer ID, hardened runtime and secure timestamp. Deep strict signature verification and the minimum-OS audit passed. In the installed arm64 executable, `otool -l` showed `LC_BUILD_VERSION`, `platform 1`, `minos 13.0` and **`sdk 27.2`**. The signed ZIP SHA-256 was `03fd9d3962943784d0dbb88d4f86be36fc040e2dfc5f763ea4ee9f5542d476ea`.

The captures below show the actual app window or the recording capsule with its immediate background. The account page used the signed-in synthetic Pro account against the local API. The capsule used live SenseVoice input. Review covered the switch and window controls, account totals and charts, onboarding language choices and navigation, and the capsule's transcript and recording indicator. No clipping or overlap was observed in these sampled states. Some interim speech strings contain the known SenseVoice silence artifact tracked by GUL-733. These images verify layout and appearance only.

| Language and appearance | Settings | Account | Onboarding | Recording capsule |
|---|---|---|---|---|
| English, light | [Settings](sdk-27.2/settings-en-light.jpg) | [Account](sdk-27.2/account-en-light.jpg) | [Onboarding](sdk-27.2/onboarding-en-light.jpg) | [Capsule](sdk-27.2/capsule-en-light.jpg) |
| English, dark | [Settings](sdk-27.2/settings-en-dark.jpg) | [Account](sdk-27.2/account-en-dark.jpg) | [Onboarding](sdk-27.2/onboarding-en-dark.jpg) | [Capsule](sdk-27.2/capsule-en-dark.jpg) |
| Simplified Chinese, light | [Settings](sdk-27.2/settings-zh-Hans-light.jpg) | [Account](sdk-27.2/account-zh-Hans-light.jpg) | [Onboarding](sdk-27.2/onboarding-zh-Hans-light.jpg) | [Capsule](sdk-27.2/capsule-zh-Hans-light.jpg) |
| Simplified Chinese, dark | [Settings](sdk-27.2/settings-zh-Hans-dark.jpg) | [Account](sdk-27.2/account-zh-Hans-dark.jpg) | [Onboarding](sdk-27.2/onboarding-zh-Hans-dark.jpg) | [Capsule](sdk-27.2/capsule-zh-Hans-dark.jpg) |

## Dictation prefix investigation

The stored transcript for the original Terminal run (05:46:17 UTC) already started with `그.` (U+ADF8, U+002E). The same prefix appeared in the processed text. This fixture had 9.75 s of digital silence before speech. Decoding its complete archived WAV with the installed SenseVoice model in automatic language mode produced the clean English sentence. Decoding only the first 2.4 s of verified all-zero PCM produced language `ko`, tokens `["그", "."]`. This test ran the decoder directly, without an editor or keyboard events.

On the signed 0.5.0 Release, the test selected each macOS input source after focusing an empty target and read back the source ID before and after dictation. It compared Classic history with the actual TextEdit document or a shell reader that captured a Terminal line verbatim. The hotkey driver only held and released Ctrl+Shift+J during speech. All six insertions matched the processed transcript exactly.

| Active input source | TextEdit | Terminal |
|---|---|---|
| ABC | Clean English | Clean English (capital B in Blue) |
| Korean 2-Set | `그.` + English | `그.` + English |
| Simplified Pinyin | Clean English | Clean English |

A Korean 2-Set control with speech starting promptly produced clean English. In an ABC control, the native capsule showed the syllable during silence, before the English recording began. Another ABC run with a 9.7 s playback delay reproduced the full prefix in TextEdit. The app logged that it chose the 36-character preview over the 34-character final transcript. The earlier ABC control finished clean, so the defect depends on timing. The artifact occurs upstream of input-method composition.

**Reproduction.** Select SenseVoice with local live preview, leave polishing disabled, focus a blank TextEdit document and hold the dictation shortcut. Wait through several 2.4 s preview chunks before playing the synthetic English sentence, then release after the final word. Compare the live capsule, history and document with an offline decode of the same WAV. Chunk timing affects whether the extra prefix survives. `LocalModelLivePreviewBackend` accumulates nonempty chunk transcripts. In `WorkflowController+Processing.swift`, `preferredTranscript` selects the longer preview if its suffix matches the final transcript. The screenshots, exact strings, source IDs and decoder tokens are attached to GUL-726.

## Performance measurements

On the same VM, quit and open the signed application and poll for its status item. These are fresh processes with the OS file cache retained. Idle readings are medians of five samples; insertion measures key release to observable TextEdit content using the same audio and recognizer.

| Measurement | 0.4.0 Release | 0.5.0 Release |
|---|---|---|
| Status item, seconds (three launches) | 0.388 / 0.389 / 0.393 | 1.685 / 0.741 / 0.868; independent repeat 1.751 / 0.731 / 0.702 |
| Idle CPU and RSS | 0.0%, 160,016 KiB | 0.0%, 161,728 KiB |
| Release to inserted text, seconds | 1.389 / 1.051 / 1.285 | 3.150 / 1.001 / 0.964 |

The initial non-interleaved Classic startup medians were 0.868 s and 0.731 s versus 0.389 s for the baseline. This probe includes Launch Services and accessibility polling. The later interleaved comparison in GUL-731 supersedes these startup samples for the release decision. GUL-730 merged.

## Focused test evidence

| Scope | Result | Measured time |
|---|---|---|
| Classic FeedbackAPIServiceTests | 28 passed | 0.280 s test execution, about 35 min initial build |
| ClassicCompatibilityContractTests, AuthStateBillingSessionTests, AuthStateBillingLinkSessionTests, PrepaidMembershipPresentationTests | 23 passed | 2.739 s test execution |
| Go TestAppReleaseProductRouting | Passed | 0.918 s package time |
| Go TestWebLoginPreservesSubscriptionCreditsAndLegacySession | Passed | 4.902 s package time, 9 min 27 s cold command |
| Go TestPrepaidPurchaseTermsAndMembershipConsumersPostgres | Passed, six term/channel combinations | 8.267 s package time |
| Classic LocalizationReleaseTests | 2 passed | 1.512 s test execution |
| Go TestCreditPackBillingPostgresFixtures/paid | Passed against isolated Postgres | 2.45 s subtest, 3.347 s package time |

Only the listed focused suites ran.
