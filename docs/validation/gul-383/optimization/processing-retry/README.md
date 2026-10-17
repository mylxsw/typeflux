# GUL-405: per-file progress and recovery

Base: `3b63419580ea6e01c8187161d903f28ce396ee59` (contains PR642 merge `386fc80897b84aee892f4043698ad01097473de6`). This slice adds durable row status, fixed-code localized reasons, saved text/media progress and one-file retry. It does not complete GUL-405; download recovery and necessary real-model/native-input checks remain.

The existing jobs/work_queue, document cursor, vector_pending, media segments, audio/video checkpoints and scheduler remain authoritative. Retry inserts one queue entry under a generation/state check. It preserves the current failure reason until processing resumes, all compatible vectors, other files, priority and checkpoint ownership. Existing indexing validates metadata before publication and changes generation only for the changed file. Password-protected/unsupported documents and unavailable/skipped files have explanations, without an automatic retry loop.

The service rechecks current settings, scope, reader authorization, cancellation and lifecycle ownership. A pending retry intent covers the race with a drain that has already observed an empty queue. Paused work remains queued and resumes through the normal scheduler. Details responses from an obsolete lifecycle are discarded; failed reads clear the visible page. UI retries cannot overwrite a different tab/page.

Counts are saved progress, without a fabricated total or percentage. Media staging is explicitly described as potentially incomplete; silent-only audio is displayed as skipped. Reasons pass through an allowlist; exception text, contents and worker internals are not rendered. Five localization sets have matching keys.

## Validation scope

`run-coverage.py` invokes `make coverage` with the explicit FILTER recorded in each command JSON. The source list is only a build closure, not a claim that every included suite ran.

- `SemanticProcessingRetryTests`: real malformed file → native file reader → persisted failure → native retry button → repeated failure → repair → one-file retry → service query; unchanged other-file generation; partial restart/vector reuse; queued pause/resume; revoked scope/disabled settings/stale generation; independent persisted media progress and fixed reason localization.
- `SemanticIndexDetailsTests`: existing paged queue/history read and timing caller.
- Two selected `SemanticFileServiceTests` methods: targeted filesystem reconciliation and completed discovery restart/manual rescan.
- Existing details render method: directly affected settings presentation caller.

Debug build, Apple M4 / 16 GiB, macOS/Xcode versions in `environment.json`. Embeddings/query vectors and model verification are deterministic fixtures; the corrupt/repaired text files and file-reader IPC are real. Media progress uses persisted synthetic vectors/checkpoints, without re-running prior accepted media extraction matrices. No real weights, release latency claim, long stability result or external-player behavior is asserted.

## Self-review

Reviewed entry-to-queue-to-index-to-query/UI flow; nil/unknown codes and unsupported/encrypted files; repeat failures and persistence; generation, cancellation and revoked scope; lock/transaction boundaries, reader/embedding cleanup and paused ownership; SQL binding, no raw error disclosure; localization and comment consistency. Fixed the empty-drain retry wake race, silent-audio status, stale details after revocation and tab/page ownership before final validation.

## Results

Nine distinct methods passed across runs: the initial seven-method run had five passes and two failures; the four-method repair run had three passes and one fixture failure; the final single-method run passed. The two caller patterns with spaces initially matched no methods; the repair command selected them with wildcard patterns. This is not a claim that the final test binary ran all nine methods together.

Application changed executable lines: **206/224 (91.96%)**. File-reader helper and native media runtime: **0 changed lines, not applicable**. The raw failure profiles remain part of the cumulative evidence. Production source hashes and all 1131 application objects match across the test-only repairs before counters are combined. Profiles are deduplicated and old baseline profiles are excluded.

Uncovered application paths: the Identifiable getter; details-load failure display and rejected-retry message; longer duration formatting; document byte-offset presentation. Exact lines are in `changed-coverage.json`. No extra tests were added to pursue the former 90% target.

All coverage commands, including three build failures and two failed test invocations, took **832.27 seconds** in total. Final single-method command: **70.88 seconds**, including build/discovery/report (test execution 0.195 seconds). The copied module-cache failure, source-change build guard and two missing `try` expressions in the test macro are preserved. Native fixture storage now separates index artifacts from content and waits for ready/failed with a bounded deadline. The remaining fixture failure used the integer audio-progress initializer (sample counts); explicit Double seconds fixed it without changing media production code.

Three changed presentation/store files pass strict lint; the service has 32 existing findings and none on changed lines. Swift/AppKit deprecation warnings are retained in the logs. Five localization sets each have 46 matching details keys. The failure and partial light/dark PNGs were visually inspected and contain the intended rows and actions.

Rollback: revert this PR. No schema was introduced; existing queue/checkpoints and compatible index data remain readable.

## Evidence

Original build and runner failures are retained with full command wall times. The copied cache's absolute module paths were rejected; its ModuleCache was moved aside in the task-local copy. No old passing results or coverage counts are reused. Final profiles are selected by change from `profiles-before.json`, merged independently, and intersected with added/modified executable LCOV lines. Application/helper/runtime denominators and uncovered lines are in `changed-coverage.json`. Inputs, production objects, actual native/test binaries, profiles and tools have SHA-256 manifests. No native helper/runtime source is changed in this slice.
