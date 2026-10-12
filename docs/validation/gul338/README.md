# GUL-338: Native emoji search

The launcher now exposes `emoji` / `表情` as a native live plugin. It searches the bundled catalog without Node or a network connection, with Chinese/English annotations, pinyin, prefixes, partial matching, bounded spelling correction and reviewed common-expression suggestions.

Results use a grid with a selected-item preview, skin-tone menu, favorites and recent usage. Return/double-click copies and closes, Command-C copies and stays, Option-Return uses the existing write-back path (with clipboard fallback). Tab leaves the editor for controls; arrows navigate the focused grid. Escape clears the query, then leaves keyword mode. Input method marked text is kept out of live searches.

New defaults respect existing workflow-reserved keywords. If a legacy workflow owns `emoji`, the built-in uses the free `表情` alias. If both are occupied, users can assign another word through Settings → Launcher → Keywords → Emoji. Existing workflow files are not modified.

Implementation:

- `EmojiCatalog` loads versioned generated data and stores local usage/preferences through `EmojiUsageStore`.
- `EmojiSearchService` builds an actor-isolated index and ranks matches; `AskEmojiPlugin` adapts results to the existing session/actions.
- `EmojiResultsView` and `EmojiGridKeyboard` provide native selection and accessibility; pending results cannot execute actions.
- `AskConversationModel+Emoji` validates mutations against the current result and records successful use.

The catalog contains 1,914 base entries and 3,944 valid sequences including variants. Build instructions and source/version details are in `scripts/emoji/README.md`. Common-expression search is a curated offline dictionary, not arbitrary semantic inference.

Validation results and native light/dark captures accompany this file. Benchmarks are measured in the local instrumented debug build, not release guarantees.

## Validation environment and limits

Apple M4, macOS 26.6.2, Swift 6.3.1. Search timing uses an instrumented debug build; it does not include the 60 ms debounce or view layout. The quality corpus bypasses font filtering so OS support does not change the linguistic score. The UI and timing tests use real CoreText filtering.

The same 204-query corpus scores 172/204 Top-5 matches with the existing gallery workflow. This corpus is a regression set authored for this feature, not a blind language-understanding benchmark.

Minimum-supported macOS 13 and an end-to-end VoiceOver session still require manual device acceptance. Native keyboard event handling, IME deferral, light/dark view rendering and accessibility labels are covered locally. No runtime network or Node path is introduced.

Repository-wide SwiftLint remains blocked by existing violations in unrelated files. The new emoji source and test files pass strict lint. Do not interpret the search benchmark as certification of the design's release latency or memory targets.

## Existing regression failures

The full run encounters outdated launcher layout expectations already present at base `b81497b8`. The failing assertions and their production implementations are unchanged by this PR:

- `AskComposerChromeTests.launcherUsesCompactCornersWithoutChangingHeaderLayout`: expects a 58-point footer; `AskDesign.swift` sets 48.
- Three `AskLauncherPlacementTests.fixedLauncher…` tests expect fixed 800×600 placement; `AskMetrics.launcherWidth` is 700 and placement uses the resting content height.
- `AskRedesignTests.launcherHeightIsTheComposerCardPlusItsGutter`: expects heights calculated from the old footer.
- `AskLauncherHomeTests.recentConversationsAreNewestFirstAndLimitedToThree` and `applicationsFillTheSpaceBetweenHistoryAndKeywords`: expect three recent conversations; `AskLauncherHome.maximumRecentConversations` is two.

These failures are reported rather than changing unrelated product layout or weakening existing assertions.

Additional full-suite failures occur in `AskLauncherMotionTests`, `AskLauncherToggleTests+Steadiness`, `AskLauncherDragTests`, `AskSurfaceOpacityTests`, and `AskLibraryVisualConsistencyTests` (fixed viewport, centering, material color, and library-filter geometry). These are outside emoji-specific scenarios and are reported as unresolved regression failures; they have not all been reproduced independently on the base revision.

## Final focused results

- `swift test --no-parallel --enable-code-coverage --filter 'Emoji|AskKeywordAlias|AskKeywordListPresentation|AskKeywordDraft|ExclusiveUIStateLanguage|AppLocalization'`: 36 XCTest + 50 Swift Testing cases passed after the final changes.
- `node --test scripts/emoji/build.test.cjs`: 4 passed. Regenerating the catalog produces the same SHA-256 (`d7ca087e875e84b0bdaa7bf1f0434def9b778d8b6b63d6056156d3e5d9cac773`).
- New Swift emoji files: 1,040/1,142 covered lines (**91.07%**); search service **98.38%**. See `coverage.json` for per-file results, including lower SwiftUI coverage.
- Curated query Top-5: **204/204 (100%)**, versus legacy workflow **172/204 (84.31%)**.
- Final isolated debug/coverage benchmark: **246.94 ms cold**, **41.16 ms warm P95** (24 queries). During full-suite concurrency: 363.81 ms / 58.99 ms. Release latency, end-to-end display latency and index-memory targets remain unverified; these debug timings exceed the proposed 150 ms / 30 ms goals.
- Full regression before the final action/name hardening: 3,774 XCTest (17 skipped, zero failures); 2,607 Swift Testing cases (12 failed tests, 35 assertion issues). See `full-regression.json` and explanations above. The final focused regression covers the subsequent changes; the full suite is not green.
- Strict SwiftLint passes for all newly added emoji Swift source/tests; `git diff --check` passes.

`emoji-light.png` and `emoji-dark.png` are captures of the native SwiftUI result view hosted in an AppKit window using the bundled catalog. They are not browser mockups or screenshots of a packaged release.
