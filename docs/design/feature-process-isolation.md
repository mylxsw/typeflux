# Feature fault isolation

## Objective

A stalled conversation window must not prevent opening the launcher, capturing a
screenshot, or using clipboard history. Ultimately, independently recoverable
feature windows need separate GUI processes. A background task, actor, package,
or extra window in the same process does not provide that guarantee.

## Current implementation: responsiveness groundwork

- `MainThreadHangMonitor` probes the main queue from an independent utility queue
  every 250 ms, retaining one outstanding probe. A two-second delay is reported
  once per incident. Gaps over five seconds invalidate the outstanding probe to
  avoid classifying process suspension or system sleep as an application hang.
- A hang triggers a local one-second `/usr/bin/sample` capture. Diagnostics use
  their own worker, have a five-second process deadline, a 2 MiB stdout bound,
  a one-minute sampling cooldown, and retain at most five reports in
  `~/.typeflux/cache/hang-diagnostics`. There is no upload or automatic app restart.
- Clipboard panel opening, refresh, row construction, and startup retention run
  outside the main queue. Closing or reopening invalidates old deliveries.
  Reads which time out leave an already visible panel intact; a late response
  cannot reopen a dismissed panel or overwrite a newer request.
- Markdown normalization and parsing run on a shared background queue. AppKit
  styling and text layout remain on the main thread. An editor retains only the
  running parse and its newest replacement. Timed-out preparation falls back to
  plain text; stale results cannot overwrite a newer source or rendering mode.
- `LatestBackgroundWork` bounds synchronous background work to one active and
  one pending request per owner. Timeout/cancellation revokes result delivery,
  but does not pretend that an uninterruptible operation has stopped. No retry
  or replacement worker is launched while that worker remains occupied.

This is not process isolation. Main-thread layout, clipboard polling, shortcut
dispatch, and several explicit clipboard management/authority checks still
share the application process. The clipboard query preserves the existing
complete-history semantics, including pinned items and snippets; pagination is
not implemented by silently imposing a new display limit.

## Next boundary: one conversation owner

Do not launch a second `AskConversationModel`/`AskLocalEngine` against the same
mutable conversation state as an implementation shortcut. Engines cache local
records in memory, temporary conversations are memory-only, and the launcher
currently drives quick-ask runs and transfers them into the conversation window.
The canonical engine does not provide a cross-process writer lock. The optional
alternate-agent directory owner has a lock, which is not a general solution for
the canonical store. SQLite serialization alone cannot transfer execution
ownership or in-memory state.

The separate device-execution work changes this boundary too. Reconcile its
final API before replacing the current model composition.

Required migration contracts:

1. A single service owns conversation mutations, run identity, queues, execution
   claims, inference, tool approvals, and temporary workspaces. UI clients send
   typed requests and receive versioned snapshots/deltas.
2. Split launcher presentation state from conversation presentation state. A
   launcher-to-chat handoff carries an acknowledged draft/reference, not a second
   independent executor. Preserve attachments, account generation, permission
   mode, temporary status, and any active quick-ask run.
3. Put the conversation window in a signed, bundled GUI helper. Keep background
   workers distinct from GUI helpers. Route settings, focus, voice recording,
   screen capture, account changes, and quit through explicit asynchronous
   interfaces; do not instantiate the entire main application's DI container
   and start duplicate hotkeys, clipboard monitors, sync loops, or indexers.
4. GUI health must include a reply from the helper's main thread. IPC liveness
   alone is insufficient. The lightweight host must never synchronously wait for
   a helper. Validate request identity, peer identity, protocol version, byte
   limits, deadlines, and bounded concurrency.
5. Recovery restarts only the affected helper with a bounded retry budget. An
   uncertain write or tool result is reconciled, never replayed. A stale helper
   generation must lose the ability to mutate state or commit delayed results.
6. Move launcher, screenshot, and clipboard GUIs into separate processes only
   after the chat ownership/handoff contract is verified. Retain existing typed
   worker pools and their independent recovery policies.

## Acceptance gates

- Freeze the chat helper's main thread for 30 seconds: launcher, screenshot, and
  clipboard shortcuts still respond within an explicitly measured latency budget.
- Stall a clipboard read: main-queue callbacks still run; repeated requests stay
  bounded; closing the panel invalidates every pending delivery.
- Stop an OCR/media helper: only its requesting operation fails or times out.
- Kill the chat helper during draft transfer, approval, local inference, and tool
  execution: drafts survive according to the persistence contract and no
  side-effecting command executes twice.
- Verify signed release and development bundles, fresh/existing permissions,
  account switching, temporary-chat cleanup, app termination, and restart.
- Measure resident memory and cold/warm opening latency before expanding the
  number of persistent GUI helpers.

## Validation, 2026-10-22

- First focused coverage run: 63 methods, 61 passed. The two failures were stale
  clipboard tests which attempted to operate on voice records without selecting
  the voice tab. Both now select the corresponding visible category.
- Narrow retry plus additional diagnostic/lifecycle coverage: 14 methods passed.
  Across both runs, 68 distinct methods ultimately passed. The retry covered
  `MainThreadHangMonitorTests`, `AskTranscriptPreparationTests`, and only the two
  failed methods in `WorkflowControllerProcessingTests`.
- Command wall times, including preparation/build/discovery/execution: 371.51 s
  for the first coverage build/run and 84.70 s for the narrow retry (456.21 s total).
- Merged scoped LLVM profiles cover 278 of 291 executable changed production
  lines (95.53%). This is changed-line coverage, not whole-project coverage; see
  `docs/validation/feature-isolation/changed-line-coverage.json`.
- The instrumented application and test binaries linked successfully. The final
  hosted-text test verifies asynchronous text delivery and nonzero layout.
- `/usr/bin/sample <owned-child-pid> 1 10 -file /dev/stdout` was separately checked
  against an owned sleeping child: exit 0, 13,165 stdout bytes containing a call
  graph. Diagnostic tests inject the capture runner and verify limits, retention,
  private file permissions, failure cleanup, and cooldown without sampling or
  modifying the user's running application.
- The app-delegate startup/termination wiring and a real end-to-end 30-second GUI
  freeze were not exercised. No GUI helper is installed by this change. The hard
  process-isolation acceptance gates above remain outstanding.
