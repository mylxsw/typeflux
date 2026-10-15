# GUL-393 usage guide validation

The guide keeps its window, page, search query and selected keyword when opening
the launcher, trying a keyword/sample, asking AI or choosing feedback. Only the
user's close action dismisses it. The voice tile is informational. The localized
title omits the brand in all five languages. Both feedback menus share the same
choices and routes, including the existing direct feedback sheet.

## Final validation

```sh
TYPEFLUX_HELP_SNAPSHOT="$PWD/docs/validation/gul-393/live" \
swift test --build-system native --enable-code-coverage --no-parallel \
  --filter '(HelpGuideModelTests|HelpCatalogTests|HelpSearchTests|AskHelpPluginTests|StatusBarFeedbackTests|LocalizationResourceTests)'
```

All 71 selected methods passed: 24 XCTest methods and 47 Swift Testing methods.
The complete command took 310.01 seconds, including the first native backend
build and 20 real window captures. This is a fresh build measurement, not a cache
hit. No full test or iOS run was performed.

- `HelpGuideModelTests`: state retention across all four pages, explicit close,
  empty/unavailable input, rendered voice and launcher tiles, feedback content,
  localized titles, both styles and window behavior.
- `HelpCatalogTests` / `HelpSearchTests`: the guide's catalog and search dependencies.
- `AskHelpPluginTests`: launcher handoff, sample prefill without execution and AI
  submission through the real guide/window controllers.
- `StatusBarFeedbackTests`: shared choices, direct feedback across first/reused/
  recreated settings windows, external URL dispatch and invalid menu values.
- `LocalizationResourceTests`: resource parsing and localized copy contracts.

LLVM LCOV intersected with the added/modified production lines reports **108/111
executable lines covered (97.30%)**. The new `FeedbackDestination` file is 25/25
(100%). The three uncovered lines are the app coordinator's lazy wiring and the
default OS URL opener; external route tests inject an opener to avoid launching
the user's mail client/browser. This is changed-code line coverage, not whole
project coverage.

`git diff --check` passed. SwiftLint passed for the feedback destination, guide
view/menu content and app factory. Other touched production files retain 11
baseline lint findings; comparison with original HEAD confirmed their rules and
locations predate this change. No new lint finding was introduced.

## Runner failures and retries

The normal `make coverage SUITE="..."` command was attempted first (304.63s).
The default Swift 6.3 build backend produced no coverage directory, and entering
native menu tracking caused the SwiftPM host to exit before a completion report.
A focused menu retry returned exit 0 after 34.38s but also lacked completion, so
it was not accepted as passing. Subsequent focused retries failed on lazy native
menu population (28.55s) and a menu accessibility-role assumption (93.74s).

The final test verifies the native menu control and renders its actual shared
content to press each choice without entering the tracking loop. The native
backend then ran the original focused coverage scope to completion and generated
profiling data. Interactive native menu tracking is not part of the automated
acceptance result.

## Visual review and self-review

Captured every guide page plus search in both styles and light/dark appearances
(20 images). Inspected the start pages, keyword detail, shortcuts, questions and
search. The retained PNGs are Chinese dark-mode real window captures:

- `classic-start.png`
- `liquidGlass-start.png`

Reviewed the complete entry-to-action chain, disabled/empty inputs, retained
navigation, explicit closing, feedback-sheet reuse, observer/callback ownership,
URL construction, localized strings and documentation. Fixed the test host's
early-exit problem instead of treating its zero exit code as successful testing.
No new resource leak, credential exposure or incomplete action route was found.
