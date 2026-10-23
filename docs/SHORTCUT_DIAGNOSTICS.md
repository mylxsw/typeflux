# Shortcut response diagnostics

Open **Settings → Advanced → Shortcut Response Diagnostics → Open Diagnostics**.
Recording is enabled by default and can be disabled in that section. This is local
diagnostic storage, independent of analytics sharing; it never uploads records.
Use the launcher, clipboard and screenshot shortcuts in normal work, then inspect
their timelines. The dashboard refreshes every two seconds while mounted. Its
filters affect the displayed statistics; **Export All Data** exports the complete
retained snapshot, including other features and unsuccessful/incomplete records.

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
- Full display paths are instrumented for launcher, clipboard and screenshot
  selection. Other feature shortcuts include routing/handler timing, with a
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

- JSONL schema version 1 contains only fixed stage/role names, UUIDs, timestamps,
  PID, build and dropped-event counts. No shortcut chord, keyword ID, payload,
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

This change records the existing behavior; it does not merge processes, change
shortcut ownership, remove readiness gates or move window prewarming.

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
