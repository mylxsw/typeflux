# GUL-217 native iOS review

The screenshots in this directory are from the native iPhone 17 Pro simulator running explicit, network-free DEBUG fixtures. Names, messages, providers and credit balances are synthetic. Production recipient names come from the authenticated disclosure endpoint; there are no invented production defaults.

Implemented flows: dismissible first-launch login, guest examples, local draft/photo preservation through authentication, explicit AI data sharing consent with manual send, consent withdrawal, private answer reporting, verified account deletion and permission-denied Settings links.

## Validation

- Shared `TypefluxChat`: 49 tests pass, including disclosure, deletion proof and private report wire contracts.
- Final iOS run: 157 tests pass, including all unit tests, private reporting/deletion completion, and guest settings/login/consent with draft preservation. Separate focused runs pass consent withdrawal, decline/manual send, guest browsing, and sign-out.
- Release simulator build passes; the privacy manifest is bundled and offline fixture identity/launch markers are absent from the executable.
- Full iOS run measured 90.3% application line coverage and 97.7% for `ChatStore`. Final focused runs also cover deletion completion, withdrawal observation and the settings/login/consent transition.
- The existing `ChatFlowTests.testLandscapeKeyboardCanReachLastModel` fails because the simulator window remains 402 × 874 after requesting landscape. The identical assertion failure was reproduced on an isolated, unmodified `main` worktree at `38ee5621` on the same simulator.
- Root macOS `swift test` was run as required. It failed in existing macOS window/selection tests; no macOS production or test sources are changed. Sequential retries passed seven of eleven affected suites/filters. Remaining failures: `WorkflowControllerProcessingTests/testOpeningPersonaPickerDoesNotPlayCueWhenSoundEffectsAreDisabled`, `AskComposerInteractionTests`, `AskConversationWindowSizingTests`, and `AskCappedWidthTests`. Other workspace tasks also had macOS UI test processes on this host, so the shared window environment may contribute; this is not a claimed all-green macOS run.

## Deployment dependency

Deploy [typeflux-api #113](https://github.com/mylxsw/typeflux-api/pull/113) before this client. Configure actual AI/tool recipients, the policy revision, Apple revocation signing credentials, and Stripe credentials for existing website subscribers. Real Apple/Google authorization and Stripe test-mode verification require deployment credentials. See `../../PRIVACY.md` and the API's `docs/account-privacy.md` for retention and private-report operations. StoreKit remains outside scope.
