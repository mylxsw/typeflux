# GUL-337: Clipboard snippets

The existing clipboard panel now has two sections, Clipboard and Snippets. Save a textual clipboard entry through its context menu; it moves into Snippets. A voice result creates a separate text snapshot and leaves the original voice history intact. Snippets have a name and an optional voice alias. They are never pinned and survive time retention, count limits, and global or per-app history cleanup. Explicit deletion asks for confirmation.

Storage remains in `clipboard.sqlite`. An additive migration adds snippet metadata and a unique normalized alias index. Snippet hashes use their IDs so capture deduplication cannot mutate a saved snapshot. Editing keeps the item ID and original source; a failed transaction leaves both the stored value and editor draft intact. No new dependencies or backend services are required.

The dictation commands `插入片段 <alias>` and `insert snippet <alias>` insert the stored text exactly, bypassing persona rewriting, punctuation optimization and OpenCC. Only complete alias matches expand. An unknown explicit alias displays a notice without inserting text; ordinary dictation and Ask commands retain their existing routing.

Validation includes migration and reopening, pin-independent retention, repeat capture, alias uniqueness and rollback, feed separation/search, editor validation and keyboard routing, voice snapshot preservation, exact voice insertion and cancellation. Native SwiftUI snapshots cover the snippet list, editor and validation error state.

The native snapshots use the existing opaque material fallback and a dark appearance so offscreen capture does not depend on desktop glass compositing. The list, editor and error state were visually reviewed at 512 × 560 points.

Full regression command: `make coverage`.

- XCTest: 3,787 tests, 17 skipped, zero failures.
- Swift Testing: 2,613 tests in 395 suites, 34 issues across eight unchanged Ask UI suites. The command exits unsuccessfully, so the full suite is **not green**.
- The failing suites are `AskComposerChromeTests`, `AskLauncherDragTests`, `AskLauncherHomeTests`, `AskLauncherMotionTests`, `AskLauncherPlacementTests`, `AskLauncherToggleTests`, `AskRedesignTests`, and `AskSurfaceOpacityTests`. Their source and the Ask implementation match baseline `a8c2d61b`. For example, the tests still expect a 58pt footer, three recent conversations, and an 800pt launcher, while the baseline implementation uses 48pt, two, and 700pt respectively. Window-motion and glass-rendering failures are also recorded; they remain unresolved here.

Final targeted regression: `swift test --no-parallel --enable-code-coverage --filter 'Clipboard|Snippet'` passed: 212 XCTest tests (two skipped), plus 35 Swift Testing tests in six suites, zero failures. This run also regenerated the reviewed native screenshots. The rollback fixture uses a fixed timestamp to avoid sub-microsecond precision differences between Foundation dates and SQLite epoch values.

Changed-line coverage from that successful run: **313 / 319 executable lines (98.12%)**. The per-file counts and uncovered line numbers are in `changed-line-coverage.json`. Coverage counts only added or modified executable production lines, as reported by LLVM against the diff from `a8c2d61b`; it is not the application's overall coverage. `git diff --check` passes.
