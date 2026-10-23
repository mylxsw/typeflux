# Consolidated macOS process ownership

Status: implemented for local acceptance; packaged runtime and resource measurements must be collected on a user's interactive Mac. Do not launch the development app on the remote build host.

## Owners and startup

| Owner | Responsibility | Startup / retention |
| --- | --- | --- |
| Host | Menu bar, one global input listener, launcher, clipboard monitor/history, ring, translation, settings, notes, word book, help, system monitor, account refresh and conversation cache | Application lifetime |
| Voice | Dictation, editor recording, transcription and selected speech model | Warm at startup; retain selected speech model throughout application lifetime |
| Chat | Chat windows, editor insertion transactions and interactive agent state | On demand; retire after 120 seconds only when hidden and without input, voice, loads or agent work |
| Screenshot | Capture, editors, pins and screen recording | On demand; retire after 180 seconds only without windows, pins, capture, recording or unsaved sessions |
| Background | Sole filename/content index service, index management and shared media decoder execution | Warm at startup; retire after 180 seconds only when both indexes are off and no jobs/helpers remain |

These are five **business owners**, including the host (four child owners). They are not a promise of five rows in Activity Monitor: native decoders, document readers, inference helpers, MCP tools and macOS services are separate OS processes. Logical feature destinations remain unchanged in commands and shortcut traces. The supervisor maps destinations to owners before deciding whether to launch a child. Old presentation-role CLI invocations are rejected.

The background entry point bypasses `DIContainer`, application delegates and the window/workflow graph. It constructs only index services and their module adapters. Screenshot startup bypasses `WorkflowController`. DI module registration is restricted to each actual owner's capabilities. Existing injected test controllers retain their local dependencies.

## Speech takes priority

Only the voice owner constructs an active production editor recorder. Launcher/chat editors retain selection ranges, UI state and cancellation, and send session-scoped commands to that owner. Live level/transcript messages carry the recording session ID; late messages cannot modify a new session. The microphone-start timestamp is sent before recognizer connection completes, so holding/releasing a shortcut preserves the original timing rules. Editor recognition/rewrite retains its own foreground-priority source until the entire transaction ends. Another editor cannot claim an occupied recorder. Cleanup retains ownership until the asynchronous operation has ended.

The selected speech model is not subject to the semantic helper's 60-second idle policy. Existing selected-model preparation and recording-start audio buffering remain intact. Cloud-only routes do not deliberately preload unrelated local speech weights. Loading/preparing a model must not delay capture or discard the initial audio. Speech model memory is an intentional latency tradeoff and is excluded from any model-free baseline target.

## Input and IPC

One listener serves all global bindings. The event tap drains a dedicated sleeping run loop. A recursive state lock serializes tap events, binding refresh, stop and gesture timers; callbacks cross back to the existing UI boundary. Carbon hotkeys retain their application event delivery and Accessibility fallback. This prevents UI layout from starving the tap, but does not promise that a busy UI thread can present a window instantly.

Each child keeps its private inherited Unix socket. There is no listener port or credential file. Routed timeout budgets now cross both IPC hops, including long transcription and decoder requests. Authentication/session/channel checks on API/cache calls remain in the host.

The filename API retains its synchronous protocol for the existing search work queue, but production lookup runs remotely. The bridge refuses to wait on the main thread, has a deadline, and propagates caller cancellation. Content search is asynchronous. UI instances mirror bounded state/results and never start index watchers, open content databases, or load semantic models.

Media inputs/results remain in the existing operation-private directory. RPC sends bounded control metadata, not base64 image copies. The decoder validates UUID-directory correspondence, directory ownership/mode, protocol options and size/deadline bounds. Existing input-version checks and output validation remain at the producer/extractor. Screen-recording export retains its existing recoverable directory/streaming-progress path.

## Resource admission

- Media execution: at most two running jobs; at most 24 retained running/queued/completed-unacknowledged jobs. Queued requests expire within their own budget; queue saturation and cancellation do not consume decoder fault-recovery attempts. Superseded disposable callers cancel their jobs. Explicit recording exports retain their established separate admission and recovery policy.
- Shared high-memory native decoder/embedding admission in the background owner: three live helper reservations. A reservation is released only after actual collection. Cheap document I/O readers, speech inference and external MCP processes are outside this high-memory pool.
- Content indexing retains its existing serial owner, checkpoint batching, memory/thermal/low-power controls and CPU time slicing. Foreground media/voice activity pauses background work. Busy sources are tracked independently with monotonic epochs, so one source finishing cannot resume indexing while another remains busy, and delayed packets cannot restore obsolete state.
- Existing query/index semantic fault domains remain separate. Their models are bounded by the shared high-memory helper pool; this change does not claim identical semantic weights share one physical helper. Avoiding a blocked query behind a background batch remains the reason for this separation.
- The compatibility image cache has a 64 MiB cost limit in addition to its entry bound. Native launcher icons and visible image projections retain their existing scoped bounds. This is not a hard RSS cap, a whole-product 256 MiB cache guarantee, or a measured 600 MiB idle result.

Limits deliberately describe what is enforced. Foundation/AppKit/WebKit allocations, transient image conversion and speech weights still require local footprint measurements. A fixed CPU-core cap and a 512 MiB aggregate image working-set guarantee are not provided by these admission limits.

## Cancellation, recovery and exit

Media cancellation is acknowledged only after actual reaping. A broken channel cannot falsely release a frontend lease. When a child owner exits, its backend jobs are cancelled and operation directories are removed only after completion/collection. Explicit export recovery data is not treated as a disposable operation directory.

Retirement checks visibility, drafts, active agent state, recording, pins and worker activity. The supervisor rechecks eligibility and in-flight routes before retirement. Draft persistence and cleanup must be acknowledged before ending the child. In-flight screenshot transfers and fallback saves block retirement, and screenshot handoffs check account generation before and after image loading. Private-staging failures use the same original-image save fallback as rejected delivery. Voice never idles out. A screenshot pin or unsaved recording intentionally retains its owner.

Normal quit stops global input and warmup, persists host/editor drafts, drains UI owners, then closes the backend. Backend acknowledgement also waits for actual media/index helper retirement, rather than merely cancelling their tasks. Active voice or unconfirmed persistence refuses clean shutdown; the app remains open with a localized notice and can retry. The supervisor does not kill a child merely because its durable cleanup timed out. Successful owners can restart on demand after a cancelled quit. Existing POSIX ownership/reaper protections are preserved.

Module health migrates once to new owner directories. The strongest previous restriction wins, including corrupt records becoming quarantined. A migration marker prevents stale files undoing a later explicit user recovery. No business database, recording path or index format is renamed.

## Diagnostics and acceptance

Settings → Shortcut diagnostics now includes business process PID, physical footprint, CPU percentage and managed-operation counters. CPU is derived from cumulative counters only for matching process lifetimes, and sampled while that window is open. Export includes the process snapshots alongside the existing stage-level shortcut data. Unknown counters remain unknown rather than zero. The existing CLI remains a log parser and does not start app processes.

On an interactive Mac:

1. Start the packaged build. Verify launcher, clipboard, ring, translation, notes, word book, settings and help reuse the host PID.
2. Open chat and screenshot; confirm at most the five business owners appear. Distinguish helper/system rows from owners.
3. Record in dictation, launcher and chat. Check initial syllables, hold/tap/auxiliary gestures, partial/final text, cancellation and selected-model reuse.
4. Exercise filename/content search and index settings, OCR, thumbnails, capture/translation follow-up and long recording export. Confirm their progress/cancellation/recovery remains usable.
5. Close chat/capture with and without drafts, tasks, pins and unsaved sessions. Verify protected state stays alive and eligible owners retire at the documented delay.
6. Quit during ordinary idle, recording, indexing and unsaved work. Verify refusal preserves the app/state and a later quit succeeds.
7. Export diagnostics after warm/cold shortcuts and after ten idle minutes. Compare total Activity Monitor footprint/CPU, business-owner snapshots, p50/p95 shortcut stages and speech preparation timing with the previous build.

Do not infer local runtime success from a build or mocked RPC test. Packaging, Accessibility, microphones, real screen capture, model load latency and measured memory/CPU remain local acceptance items.
