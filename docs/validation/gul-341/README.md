# Persona settings redesign validation

The native captures render the production `StudioView` in macOS windows with synthetic personas and app rules. They use the Classic appearance so cached window images have an opaque backdrop. The wide viewport is 1180 × 780 points; narrow captures use 920 × 780 points. Native PNGs retain Retina resolution.

The fixtures use Mail, Notes and Safari rules and synthetic custom definitions. Built-in definitions and shortcut badges come from the real settings implementation; the prototype contains illustrative content and bindings.

The editor tests verify bounded definition scrolling, valid saves, the dirty guard’s Save / Don’t Save / Cancel actions, deletion and undo through native controls, and the drawer’s master switch and close button. Model tests cover deletion impacts and complete snapshots, paused rules, template replacement, default and auxiliary selection, search, duplicate rules and preset add flows. Undo expires when a newer store change or account scope makes its snapshot stale. Application discovery propagates cancellation when the drawer closes.

Snapshots can be regenerated on a Mac with:

```sh
TYPEFLUX_PERSONA_SNAPSHOTS=/tmp/persona-snapshots swift test --no-parallel --filter PersonaLibraryVisualTests
```

## Dark

| State | Approved prototype | Native SwiftUI |
|---|---|---|
| Built-in | ![Built-in prototype](prototype/builtin-dark.png) | ![Built-in native](native/builtin-dark.png) |
| Custom with edits | ![Custom with edits prototype](prototype/custom-dark.png) | ![Custom with edits native](native/custom-dark.png) |
| Create | ![Create prototype](prototype/create-dark.png) | ![Create native](native/create-dark.png) |
| App rules drawer | ![App rules drawer prototype](prototype/apps-dark.png) | ![App rules drawer native](native/apps-dark.png) |
| Delete confirmation | ![Delete confirmation prototype](prototype/delete-dark.png) | ![Delete confirmation native](native/delete-dark.png) |
| Empty search | ![Empty search prototype](prototype/search-dark.png) | ![Empty search native](native/search-dark.png) |

## Light

| State | Approved prototype | Native SwiftUI |
|---|---|---|
| Built-in | ![Built-in prototype](prototype/builtin-light.png) | ![Built-in native](native/builtin-light.png) |
| Custom with edits | ![Custom with edits prototype](prototype/custom-light.png) | ![Custom with edits native](native/custom-light.png) |
| Create | ![Create prototype](prototype/create-light.png) | ![Create native](native/create-light.png) |
| App rules drawer | ![App rules drawer prototype](prototype/apps-light.png) | ![App rules drawer native](native/apps-light.png) |
| Delete confirmation | ![Delete confirmation prototype](prototype/delete-light.png) | ![Delete confirmation native](native/delete-light.png) |
| Empty search | ![Empty search prototype](prototype/search-light.png) | ![Empty search native](native/search-light.png) |

## Narrow window

![Narrow dark](native/narrow-dark.png)
![Narrow light](native/narrow-light.png)

## Verification

Validation ran on the connected Mac with Swift 6.4.

- `swift build`: passed.
- `swift test --no-parallel --enable-code-coverage`: all 2,678 Swift Testing tests in 406 suites passed. The XCTest phase exposed a concurrent read/write in its in-memory workflow history fixture; that fixture now uses a lock and snapshots the dictionary before sorting.
- `swift test --no-parallel --enable-code-coverage --disable-swift-testing`: the complete XCTest rerun passed, with 3,787 tests, 17 existing skips and zero failures.
- Final persona/localization/settings regression: 44 Swift Testing tests in five suites passed, together with the selected XCTest suites. Native controls cover creation, saves, all three dirty-guard decisions, deletion/undo, the drawer master switch and closing the drawer.
- Changed-line coverage: **1,163 / 1,187 executable production lines (97.98%)**. [Per-file counts](changed-line-coverage.json) count added or modified lines against the merged main base; this is not overall application coverage.
- `make format`: formatter/autocorrect steps ran; repository-wide lint exited 2 on existing findings. Final lint of changed source files found 39 existing findings and **zero new findings**, checked against unchanged source from the merged main base. [Lint summary](lint-summary.json).
- `git diff --check`: passed.

Self-review covered complete entry-to-exit flows, empty/invalid drafts and missing personas, default/auxiliary fallbacks, all affected rules including paused rules, cancellation of application discovery, account-scoped undo, pending sync notifications, accessibility identifiers and five-language key/placeholder parity. Native captures were compared in both appearances and at the narrow breakpoint.
