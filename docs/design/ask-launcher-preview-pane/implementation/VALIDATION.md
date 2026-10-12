Initial implementation validated on macOS 26.6.2 (25G83), Apple Silicon, Swift 6.4 and Xcode 27.0 (27A266a), on 2026-10-12. The following full-suite and coverage results use production source `9623db8c` and test fixtures `c1c5c0d2`; review-fix validation is recorded below.

| Check | Result |
| --- | --- |
| `swift build` | Passed |
| `swift test --no-parallel --enable-code-coverage` | Passed: XCTest 3,760 tests, 17 skipped, 0 failures (235.062s); Swift Testing 2,613 tests in 398 suites, 0 issues (772.437s) |
| Preview tests | 28 tests in 7 suites passed (9.144s) |
| `swiftlint lint Sources/Typeflux/Ask/QuickResults/Preview --quiet --strict` | Passed |
| `git diff --check` | Passed |

After the full run, commit `220c0e5f` resolves a test-only conflict with the newer main branch by replacing literal `36` with the existing `SettingsControlMetrics.menuHeight` constant (also `36`). `swift test --no-parallel --enable-code-coverage --filter SettingsPolishTests` passes on that final test source. Production code is unchanged. A three-way merge check against main `7d7e3341` succeeds.

The focused rendering, screenshot and microbenchmark command was:

```sh
TYPEFLUX_PREVIEW_SNAPSHOTS=/tmp/typeflux-gul335-snapshots \
TYPEFLUX_PREVIEW_BENCHMARK=1 \
swift test --enable-code-coverage --filter AskFilePreview
```

The PNG loader microbenchmark reported p95 **121.38ms**, calculated as measured loader completion plus the configured 120ms debounce, across 20 distinct local paths. It excludes AppKit drawing and the entry animation. This is not an all-format, cold-disk, or 60fps scrolling measurement.

Coverage is collected from the final full test run's `.profraw` files with `xcrun llvm-profdata merge -sparse`, then reported with `xcrun llvm-cov report` against the `TypefluxTests.xctest` executable. Changed-line coverage uses `llvm-cov show` counts for added executable Swift lines relative to base `884dac60`, including the existing integration files as well as the new preview directory.

| Coverage scope | Covered / total | Coverage |
| --- | --- | --- |
| New preview module, lines | 1,418 / 1,437 | **98.68%** |
| New preview module, regions | 496 / 539 | **92.02%** |
| New preview module, functions | 197 / 210 | 93.81% |
| All added/changed executable Swift production lines | 990 / 1,006 | **98.41%** |

Per-file line coverage in the new module: clock 100%, content 100%, controller 98.60%, loader 92.36%, placement 100%, policy 100%, renderer 98.89%, text 100%, view 99.80%.

Full regression testing exposed old launcher size/home-row/menu-height/glass expectations on the starting main branch, plus UI readiness races. The separate test-only commit aligns those assertions with the existing adaptive launcher, scopes popover lookup to its presenting window, waits for actual history/menu content, and controls streamed chunks explicitly. It does not change launcher production layout.

The [screenshots and implementation decisions](README.md) cover light/dark image, PDF, code and table fixtures, format fallbacks, bounded reads, and the repository's five existing locales.

Review follow-up (2026-10-12): pending search results now preserve the displayed preview, and same-path hits update their header metadata without cancelling or restarting a load or crossfade. Two new regression tests cover a deliberately stalled file search through settlement, unchanged panel visibility and content identity, clearing the query, and score/match/highlight changes during dwell and after loading.

```sh
swift build --enable-code-coverage
swift test --no-parallel --enable-code-coverage \
  --filter 'AskFilePreview|AskQuickSearchSessionTests|AskLauncherMotionTests'
```

Build passed (15.96s); **53 tests in 9 suites passed** (29.388s), including all 30 preview tests. This follow-up runs the relevant preview, staged-search and launcher-motion suites; the earlier full-suite results above remain scoped to their stated revision.

Profiles from this follow-up run cover **4/4 changed executable production lines (100%)**: both updated composer guards and the controller's same-path comparison and metadata assignment, measured with `llvm-profdata merge -sparse` and `llvm-cov show`.
