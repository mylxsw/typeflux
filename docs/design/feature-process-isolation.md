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
Production canonical engines now acquire a nonblocking directory lease before
loading records. The device API separately owns its account directory before
reading the sync journal or starting an uploader. These leases exclude other
participating processes; SQLite serialization alone still cannot transfer
execution ownership or in-memory state.

The device-execution change merged before this boundary. Its account-scoped
engines and sync journals remain together. `AskApplicationService` now retains
one production API graph; the conversation controller and fallback workflow
assistant resolve it instead of constructing competing caches or upload loops.
Explicitly injected API graphs remain isolated for fixtures.

The lease is retained for the owner's lifetime, across awaits, task cancellation,
and window closure. A rejected acquisition does not mark an engine loaded; a
later explicit retry reads fresh records after the old owner exits. Locks are
not unlinked on release, use close-on-exec, reject symlink/non-regular/hardlinked
lock files, and are acquired without waiting for another owner. Different account
directories remain independent. Ownership errors have localized user feedback.
Raw engine/device initializers retain an opt-out default for injected fixtures;
every production construction path enables exclusive access. Older binaries
that do not participate in this protocol are not fenced by advisory file locks.

This is a storage-ownership boundary, not a GUI or execution-driver split. The
existing durable execution journal still decides whether a model/tool call may
be dispatched. UI models still drive calls, temporary drafts still live in their
current model, and no helper process, IPC handoff, or automatic takeover is
introduced by this step. `shutdown()` stops sync retries, not engine ownership;
releasing a live service during an uncertain operation would be unsafe.

## Draft handoff groundwork

Launcher-to-chat transfers now save an account-scoped recovery copy and read it
back before clearing the launcher. The acknowledgment compares the serialized
payload off the main actor, preserving attachments, references, source context,
storage choice, skills and MCP selection without requiring exact subsecond Date
round-trips. A failed save, unavailable/discarding cache, changed input/account,
changed selection, or cancellation cannot acknowledge the transfer. Retrying an
unchanged transfer reuses its identity and the displaced draft's identity.

Recovery copies remain available after navigation or restart. The active copy is
hidden from the saved-draft list and edits update it. Writes to the same copy
are ordered across debounced saves and navigation; unrelated accounts and drafts
have independent chains. Choosing temporary mode schedules cleanup independently
of subsequent debounced edits. Deletion installs the existing cache tombstone,
so a late save cannot recreate a consumed copy. Temporary inputs are not staged
in persistent recovery storage, and cancelling departure from a temporary chat
keeps the editors and current selection intact.

Submitting binds the backup to one conversation/message identity. Only a valid
accepted-run response containing that exact user message may consume it, after
the destination conversation has been persisted. A failed/uncertain send keeps
the backup; cleanup failure does not interrupt the accepted run or replay the
request. Restoring a backup requires an explicit user action and never submits
it automatically. A remaining backup is not evidence that an uncertain remote
operation never executed. Recovery restores the standard permission mode; it
does not persist a grant to run privileged tools.

This is a durable draft contract inside the existing application, not IPC or an
execution-owner transfer. Quick-ask continues its existing run in the same
model. The signed GUI helper, service-owned execution, peer/generation checks,
and cross-process temporary-state handoff remain required. The UI must not
launch another executor against this cache as a shortcut.

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

## Storage ownership validation, 2026-10-22

- The focused scope passed all 78 distinct methods: engine behavior, budget
  accounting and reentrancy; device synchronization; application composition;
  injected model completion; directory ownership; and shared UI-state discipline.
  The fallback workflow assistant's API routing is checked by the composition
  and production-factory tests, not by claiming a full workflow-editor test run.
- A real Perl child process fails a nonblocking lock while the Swift owner holds
  it and succeeds after release. Other tests cover path aliases, independent
  directories/accounts, invalid lock files, retained lock-file identity,
  localized errors, denied read/write/delete/import/budget paths, fresh reads
  after takeover, temporary state, and cancellation retaining ownership.
- After correcting the inert service singleton's actor-isolation annotation,
  the smallest relevant follow-up scope passed all seven methods. There were no
  failing tests. Both runs rebuilt/discovered tests before execution; neither is
  reported as a verified build-cache hit.
- First command: 452.20 s (433.47 s preparation/build/discovery). Follow-up:
  74.60 s (68.61 s preparation/build/discovery). Total command wall time:
  526.80 s. Coverage replaced plain test runs.
- Merged scoped LLVM profiles cover 69/72 changed executable Swift lines
  (95.83%); see `docs/validation/feature-isolation/ownership-coverage.json`.
  Uncovered paths are the authenticated production engine factory and an unusual
  non-contention `flock` error. This is not whole-project coverage.
- Tests used temporary stores and synthetic model/transport dependencies. No
  real inference, production account upload, installed-app replacement or GUI
  helper freeze test was performed. The GUI acceptance gates remain outstanding.

## Draft handoff validation, 2026-10-22

- The first focused coverage command passed 123 methods across seven suites:
  `AskDraftHandoffTests`, `AskOpenChatTests`, `AskNoteChatTests`, `AskQuickAskTests`,
  `AskTemporaryConversationTests`, `AskConversationTests`, and
  `AskAgentBindingInteractionTests`. These cover the transfer contract, its
  launcher/note/quick-ask callers, temporary navigation, submission/retry, and
  operation/account fencing. Command wall time: 224.85 s.
- Review found two additional ordering/privacy edges. The follow-up passed all
  63 methods in the first four suites, including a new held-write ordering test
  and immediate editing after choosing temporary mode. Across the successful
  commands, 124 distinct methods passed. Follow-up wall time: 215.60 s; successful
  command total: 440.45 s, including compilation/discovery/execution. Both rebuilt
  tests; neither is reported as a verified build-cache hit.
- One intervening build failed in the Swift compiler before tests executed:
  an unqualified `error` assignment inside `catch` triggered a type-checker
  assertion. Explicitly using `self.error` fixed it. That failed command did not
  emit a total wall time and is excluded from the measured total above.
- The final binary's own LLVM profile covers 124/126 changed executable Swift
  lines (98.41%); see `docs/validation/feature-isolation/handoff-coverage.json`.
  Profiles from the earlier binary are not used in this figure because the
  changed persistence function has incompatible counters. This is changed-code
  coverage, not whole-project coverage.
- Fixtures reopen SQLite storage, inject unavailable/altered storage and SQL
  write/delete failures, hold writes across cancellation/account changes, and
  verify exact-message acknowledgment without real API requests. A recovered
  draft is never automatically sent. An installed-app crash/restart, real IPC,
  signed helper launch, and the 30-second GUI freeze acceptance gate have not
  been exercised; this step does not claim process isolation.
