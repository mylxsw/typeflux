# Unified diagnostics panel — 2026-10-24

## Supplied report

The supplied JSON is 472,062 bytes (about 461 KiB), containing 46 traces
between 02:58:05 and 03:47:59 UTC. There are 31 window-visible outcomes and
15 deliberate dismissals, with no recorded failed/blocked outcomes. Dismissals
must not be counted as failed opens.

| Feature | Traces | Visible | Dismissed | Visible P50 | Visible P95 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Launcher | 24 | 13 | 11 | 69.02 ms | 246.74 ms |
| Screenshot | 13 | 13 | 0 | 342.19 ms | 1223.92 ms |
| Clipboard | 6 | 3 | 3 | 137.56 ms | 214.70 ms |
| Translation | 3 | 2 | 1 | 52.11 ms | 57.58 ms |

Screenshot remains the largest opening delay. Its single cold trace spends
about 439 ms before the target receives the command, 267 ms capturing screens,
and 512 ms constructing/presenting overlays, handling focus and reaching the
next-turn visibility probe. Twelve warm screenshot traces have P50 323.25 ms
and P95 808.06 ms; the slowest warm capture alone takes about 646 ms. Both
capture and presentation need attention; startup alone cannot explain the data.
Small sample sizes limit these percentiles. Visibility is not physical first paint
or completion of later translation/context work.

The five business-process footprints sum to about 1147.7 MiB (1.12 GiB).
The report has only one cumulative CPU snapshot, so it cannot establish current
idle CPU usage. It also reports 9,620 rejected input lines without reasons. Their
cause cannot be reconstructed from this JSON. New exports include categorized
rejection counts rather than treating all rejected lines as malformed JSON.

## Delivered behavior

See [the diagnostics contract](../SHORTCUT_DIAGNOSTICS.md) for the schema,
time boundaries, retention, export limits and current-versus-historical semantics.
The runtime overview adds current module health and retained hang metadata.
The existing process footprint/CPU table now lives in that overview. Shortcuts
retain their separate timeline and feature/temperature filters.

Collection is bounded and local. No raw chat, clipboard, screenshots, stack text
or private paths are embedded in the exported JSON. No new persistent sampling
loop is introduced. Source failures are marked, and a shortcut-log read failure
does not prevent exporting other diagnostics.

## Verification

- Application compilation passed (`swift build`). No development app or real
  feature-process runtime was launched.
- First focused coverage command selected `ShortcutLatencyTests`,
  `ShortcutLatencyUITests`, `DiagnosticsReportTests`, and `FeatureModuleHealthTests`:
  25/26 passed in 349.75 seconds including preparation/build. The remaining test
  incorrectly assumed SwiftPM preserved localization-directory capitalization;
  its lookup now accepts the normalized lowercase directory names.
- The same narrowed retry (8 methods) was blocked during compilation by unrelated,
  concurrently edited `VoiceCapsuleAnimationTests` (277.24 seconds; no tests ran).
  Those changes were preserved.
- Final focused coverage used the package's existing `TYPEFLUX_TEST_FILES`
  source-selection mechanism for `DiagnosticsReportTests.swift`,
  `ShortcutLatencyUITests.swift` and `ExclusiveUIStateTrait.swift`. An instrumented
  build followed by an explicit `swift test --skip-build --enable-code-coverage
  --no-parallel --filter 'DiagnosticsReportTests|ShortcutLatencyUITests'` passed
  all 8 methods in 72.50 seconds including compilation and lock waiting.
- Final matching-binary profile: changed executable lines covered **224/285 =
  78.60%**, excluding tests/localization/docs. Per-file changed-line coverage:
  dashboard 72.04%, shortcut report 95.45%, collector 88.37%, unified report 91.18%.
  This uses only the final binary/profile; profiles from different collector
  versions were not combined for the reported result.
- Five localization files passed `plutil -lint`; all 43 new diagnostic keys and
  existing module labels are present in all five locales. Native offscreen bitmap
  renders of both categories were inspected with injected data and collection
  disabled. Real app/window interaction, save-panel interaction and physical
  hotkeys remain for local acceptance; no full project test run was performed.
