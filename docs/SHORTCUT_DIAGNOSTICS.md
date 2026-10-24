# Shortcut response diagnostics

Open **Settings → Advanced → Diagnostics → Open Diagnostics**.
Shortcut timing recording is enabled by default and can be disabled there. All
records remain local and independent of analytics sharing; nothing is uploaded.

The panel has two categories:

- **Runtime overview:** current business-process footprint, CPU between consecutive
  observations, active operations, current module health/failure classifications,
  and metadata for retained automatic main-thread hang samples. Raw stack files
  can be inspected through **Open hang folder**; they are not embedded in JSON.
- **Shortcut response:** ring, translation, launcher, clipboard and screenshot
  timelines, feature/process-state filters, sample counts and P50/P95.

Choose last hour, last 24 hours, all retained data, or a custom local date/time
range. Endpoints are inclusive. Shortcut filtering uses trace start dates and
keeps complete timelines, including stages after the selected end. Filtering is
performed before sample/event limits so older selected periods remain accessible.
The panel refreshes every five seconds while open and stops when closed.

**Export selected period** produces `typeflux-diagnostics.json`, a versioned JSON
bundle with the selected UTC boundaries, bounded shortcut report, current process
resources/module health and hang metadata. It always includes all features in
that period, independent of the shortcut category's feature/temperature filters.
`currentSnapshotAt` marks the current snapshot; current metrics are not historical
metrics for a selected past period. `previousProcesses`, when available, allows
CPU deltas to be reproduced using matching process lifetimes and monotonic clocks.
Unavailable sources are listed in `collectionFailures`; they are never silently
presented as healthy. An empty retained hang list does not prove absence of hangs.

Exports remain capped at 2 MiB and exclude private payloads, raw stacks and paths.
Shortcut storage retains at most 16 × 256 KiB files, expiring after seven days
without updates. Existing 200-sample/2,048-event display bounds still apply;
`droppedEvents` indicates omitted events. `invalidLines`, `rejectedRecords` and
`unreadableFiles` describe scanned input integrity across the retained files,
including records that cannot be assigned to the selected period. Rejection
reasons distinguish undecodable data, protocol version, invalid clocks/fields,
and stages more than five minutes after their trace start. This is not the same
as a measured shortcut failure. Existing CLI output remains the legacy shortcut
schema for compatibility; the panel export nests it under `shortcuts`.

## Measurement contract

- A trace UUID joins records from the shortcut, host and target processes.
- All durations use `ProcessInfo.systemUptime`, a common monotonic clock on this
  Mac. Wall dates are for browsing and are not subtracted to calculate latency.
- Plain registered shortcuts start at the native hotkey callback (before its
  main-queue forwarding). Gesture shortcuts start when the gesture is recognized
  as an action. OS delivery before these callbacks and gesture recognition time
  are outside the measurement. These two input forms should not be compared as
  physical-key-to-screen measurements.
- The terminal display event is an `isVisible` check on the next main queue turn
  after submitting the window show request. It is **not compositor completion,
  physical first paint, animation completion, or proof the editor is responsive**.
  Instrumentation never forces drawing or layout to manufacture a display event.
- Full display paths are instrumented for ring, translation, launcher, clipboard
  and screenshot selection. Other feature shortcuts include routing/handler timing, with a
  separate `handled` outcome; they are not counted as display successes. Voice
  gesture startup remains covered by the existing recording startup diagnostics.
- `targetCold` means no existing child was registered at routing time, possibly
  because an earlier prewarm is still starting it. `targetWarm` means a child
  exists; it does not guarantee module readiness or a prebuilt window.
- A handler returning is distinct from its asynchronous data/capture/window work
  finishing. Missing terminals stay incomplete. A failed IPC response does not
  prove that an external action did not execute. A visibility event can coexist
  with a later failed response; inspect the timeline in that case.
- Repeated launcher/clipboard shortcuts that close an existing session are marked
  `dismissed`. Screenshot shortcuts that switch an existing selection to full
  screen also use that non-opening outcome. Permission/busy/empty-history paths
  are marked `blocked`; cancellation/replacement is `superseded`.
- P50/P95 use nearest rank on visible durations only, within the selected filters.
  The denominator and other outcomes remain visible. Small samples are not a
  reliable benchmark. The exported report contains per-feature summaries split
  into all/cold/warm/unknown and every retained stage for independent analysis.

## Recorded stages

```text
recognized → callback → dispatched → hostReceived → hostRouting
    → targetWarm OR targetCold [→ spawnRequested → processStarted]
    → targetWireReceived → targetReceived
    → readinessStarted → readinessFinished → handlerStarted
        → clipboard: dataStarted → dataFinished
        → screenshot: captureStarted → captureFinished
        → windowOrdered → visibleNextTurn
```

`handlerFinished` can appear before asynchronous work finishes. Each row shows
cumulative milliseconds since recognition and the gap from the previous event,
plus the emitting process role, PID and app build. Gaps are not independent span
durations; asynchronous work can overlap. For analysis, compare matched stages:

| Interval | What it includes |
| --- | --- |
| recognized → callback | Source main queue scheduling |
| dispatched → hostReceived | First IPC and receiving task scheduling |
| hostReceived → hostRouting | Supervisor scheduling |
| hostRouting → targetWireReceived | Child acquisition/startup and second IPC |
| targetWireReceived → targetReceived | Target main actor scheduling |
| readinessStarted → readinessFinished | Bootstrap and module preparation gate |
| dataStarted → dataFinished | Clipboard worker scheduling, maintenance and history read |
| captureStarted → captureFinished | Screen snapshot acquisition |
| handlerStarted → windowOrdered | Feature preparation, including nested async work |
| windowOrdered → visibleNextTurn | Next main queue turn and visibility check |

## Detailed stages (schema version 2)

Paired `Started`/`Finished` events measure the named operation. They do not add
new waits or change execution order. Match the pair within a trace; for per-screen
operations also match `itemIndex` (one-based ordinal) and `itemCount` (screen count).
The dashboard shows the ordinal next to those stages and exports both fields.
No display identifier or display content is recorded.

| Feature | Additional detail |
| --- | --- |
| Ring | Single-modifier and registered chord paths start a trace at recognition. `ringPressed`, `ringReleased` and `ringCancelled` share that trace. `ringShowStarted`/`ringShowFinished` bracket menu presentation, followed by the next-turn visibility probe. Toggle-close and blocked requests remain separate outcomes. |
| Translation | Window cache reuse/creation, acquisition, layout, ordering, focus and monitor setup. `translationSelectionStarted`/`translationSelectionFinished` measure asynchronous selection capture; this can finish after the first visible event and cause another presentation. Toggle-close is `dismissed`. |
| Screenshot | `overlayStarted`, `oldOverlayRetired`, per-display `displayView`, `displayPanel` and `displayShow` pairs, focus, initial pointer/magnifier update, and `overlayFinished`. Snapshot capture retains its existing separate pair. |
| Launcher | State preparation, quick-app refresh, selection request creation, window cache/acquisition, layout, ordering, focus and monitors. Workflow refresh and selection context loading have separate background spans; do not add them to the opening duration if they overlap or finish after visibility. |
| Clipboard | `dataStarted` to `dataWorkerStarted` includes preparation and scheduling; `maintenancePlanFinished` to `dataWorkerStarted` narrows queue wait plus submission setup. Maintenance preparation/execution, voice history, clipboard history, pins and merge are distinct spans. `dataFinished` to `dataCallback` measures return to the main queue. Presentation model update, window cache/acquisition, layout, ordering, focus and monitors follow separately. Both list and shelf presentations are covered. |

`windowCached`/`windowUncached` describe window reuse, independently of process
warmth. Layout spans describe the existing content preparation calls; they do not
force layout completion. Quick-app refresh spans cover refresh/index kickoff and
icon preparation calls, not completion of background indexing. Focus spans measure
the focus request calls, not the time
until the editor can accept a physical key. Shelf animation remains outside the
visibility completion proxy. Repeated span names (such as a second translation
presentation) must be matched in event order, not by subtracting the last finish
from the first start.

Version 1 ring/translation recordings that only reached `handlerFinished` retain
the `handled` outcome, without a display percentile. Version 2 recordings for these
features require a visible or explicit non-opening outcome; a missing endpoint is
`incomplete`. A visibility event takes precedence over later dismissal/cancellation
in the same trace because the panel did open.

## Read the same data without the UI

The native command reads the same files with the same parser and summary code:

```bash
"$HOME/Applications/Typeflux Dev.app/Contents/MacOS/Typeflux" shortcut-diagnostics
# Optional alternate diagnostic directory, for a copied log set:
"$HOME/Applications/Typeflux Dev.app/Contents/MacOS/Typeflux" shortcut-diagnostics --directory /path/to/shortcut-latency
```

Output is JSON with `generatedAt`, `samples`, `summaries`, `unreadableFiles`,
`invalidLines` and `droppedEvents`. Each sample contains its trace and ordered
events. The CLI does not initialize AppKit or start feature processes. It exits 64
for invalid arguments and 1 for a directory read failure. A missing log directory
is an empty report, not an error. The dashboard displays the actual directory;
normally it is `~/.typeflux/cache/shortcut-latency`.

You can also open the app directly to the diagnostics window:

```bash
open "$HOME/Applications/Typeflux Dev.app" --args --shortcut-diagnostics-window
```

## Storage, retention and overhead

- New events use JSONL schema version 2; the reader also accepts version 1.
  Records contain only fixed stage/role names, UUIDs, timestamps, PID, build,
  dropped-event counts and optional one-based display ordinal/count. No shortcut chord, keyword ID, payload,
  clipboard text, file path, screenshot, token or underlying error is serialized.
- A private serial utility queue writes each process's own files; the input and
  UI threads never wait for disk. At most 512 writes can be queued per process;
  excess events are dropped and the next accepted event reports the count.
- Files rotate at 256 KiB. Rotation removes expired files and retains at most 64
  files across processes (about 16 MiB, with a brief concurrent-rotation allowance).
  The reader ignores files last modified more than seven days ago and returns
  the latest 1,000 retained traces. Active-file retention is based on modification
  time, rather than a strict per-event seven-day deletion guarantee.
- The directory is created with mode 0700 and files with 0600. A partial final
  line from an active writer is retried on refresh; malformed complete lines and
  unreadable/oversize files are counted separately. Recent files are read first.
- Disabling recording prevents new traces; existing in-flight traces may finish.
  Existing logs remain subject to retention. Settings propagate through the
  existing preference synchronization channel.
- Forced termination, disk failure, queue overflow or retention can leave partial
  traces. Never reinterpret absent stages as zero milliseconds.

## Collection and comparison

1. Keep the build, shortcut form and feature filter fixed. Collect first opens
   separately from repeated opens; check that each test intends to open rather
   than close an existing panel.
2. Collect at least several dozen ordinary uses per feature. Include periods of
   indexing/recording if they reproduce the delay, recording that workload outside
   the content-free trace. Do not infer a cold start from a slow sample alone.
3. Find the slow P95 samples and inspect the largest matched intervals above.
   Compare the same interval in fast samples. Keep failed/incomplete counts visible.
4. Make one optimization, collect the same workload and compare the matching
   feature/process-state groups. A search-query benchmark is not a shortcut-open
   benchmark; neither this visibility proxy nor app launch proves physical first
   paint. Use Instruments or an independent screen/input measurement if needed.

The initial instrumentation recorded existing behavior without changing process
structure, shortcut ownership, readiness gates or prewarming. The optimization
follow-up below changes preparation and cache timing separately.

## Validation on 2026-10-23

This checkout runs on a remote machine. Do not launch the development application
on this machine for subsequent verification. Use builds, focused tests and the
read-only diagnostics CLI here; validate physical shortcuts and interactive
behavior on the user's local Mac. The remote desktop observations below are
automation smoke checks, not verification on the intended interactive machine.

- `swift build` passed (successful incremental build: 64.37 seconds).
- Focused coverage passed 107 tests (73 XCTest and 34 Swift Testing), with no
  failures, using:

  ```bash
  make coverage SUITE="ShortcutLatencyTests ShortcutLatencyUITests FeatureRPCTests KeywordHotkeyTests ScreenshotHotkeyTests AskLauncherToggleTests ClipboardPanelControllerKeyTests ScreenshotCoordinatorTests"
  ```

  Total command wall time was 282.62 seconds, including the first instrumented
  build, discovery and execution. This is not a full-project test run.
- Scope mapping: the new suites cover trace joining, monotonic durations,
  incomplete/non-display outcomes, process-state summaries, percentiles, legacy
  command decoding, independent file writers, partial/corrupt/oversize records,
  retention and empty UI rendering. Existing suites cover the directly affected
  RPC, shortcut dispatch, launcher toggling, clipboard controls and screenshot
  state transitions.
- Measured line coverage for the new files was 74.77% for `ShortcutLatency.swift`,
  86.40% for `ShortcutLatencyReport.swift`, and 44.51% for
  `ShortcutLatencySettingsView.swift`. These values are below the repository's
  90% target; no project-wide or 90% changed-code coverage claim is made.
- `plutil -lint` passed for all five localization files, and all 72 diagnostic
  localization keys match across locales. `git diff --check` passed.
- Native CLI smoke checks passed: empty report, a synthetic three-process JSONL
  trace yielding a 350 ms cold summary, and invalid arguments returning exit 64.
  Synthetic smoke records were kept in a disposable temporary directory, outside
  the user's diagnostic logs.
- `make run` built the optimized development application (Swift build: 412.05
  seconds), verified its signature and launched it. The existing development
  profile does not match the selected signing certificate, so the repository's
  runtime-entitlement fallback disabled Sign in with Apple for this dev build;
  login was not part of this verification.
- The actual signed app's empty diagnostics window was inspected visually and
  through accessibility. Installed-app CLI reads also passed. Initial automation
  attachment timed out when no window was open; a normal quit and launch with
  `--shortcut-diagnostics-window` allowed inspection.
- Automated shortcut injection did not produce global-shortcut samples. Physical
  shortcut-to-window collection and populated-dashboard/export interaction still
  require actual key input. App launch and UI inspection are not presented as
  proof of that full path. No performance conclusion is drawn from these checks.

## Detail instrumentation validation on 2026-10-23

The follow-up changes preserve shortcut ownership, process structure and feature
execution order. No development application is launched on the remote machine.
Focused automated checks use synthetic content and injected diagnostic collectors;
physical shortcut latency and populated dashboard interaction require local testing.

- The initial focused coverage scope executed 199 tests (145 XCTest, 54 Swift
  Testing) in 127.56 seconds. One existing translation focus assertion failed
  in the combined run; all diagnostic assertions passed.
- A 22-method retry after collector concurrency cleanup took 114.17 seconds and
  reproduced only that focus failure. The focus test passed alone in a 43.24-second
  command. Diagnostic assertions were then folded into the existing translation
  cases, avoiding the extra window lifecycle. All 10 translation entry tests passed
  in 83.94 seconds, retaining the original focus assertion. A later combined run
  reproduced the focus failure, so its cause is not considered resolved. The final
  retained scope contains 198 unique test methods; the removed standalone case is
  excluded. Do not describe this scope as uniformly green.
- The scope covers recording/parser compatibility, modifier/chord correlation,
  ring outcomes, translation visibility and capture, launcher preparation,
  clipboard worker-to-main delivery and list/shelf presentation, synthetic
  per-display screenshot overlays, RPC and existing shortcut behavior.
- All five localization files pass `plutil -lint`; all 129 diagnostic keys match
  and every stage has a label. `git diff --check` passes.
- Strict SwiftLint on touched source files is not green: it reports line, function
  and type length, complexity and other existing style rules. Instrumentation also
  increases some function lengths. No lint-success claim is made; broad style
  cleanup is outside this diagnostic-only change.

- Synced concurrent upstream commit `34b9c7c2` and rebuilt the final client. The
  affected launcher/translation scope executed 25 methods: 24 passed; the same
  translation focus assertion failed in the combined run. Runner wall time was
  255.42 seconds, including a 217.05-second build. This remains a validation
  limitation for local testing; the assertion was not weakened and feature focus
  behavior was not changed to make a remote test pass.
- Approximate complete command wall times, including coverage report generation
  where successful, were 127.67, 114.24, 46.57, 89.70 and 255.50 seconds for the
  initial scope, collector retry, isolated focus check, translation suite and
  post-rebase scope respectively. Earlier values above are the runner-reported
  build/discovery/execution times.
- A union of focused profiles estimated 239/252 changed executable production
  lines covered (94.84%). However, merging across the upstream baseline and test
  revisions emitted counter-mismatch warnings in changed upstream functions and
  test functions. This is an estimate, not a clean formal 90% or project-wide
  coverage claim. The new populated per-display dashboard rows were not exercised
  visually; JSON metadata round-trips and localization were checked automatically.
- No development app, real screen capture or physical shortcut smoke test was
  launched during this follow-up. Validate the final build locally, including
  translation focus, and export all diagnostic data for latency analysis.

## Shortcut preparation optimizations

- Screenshot overlays retain only native panels, keyed by display ID, geometry
  and scale. Each capture receives a fresh view, source image and editor state.
  Dismissal detaches content, cancels image work and clears callbacks. Disconnected
  or changed displays evict their panels; the pool is bounded by the last display
  set. Per-display `windowCached`/`windowUncached` events show reuse alongside the
  existing creation/show spans. The snapshot capture itself is unchanged.
- Clipboard opening snapshots stay in memory and are valid for at most 30 seconds
  of monotonic time, or until the earliest unpinned clipboard retention boundary.
  Pin/snippet/voice retention rules remain distinct. Store changes invalidate the
  snapshot. Clipboard-change notifications use the existing content-free process
  notification bridge, so deletions from the settings process also invalidate it.
  Hidden updates coalesce for 150 ms before pre-reading off the main
  queue. Startup also pre-reads without setting the panel's loading/open state.
  Account transitions cancel reads, close the panel and retire cached data.
- A valid snapshot is presented immediately, followed by a fresh maintenance/read
  in the existing bounded worker. Policy, store identity, request generation and
  invalidation revision prevent outdated reads from restoring stale snapshots.
  Refresh updates preserve query/selection and do not show or focus the window
  again. Empty refreshed history closes the panel; a refresh failure keeps an
  already presented panel with its existing notice behavior. Cold/cache-miss opens
  still wait for the fresh read. No cache is written to disk.
- `dataCacheHit`/`dataCacheMiss` identify that opening path. On a cache hit,
  `windowOrdered` can precede `dataStarted` and `dataFinished`; background-read
  duration must not be added to the initial visible duration. Repeated model-update
  spans describe the initial snapshot and the later refresh separately.
- Launcher opening shows cached home content and takes focus before refreshing
  app/index/workflow data and enabling media loads. A cancellable 16 ms delay gives
  presentation an initial scheduling opportunity; it does not prove physical
  first paint. `mediaActivationStarted`/`mediaActivationFinished` measure media
  activation separately. Dismissal cancels pending refresh. Existing selection
  capture and text-entry semantics remain in place.
- Launcher and clipboard avoid redundant native geometry assignments. Clipboard
  native show/hide animations are disabled; the shelf retains its explicit content
  animation. Native ordering/focus calls are otherwise unchanged. The logs do not
  yet establish how much of their earlier spikes came from deferred drawing or
  system window interaction, so actual improvement needs local measurement.
- Essential launcher/clipboard/voice startup remains immediate. After bootstrap
  preparation and a two-second delay, the host pings ring and translation in
  sequence. Translation prepares its hidden panel, and ring keeps its existing
  hidden preparation. No extra shortcut listeners or process roles are introduced.
  These two existing processes now become resident earlier, increasing idle memory
  use; triggers before prewarming finishes can still be cold.
- Remote verification must not launch the development app. Synthetic native-window
  tests and builds are permitted; local physical shortcuts, multi-display changes,
  screenshot freshness and actual before/after latency remain separate checks.

### Optimization verification (2026-10-23)

- App builds passed; the final pre-test incremental build took 21.88 seconds.
  No development app was launched. Native-window tests used synthetic captures;
  physical shortcuts and real display capture were not exercised.
- Primary focused coverage selected 231 methods: 168 XCTest and 63 Swift Testing.
  Complete command wall time was 258.08 seconds (runner: 257.94 seconds, including
  preparation/discovery). All new optimization assertions passed. One old screenshot
  test still required every presentation to replace its native panels, contrary to
  the new reuse contract. It was updated to verify reused windows, fresh content,
  retired callbacks and delivery exclusively to the new session.
- Only that screenshot method was retried, together with the separately planned
  translation-entry suite to isolate native focus state. All 11 methods passed;
  complete command wall time was 75.99 seconds (runner: 72.99 seconds):

  ```bash
  ./scripts/coverage.sh --suite AskTranslationPanelCoordinatorTests --filter ScreenshotOverlayTests/testPresentingAgainReplacesOldContentAndReusesThePanels
  ```

- Follow-up cache review found that settings can mutate the shared clipboard store
  in another process. The existing notification bridge now includes clipboard
  changes. A content-free loopback test, clipboard settings and the panel change
  observer were validated together: 19 methods passed in 19.16 seconds complete
  command wall time (runner: 13.55 seconds):

  ```bash
  ./scripts/coverage.sh --suite ClipboardPanelSnapshotTests --suite ClipboardSettingsTests --filter WorkflowControllerProcessingTests/testClipboardChangesReloadTheOpenPanel
  ```

  One preceding scope-selection attempt used the nonexistent name
  `ClipboardSettingsModelTests`; the runner rejected it before executing tests
  (67.90 seconds including preparation). The corrected explicit scope above did
  not fall back to broader tests.
- The retained scopes cover 255 unique current test methods, with the replaced
  screenshot case counted once. Primary suites were ClipboardPanelSnapshotTests,
  ShortcutLatencyTests, ShortcutLatencyDetailTests, ShortcutLatencyUITests,
  RingControllerTests, RingHotkeyTests, ScreenshotOverlayTests,
  ScreenshotCoordinatorTests, ClipboardPanelControllerKeyTests,
  ClipboardShelfPresentationTests, AskLauncherToggleTests, AskContextImageTests,
  ContextImageAuthorityTests, ContextImageSourceOwnershipTests,
  AskTranslationPanelControllerTests, FeatureRPCTests and FeatureModuleHealthTests.
  An additional filter selected all WorkflowControllerProcessingTests/testHistory*
  methods and the clipboard harness's paste/copy/delete/pin/settings cases.
- Changed executable production-line coverage was 158/174 (90.80%), using
  separately exported, matching-binary focused profiles and their line-level union.
  Uncovered lines are the actual startup calls and deferred process-launch task;
  process startup was not exercised by launching an application. This is not
  project-wide or branch coverage. The HTML report represents only the latest
  individual scope, not the union.
- All five localization files pass `plutil -lint`; all 133 diagnostic keys match.
  `git diff --check` passes. No strict SwiftLint success or full-project test claim
  is made. Actual latency reduction, idle-memory cost of prewarming and native
  WindowServer behavior still need measurement on the local interactive Mac.
