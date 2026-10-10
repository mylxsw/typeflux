# Launcher number conversions and developer workflows

Verified on 2026-10-10 with the production SwiftUI views, in Simplified Chinese, light and dark appearances.

- `quick-number-conversions-*.png`: input 255, exact numeric radices, Chinese words/amount and text Base64.
- `quick-number-fraction-*.png`: input 1001.005, unrounded numeric words, rounded currency words and decimal formats.
- `quick-number-search-*.png`: input 2024, numeric conversions precede matching files in the same scrolling list.
- `built-in-number-conversions-*.png`: Settings → Launcher → Built-in Features, with independent calculator and number-conversion switches.
- `implemented-g-list*.png`: the expanded 18-example gallery and category counts.

Validation:

- Built-in feature switch follow-up: 60 Swift tests in 8 suites passed, covering persistence, independent arithmetic/number switches, live launcher refresh, cancellation during slow searches, numeric content search and native renders. One final light/dark settings render passed with the settings-page canvas. An independent scratch directory avoided the other chat's active SwiftPM lock; the successful build was packaged and launched using the normal signing/install script. Logs: `/tmp/typeflux-number-toggle-tests.log`, `/tmp/typeflux-number-toggle-render.log`, `/tmp/typeflux-number-toggle-install.log`.
- Conversion-first ordering follow-up: 66 Swift tests in 9 suites passed, including numeric search, keyboard open/copy actions and light/dark snapshots. A final 31 tests in 2 suites passed after preserving the numeric default when browser results arrive. Logs: `/tmp/typeflux-number-first-tests.log`, `/tmp/typeflux-number-first-final.log`.
- Numeric-search follow-up: 151 Swift tests in 9 suites passed, covering simultaneous numeric conversion and application/file searches, immediate conversion display, preserved keyboard selection, stale batch rejection, open/copy actions, existing launcher interactions, and light/dark renders. Log: `/tmp/typeflux-number-search-verified.log`.
- The follow-up dev app was installed and launched from that successful test build. A subsequent fresh build encountered concurrently added browser-search code referencing the unfinished `focusBrowserTab` action; the verified executable was packaged with the usual signing/install script instead. Logs: `/tmp/typeflux-number-search-launch.log`, `/tmp/typeflux-number-search-install.log`.
- 93 related Swift tests passed (numeric detection/conversion, existing calculator, result selection/copying, staged search, gallery installation and runtime, and localization isolation).
- 9 Node test groups and 3 Python tests passed, including all 14 case modes, 12 directed data-format pairs, HTML/Markdown tables, malformed encodings, Quartz/Linux differences and subnet edge cases.
- A further 5 gallery/developer-tool integration tests passed after the final dependency update. The generated QR PNG was decoded back to its original Unicode text with Core Image.
- 4 native rendering tests passed. Snapshot tests initialize authentication from the in-memory test store rather than accessing the real keychain.
- The full test run did not pass: `AskLocalWebToolsTests.testAddressPolicy` failed at `Tests/TypefluxTests/AskLocalModeTests.swift:44`. That run was stopped during an unrelated asynchronous XCTest wait. No web address-policy code was changed for this work.

Offline dependencies can be rebuilt using `scripts/workflow-tools/README.md`. Installed workflows need their stated Node/Python runtime; they do not install packages or call network services.
