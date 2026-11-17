# Cloud image tools in desktop work mode

The screenshot's conversation used `kind=work` and `cloud:default`. Work mode executes through `AskLocalEngine`, even with cloud sign-in. Its account-scoped builtin host advertised only plan/web tools, so fixing the server-hosted Chat catalog alone could never expose image generation on this path.

## Changes

- Refresh the published cloud image catalog before each send, retry and regeneration, before loading mutable conversation state.
- Advertise generation/edit tools with the catalog's actual model aliases, aspect ratios and resolutions. The first live attempt exposed an unsupported model-selected `4:3`; published enums now prevent that omission in the tool contract.
- Use the signed-in account's image asset/job endpoints and existing Credit protocol, with a stable per-call idempotency key. Poll the original job across transient read failures; never resubmit a paid generation while polling.
- Preserve existing tool authorization and account binding. Image tools use the existing write classification and serial execution.
- Persist generated-image metadata through the normal tool result and existing image cards. Include user image reference IDs in the model context for editing.
- Do not expire a running builtin flight merely because its persisted run timestamp is old. Cancellation still uses the existing execution journal.

## Review and verification

Reviewed actor reentrancy around catalog refresh, account binding, idempotency, polling/cancellation, pending-job identity, image reference ownership, result persistence and stale-run recovery.

The focused scope covers the image transport and host, affected builtin execution/authorization, local engine, prompt builder and existing generated-image cards:

`AskCloudImageToolsTests AskBuiltinToolHostTests AskBuiltinWaveTests AskDeviceTransportTests AskToolAuthorizationTests AskGeneratedImageTests AskLocalEngineTests AskPromptBuilderTests`

- 73 tests passed; main focused command wall time including discovery: 102.15 seconds.
- After the live-discovered schema correction, only `AskCloudImageToolsTests` was repeated: 7 passed, 23.30 seconds including discovery.
- Final new image-tools file line coverage: 81.65% (129/158). These are focused coverage measurements, not full-project coverage.
- Coverage preparation required the Xcode SwiftUI macro plugin to be explicitly loaded with native SwiftPM. Initial compile attempts also exposed test macro syntax errors and an input modified during compilation; these were corrected before execution. Approximate total coverage/live validation command time, including build preparation and failed attempts: 17 minutes, excluding release packaging.

The explicit opt-in `AskCloudImageLiveTests` ran a real local work-mode engine, real cloud inference, existing approval/result handling and the production image service using the signed-in account. The first live attempt failed before job creation because `4:3` was unsupported. The corrected live attempt passed in 56.31 seconds including discovery (40.09 seconds test execution).

Successful image job: `78c22da6-4834-4e3b-9223-975cde9331d6`. The conversation completed with exactly one image; the job had one 10-Credit debit. Downloaded PNG was 1254 x 1254, 2,577,650 bytes; all PNG chunk checksums and compressed pixel data validated. Visual inspection confirmed the requested kitten/dog illustration.

The live acceptance uses the real engine and transport but is not itself a mouse-driven UI test. Existing snapshot/journal recovery still treats interrupted unknown outcomes conservatively; this change does not claim automatic crash recovery of image jobs.
