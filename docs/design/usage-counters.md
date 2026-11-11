# Operation counters

## Contract and delivery

Detailed operations use the existing fastest-endpoint analytics transport and `/api/v1/analytics/events/batch`. Feature processes forward to the host's consent-aware reporter. They never create their own network queues. Existing lifecycle events remain available for duration and distinct-device analysis; their traffic and semantics are unchanged.

`usage_counters` properties contain schema `1`, a random installation epoch, a Beijing calendar day, and a JSON string of `[metric ID, cumulative count]` pairs. No text, paths, URLs, custom names, error text or arbitrary dimensions are allowed. The API catalog `internal/domain/usage_metrics.json` is authoritative; `scripts/generate_usage_metrics.py <catalog> --check` validates the generated Swift IDs. IDs are append-only; unused reserved IDs are not evidence of instrumentation.

Increments update one scalar preference and an in-memory counter. Date conversion is cached by calendar day. A dirty reporter sends after 60 seconds; 128 counters fit in each snapshot and up to 20 snapshots share one request. Empty reporters do not poll. Snapshots are structural compression, not gzip: 10,000 uses of metric 266 become `[[266,10000]]`, 13 UTF-8 bytes before the envelope. There are no individual click records. Preference persistence follows UserDefaults durability; a forced process or power loss can lose writes not yet persisted by the OS.

Counters from the last 30 days survive restarts and transient failures. Acknowledgements are intentionally not persisted: restart replays the same cumulative values. In-flight increments are acknowledged only up to the sent value. Disabling statistics deletes pending counters and rotates the epoch. A request already accepted by the server cannot be recalled.

The server validates bounded, known IDs and totals, then uses the existing local Redis stream. The request does not write PostgreSQL. The consumer coalesces duplicate keys with MAX and performs a conditional UPSERT only when the received count is greater. Retrying, out-of-order delivery and regional failover therefore cannot add the same counts twice. Counter snapshots are excluded from raw analytics_events. One row exists per active installation epoch/day/metric, rather than per click. Existing maintenance deletes counter rows older than 180 days in bounded chunks; dashboard periods remain at most 90 days.

## Instrumented operations

| Area | Operation dimensions |
| --- | --- |
| Launcher | Existing action kinds and result types |
| Ring | Action type and selected built-in feature |
| Screenshot | Capture mode, output/follow-up action, committed annotation tools, successful undo/redo/delete |
| Recording | Video/GIF start attempts, completion/failure/cancellation, pause/resume, export attempts/success/failure, completed recording seconds |
| Translation | Copy, speak, write back, rerun, swap, word-book and configuration actions through the existing dispatch |
| Clipboard | Existing action dispatcher: paste, plain-text paste, pin, edit, copy, preview, export, delete and other supported actions |
| Keywords | Safe built-in plugin type or custom; existing keyword execution counting rules apply |
| Workflow | Source, actual runtime, execution mode and lifecycle; refresh is explicitly a separate category |
| Voice | Existing dictation pipeline start/completion/failure |

A committed annotation counts once regardless of pointer samples; a cancelled draft counts zero. Undo/redo are edits and do not count another drawing. Automatically applied mosaics count one operation, not one operation per detected rectangle. Recording permission rejection before admission does not count as a start. A startup failure after admission does. Recovery previews do not invent recording starts; exports from recovered media still count. Custom keyword/workflow contents remain private; existing safe built-in workflow IDs remain available in the legacy detail view.

## Validation and remaining gates (2026-11-11)

- The isolated Swift counter implementation compiled and executed with fake transport/client-info dependencies: 10,000 increments, bounded snapshots, restart replay, failed send/retry, increments during a send, consent clearing, epoch rotation and actual runtime mapping passed. Final execution took 3.13 seconds, excluding compilation. This is not an app build or a network benchmark.
- Fifteen changed Swift source/test files passed syntax parsing. The canonical catalog and Swift table agree on 363 IDs.
- XCTest cases additionally cover mapping, payload limits, persistence and consent. Editor and recording integration tests cover committed operations and a single cancellation. These app suites have NOT executed in this environment: the normal runner failed under Python 3.9 (0.40 seconds total); retry with Python 3.14 reached SwiftPM but nested sandbox initialization failed (2.07 seconds total). Escalated execution is prohibited by the environment's approval policy.
- Go focused validation passed for input bounds, SQL repository behavior, maintenance, growth response and HTTP-to-Redis collection with an unavailable primary database. The HTTP test includes both legacy events and compressed counters, authentication cache failure and failed enqueue.
- Dashboard production build, lint and seven page interaction tests passed. Tests include cross-day aggregation, searching and recording filtering without contradictory empty states. No live production screenshot review has been completed for this change.
- The real PostgreSQL pipeline test now includes duplicate/reordered counter snapshots and validates final totals and dashboard JSON. It was explicitly SKIPPED because FEATURE_ANALYTICS_TEST_DATABASE_URL is absent. Do not report this as a passed end-to-end test.

Before release, run the focused app suites including UsageCounterReporterTests, AppAnalyticsReporterTests, FeatureUsageAnalyticsTests, FeatureUsageIntegrationTests, ScreenshotAnnotationEditorTests, ScreenRecordingCoordinatorTests, ScreenshotLongImageEditorTests and RingControllerTests in a normal macOS build environment. Run the real pipeline with a disposable migrated PostgreSQL database and Redis via the existing scripts/test_feature_analytics.sh. Apply API migration 00088 and deploy the accepting API/consumer before distributing the client; older APIs reject the new event. Deploy the dashboard after the API. This change is not yet release-verified.
