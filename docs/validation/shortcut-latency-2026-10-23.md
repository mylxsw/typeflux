# Shortcut latency follow-up, 2026-10-23

## Evidence and comparison rules

Input: `typeflux-shortcut-diagnostics.json`, generated at `2026-10-23T14:59:18Z`.
The export contains 215 traces, including all 107 traces from the earlier export
and 108 additional traces. It reports zero dropped events, invalid lines, and
unreadable files. Historical records must not be treated as current measurements.

All durations below are milliseconds, measured from `recognized` to the **first**
`visibleNextTurn`. This is an application event-loop visibility proxy; it does
not prove the display compositor has painted a frame or that an animation has
finished. Dismissal-only traces are excluded. Translation can emit two visibility
events; the first is the initial panel, before selected text is available.

The build field remains `1.0.0`, so the exact Git revision cannot be established
from this export. Screenshot window-cache events, launcher media-activation
spans, and clipboard snapshot-cache events identify traces containing the prior
optimization. Ring/translation observations after `12:50Z` are listed separately
by time and process session; this is not an independently verified build identity.
Use schema-v2 traces for stage comparisons. Screen counts must match when
comparing screenshot totals. These are observational samples from different
sessions, not controlled benchmarks.

## Observations

| Feature / cohort | Visible traces | Median | Range |
| --- | ---: | ---: | ---: |
| Screenshot, earlier warm, three screens | 7 | 899.43 | 758.95–920.15 |
| Screenshot, optimized warm, three screens | 2 | 271.53 | 169.41–373.65 |
| Screenshot, optimized warm, one screen | 13 | 182.15 | 145.80–321.57 |
| Screenshot, optimized cold, one screen | 4 | 892.10 | 858.68–1193.56 |
| Screenshot, optimized cold, three screens | 1 | 1376.68 | single observation |
| Clipboard, earlier schema-v2 warm | 6 | 111.50 | 95.76–516.92 |
| Clipboard, snapshot hit | 7 | 61.93 | 38.78–161.47 |
| Clipboard, snapshot miss | 2 | 274.00 | 263.84–284.16 |
| Launcher, earlier schema-v2 warm | 11 | 88.68 | 67.92–253.76 |
| Launcher, deferred refresh | 25 | 91.55 | 61.26–329.08 |
| Ring, later warm sessions | 6 | 136.73 | 84.19–178.14 |
| Translation, later warm session | 2 | 24.59 | 8.81–40.37 |

- Screenshot panel acquisition across all displays now has a warm median of
  0.13 ms. Warm capture has a median of 91.31 ms and reaches 238.17 ms. A focus
  outlier consumes 133.34 ms. Cold process routing/readiness remains 487–850 ms;
  first-use native panel creation remains 72–291 ms. Do not remove capture
  freshness or reuse pixels to improve these numbers.
- Clipboard snapshot hits remove the data read from the first presentation's
  critical path. Fresh background reads still take roughly 44–73 ms. A snapshot
  hit can still take 161 ms because showing the native window costs 122 ms.
- Launcher defers media/app/workflow refresh until after the visibility event,
  but its visible median has not improved in this sample. Its native show call
  has a median of 62.64 ms and reaches 248.77 ms. Routing is not the dominant cost.
  Selected-text context capture in these 25 traces has a median of 385.15 ms
  (253.34–659.89 ms), after the first visibility event. This can delay context
  availability even when the initial panel appears quickly; first visibility is
  not equivalent to readiness of a selection-dependent action.
- Ring's later warm median has not improved. Its show span has a median of
  100.25 ms. Source inspection confirms `prepare()` previously rasterized graphics
  but `show()` recreated both the native panel and material surface every time.
- Translation's later samples are already warm; two visible samples cannot
  establish a reliable performance trend.

## Follow-up implementation

1. Reuse the radial menu's native panel and material surface; construct them
   during its existing hidden preparation. Retain custom open/close animations,
   update current items/style/title, reset interaction on each opening, and ignore
   selection/focus commands while hidden or dismissing.
2. Add the existing screenshot role to delayed, sequential process warmup after
   ring and translation. Prepare hidden empty screenshot windows from display
   geometry. Do not request capture permission, read pixels, retain a snapshot,
   take focus, or show a window during warmup. Revalidate display geometry/scale
   on actual capture; evict removed displays. Warmup cannot disturb a live capture.
3. Keep process boundaries and launcher focus behavior unchanged. The existing
   launcher show span does not yet distinguish native ordering, focus transfer,
   and synchronous AppKit drawing, so changing those semantics would be speculative.

Real shortcut latency, focus across other applications/Spaces, and extra idle
memory must be checked on the user's local machine. The remote development app
must not be launched for validation.

## Verification

- `swift build`: passed, 67.05 seconds. This builds the application; it does not
  launch a development app.
- OpieMenu focused coverage, initial four methods: passed; full command wall time
  21.02 seconds. Includes hidden preparation, repeated preparation, repeated open /
  close reuse, current configuration and hidden-action fencing.
- Client focused coverage: `ScreenshotOverlayTests`, `ScreenshotCoordinatorTests`,
  `RingControllerTests`, `ClipboardPanelSnapshotTests`; 100 methods, initially
  98 passed and two new hidden-empty-window assertions failed. Full command wall
  time 231.12 seconds, including build/discovery. AppKit creates a default content
  view for a new native window; hidden prewarm now explicitly removes it.
- Retried only the two failing `ScreenshotOverlayTests/testPrewarm...` methods:
  both passed; full command wall time 68.10 seconds.
- Added a native-display geometry entry-point test and a real menu selection /
  closing-callback test to cover branches missed by the initial scope. The menu
  fixture initially assumed the real pointer remained centered after screen-edge
  clamping (6.53 seconds, failed); removed that unrelated desktop-dependent
  assumption and retried only the selection method (2.44 seconds, passed).
  The display-prewarm method passed (254.03 seconds including rebuild/discovery).
- **106 distinct retained methods passed across the focused scopes.** No full
  project suite or real desktop capture test was run. Most command time was test
  program preparation, not method execution.
- Changed executable production lines: **93/96 = 96.88%**, unioned from matching
  binary/profile LCOV exports for the initial scopes and focused retries. The
  initial overlay line map accounts for the two-line content-view cleanup added
  after its failed assertions. This is changed-line coverage, not project-wide
  coverage. Uncovered changed lines are the application startup binding, the
  protocol's default no-op warmup, and the positive pointer-activation forwarding
  line. Keyboard selection and the hidden pointer-activation fence were tested.
- `git diff --check`: passed. Global shortcut feel, real first-use latency,
  cross-application/Space focus and extra resident memory remain local validation.
