# Inline image generation presentation

The selected design keeps a square image card in the conversation from generation through download and completion. The card belongs to the original tool call, outside the process disclosure, so the final answer cannot hide or relocate it. Tool details remain collapsed, generated images are removed from the duplicate task-outcome display, and completed cards offer preview, save and an editable follow-up draft.

## State correction

An unfinished execution journal entry previously triggered the recovery presentation even while its own local dispatch was still running. The header and activity group consequently said that a decision was required, and the composer hid Stop, while the tool row continued to say Running.

The driver now registers the exact execution identity after claiming it and removes that registration when that dispatch/delivery exits. The presentation excludes only that live identity's unfinished or successful receipt. Foreign identities, uncertain receipts, interrupted operations and server-side recovery blocks remain visible. This is display metadata, not new execution authority or permission to replay a request.

Waiting cards show elapsed time, not invented provider progress. A completed URL enters a distinct download state. Reload only downloads that same URL; it never submits another image job. Stop waiting retains the existing cancellation behavior and explicitly explains that submitted cloud work may still finish and incur a charge. Editing fills the composer without submitting or overwriting the existing draft.

## Verification

The focused scope contains 81 methods across:

- AskRunPhaseTests and AskRecoveryNoticePresentationTests: active execution versus genuine recovery, run-level state and interrupted claims.
- AskRecoveryNoticeInteractionTests: account/conversation recovery, current-run isolation and preservation of historical receipts.
- AskGeneratedImageTests and AskCloudImageToolsTests: card states, URL validation, existing image transport/polling behavior.
- AskRemoteImageTests: download-only retry, authorization revocation, bounded decoding, real media helper decoding and image rendering.
- AskActivityPresentationTests, AskActivityRowPresentationTests and AskTurnProcessTests: native layouts, stable card identity and keeping images outside the completed process disclosure.

All selected methods passed across the initial execution and focused retries. No paid image request was submitted. Original native waiting, approval (superseded below) and interrupted card captures are in `validation/image-generation-presentation-2026-11-17/`. Successful image rendering was checked using a synthetic raster in `.build/remote-image-validation/remote.png`; this is not a live-provider acceptance screenshot.

The normal coverage runner was used. Initial preparation exposed a mixed SDK/toolchain, a source change during compilation, and one incorrectly named suite before tests could run. Subsequent execution exposed existing fixture isolation issues: real-keychain defaults in view fixtures, use of the lifecycle-owned preview worker without an application lifecycle, and historical-entry assertions that predated current-run-only recovery reads. Fixtures now use isolated identity/keychain/worker dependencies and verify retained historical receipts directly in storage. Only failed or interrupted suites/methods were retried.

Recorded runner wall times (including build and discovery) were 26.58s, 75.18s, 180.19s, 280.66s, 137.11s and 77.88s. Coverage HTML reflects the final retry scope, not a whole-project or combined changed-line coverage claim.

## Visual review and limits

The native waiting card matches the selected design's hierarchy: square reserved area, centered activity indicator, status, elapsed time and concise hint. Real progress uses a native spinner rather than a fabricated intermediate image. Result cards keep the same square area and fit the image without cropping. Process grouping tests prove that completion preserves the card's section identity before the answer.

This change does not add durable client job recovery after a crash, provider cancellation, progressive image previews, or original-resolution export. Save uses the existing validated preview export, bounded to 1600 pixels. Interrupted generation remains explicitly uncertain rather than being silently resubmitted. Live-provider behavior and a new paid generation were not revalidated in this change.

## Approval ordering correction

The original approval placeholder was premature. The driver now records a session-local start time only after dispatch authorization succeeds. Proposed calls, pending approvals, queued calls and cancellation before dispatch reserve no image space. Denied/invalid receipts stay in the tool trace without becoming failed image cards. Each call has its own start evidence; another tool waiting for approval cannot create or hide its image. Elapsed time starts at authorized dispatch rather than the assistant message timestamp.

The existing approval card remains the only decision surface. Once execution starts, the image card retains its position through generation and download. A completed valid image remains visible when reopening history. The start marker is display metadata, never permission, and is cleared on session reset. Interrupted jobs after app restart continue to use existing recovery notices; this change does not introduce durable job recovery.

Focused validation covers hidden pre-dispatch states, denied/invalid/cancelled receipts, unrelated approvals, successful history rendering, approval/refusal layout height, and the native generating/interrupted layouts.

Approval correction validation: `make coverage SUITE="AskGeneratedImageTests AskActivityPresentationTests AskTurnProcessTests AskCloudImageToolsTests AskRunPhaseTests"` passed all 45 tests (5 XCTest and 40 Swift Testing) in 419.94 seconds including a clean preparation/rebuild. The image card source had 95.58% line coverage in this focused run; this is file coverage, not whole-project or changed-line coverage. No paid provider request was made.
