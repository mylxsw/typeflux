# Guest access and account privacy

The iOS app always opens its chat shell after session restoration. First launch presents a dismissible login sheet; subsequent launches remember the guest choice. Guests can browse bundled examples, compose text, select a local photo, use system dictation, and open settings/help without creating an account. Local examples never call the API or consume credits.

A guest send opens login while retaining text and the local image. Successful login fetches the backend's reviewed recipient disclosure and asks for explicit AI sharing consent. Login and consent never send content automatically. Consent is scoped to the account, policy revision and recipient names, can be withdrawn in Settings, and is checked again before every send/regeneration. Existing conversations can still be read after withdrawal. System microphone/Speech/camera permissions are requested on use; permission failure leaves text entry working.

Settings includes privacy/terms/help and authenticated account deletion. Deletion verifies password or Google identity, or Apple identity plus a one-time authorization code for Apple-linked accounts. Only a successful server response clears the local account; external failure leaves an actionable error and allows retry. Website subscriptions are cancelled by the backend; App Store subscriptions have a separate management link. The app does not promise automatic refunds or an unimplemented retention deadline.

The report action is available for real assistant answers, with a reason and optional explanation. The selected answer is sent to the private `ai-report` branch of `/feedback`, never its public GitHub queue. Bundled examples have no report control.

## Deployment

Deploy the companion GUL-217 API change first. Configure its reviewed `AI_DATA_PROCESSORS` and `AI_PRIVACY_VERSION`, Apple revocation signing credentials, and Stripe credentials for existing customers. Missing disclosure blocks AI sending rather than inventing provider names. Review the API's `docs/account-privacy.md` for failure/retry semantics and private report operations.

`PrivacyInfo.xcprivacy` declares app-owned UserDefaults access (CA92.1) and account/content/support data used for app functionality. Audio dictation uses Apple's Speech framework and its system permission disclosure; the app sends transcribed text to AI providers only after consent. Validate the final archive's aggregated privacy report and App Store Connect labels against deployment behavior. The manifest alone is not App Store approval.

StoreKit and subscription purchase flows remain outside this change. Real Apple/Google authorization and Stripe test-mode cancellation need deployment credentials; deterministic unit/UI fixtures never contact those services.
