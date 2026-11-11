# Feature usage analytics contract

The client uses `AnalyticsEventReporting` and the existing
`POST /api/v1/analytics/events/batch` transport. Feature processes forward events
to the host through `analyticsEvent`; the host owns the settings-aware reporter,
persisted queue, app session ID and network transport. The opt-out still clears
the pending queue and cancels delivery. Local keyword ranking and help counters
remain separate and are not uploaded.

## Events

All new events include `feature` and `analytics_schema=1`. All properties remain
strings. A run has one `started` event and at most one terminal event, linked by
`flow_id`. Terminal events include monotonic elapsed `duration_ms`.

| Feature | Events | Meaning |
| --- | --- | --- |
| Launcher | `launcher_opened`, `launcher_action_executed` | New presentation; an admitted action, not a search refresh or keystroke |
| Ring | `ring_opened`, `ring_action_triggered` | Presentation; selected action type, without titles or targets |
| Screenshot | `screenshot_started/completed/failed/cancelled`, `screenshot_action_executed` | One screenshot interaction, including scrolling; output and follow-up actions |
| Translation | `translation_started/completed/failed/cancelled`, `translation_action_executed` | Explicit translation runs and result actions; imports and window handoffs do not start another run |
| Clipboard | `clipboard_opened`, `clipboard_action_executed` | Panel presentation and actions, including clipboard actions in the launcher; background capture is not usage |
| Keyword | `keyword_activated`, `keyword_executed` | Activation; explicit execution or first use of a live result during that activation |
| Workflow | `workflow_started/completed/failed/cancelled`, `workflow_actions_completed/failed` | Script invocation and separately reported output actions |

`action_executed` describes invocation, not confirmed OS delivery. Only lifecycle
terminal events express completion or failure. Clipboard paste and ring key events
must not be interpreted as confirmed text insertion into another application.

Keyword live previews do not count as executions. Explicit submits have
`execution_kind=submitted`; chained keyword invocations use `workflow_chain`; consuming a live result uses `result_action` once per
activation. Workflow reruns requested by output have `execution_kind=refresh` and
must be excluded from user-submission counts. A workflow's successful script run
and its output actions are distinct: action events can carry `parent_flow_id` to
reference the script run. Script truncation is a failed run, even when partial
output remains visible.

Translation with all engines failing is a failed run. A result with at least one
successful engine is completed; mixed results carry `result_type=partial_success`.
A save failure recovered by copying a screenshot still reports a failed save with
`result_type=clipboard_fallback`.

`entry_point` currently identifies the owning surface (launcher, screenshot,
clipboard, or translation input/selection/screenshot/launcher) or a known trigger
(ring/hotkey). It is not a complete cross-feature attribution graph. Screenshot
recording/GIF sessions are not counted as screenshot captures.

## Privacy and dimensions

Only built-in plugin IDs and canonical built-in keyword IDs are uploaded. Custom
aliases and custom workflow identifiers are excluded. Workflows with a gallery
origin matching the bundled gallery can expose that gallery ID; this is provenance,
not a claim that the installed files are unchanged. Other workflows are grouped as
`custom`. Runtime, action, content type and capture mode are fixed enum values.
Language statistics use supported common language codes or `other`.

Never send queries, selected text, clipboard payloads, image pixels, paths, URLs,
script contents, workflow titles, or raw error messages. The client property
allowlist and server feature-event validator enforce bounded metadata. These
statistics are best effort, not billing or audit records.

## Routing and delivery

The analytics transport uses the shared endpoint selector's latency-optimized
order, including its explicit endpoint preference and cooldown behavior. No new
probe loop is introduced. HTTP 401 can retry anonymously as before; retryable
errors fail over without changing event IDs. Business request latency is not
mixed into probe latency.

The server authenticates signed-in event requests from regional Redis snapshots.
A missing runtime auth service or cache snapshot returns 503; no database fallback
is permitted. Anonymous requests do not need account state.

The event writer and consumer both use `RedisURL`, rather than mixing a billing
Redis writer with a general Redis consumer. The writer has an independent pool,
bounded I/O and no internal retries. Redis Stream enqueue success returns 202;
a failed enqueue or disabled recorder returns 503 so the client retains its batch.
The existing consumer batches upserts to PostgreSQL and ACKs only after success.
Retries are idempotent by event ID; repeatedly failing events use the existing DLQ.

Deploy server support before the client. Older servers reject unfamiliar event
names permanently. Redis durability, stream capacity and DLQ monitoring remain
operational requirements; the existing bounded client queue and IPC are not an
unlimited durable journal.

## Validation scope

- `AppAnalyticsReporterTests`: opt-out, queue/retry behavior, fastest endpoint and failover.
- `FeatureUsageAnalyticsTests`: terminal-event races, content-free metadata, host forwarding.
- `FeatureUsageIntegrationTests`: live keyword results versus submissions, workflow success/failure, translation reuse.
- `ScreenshotCoordinatorTests`, `RingControllerTests`: real controller paths with synthetic UI/capture dependencies.
- Existing plugin, translation, workflow-action, clipboard and quick-result suites cover affected callers.
- API feature analytics tests exercise every event contract and invalid metadata;
  HTTP integration uses Redis with no permitted primary database queries.

Dashboard aggregation and presentation are intentionally a separate follow-up.
