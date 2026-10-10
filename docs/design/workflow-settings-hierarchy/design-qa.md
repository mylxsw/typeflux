# Workflow settings hierarchy — 2026-10-10

final result: passed

## Scope and evidence

The user approved `reference.png`. This change implements its workflow header and grouped list in the existing native macOS application, preserving the app shell and shared settings tokens.

- Source: `reference.png` (1448 × 1086 physical pixels, including a black surrounding canvas). The inset app frame has approximately the same 1100 × 800 logical aspect ratio as the default native settings window.
- Native full-page capture: `full-page-dark.png` (2200 × 1600 pixels; 1100 × 800 logical points at 2×).
- Controlled workflow fixtures: `states-dark.png` and `states-light.png` (1148 × 1800 pixels; 574 × 900 logical points at 2×). They deliberately include ready, disabled, untrusted, modified, and invalid workflows, a long description and multiple keywords.
- Narrow captures: `narrow-chinese.png` and `narrow-english.png` (800 × 2200 pixels; 400 × 1100 logical points at 2×).
- Failure capture: `failed-row.png`; diagnostics sheet: `failure-details.png`.

The source and native captures were opened together in one comparison input. Compare the inset source window against the native full-page capture, allowing for their respective image densities. The fixture captures provide readable close checks of the header, row hierarchy, switches, and exception states. The full-page test process does not share the signed app's trust preferences; its installed workflows therefore show untrusted states. The controlled fixtures verify normal ready/off presentation separately. No one-to-one comparison of mock workflow text or trust state is claimed.

## Findings and fixes

1. [P2, fixed] The native SwiftUI menu styles flattened custom labels or ignored the intended button style in the signed app. Replaced the menu hit area with a native NSPopUpButton and draw its visual label using the shared settings tokens. This preserves native menu navigation and a full 30-point accessible control, while keeping the blue creation action and consistent secondary chrome.
2. [P2, fixed] A container accessibility identifier hid the failure-details button from accessibility traversal. Moved the identifier to the notice label. The details button is now found and clicked in the native interaction test.
3. [P2, fixed] Menu accessibility identifiers resolved to individual text/icon frames rather than the complete 30-point controls. Use the full native control as the named accessibility element. The same geometry checks now pass in Chinese and English at 400, 574, and 800 logical widths.

No actionable P0/P1/P2 visual findings remain in the scoped workflow surface.

## Fidelity review

- Typography: existing macOS system fonts; 17-point pane title, 14-point semibold row titles, 12.5-point descriptions, and 11.5-point metadata. Long names truncate without overlapping switches; description tooltips preserve the full text.
- Layout: title and actions above one grouped list; 18-point section gap, 36-point icon tiles, 16-point row vertical insets, and shared inset dividers. A narrow header moves actions onto a second line. Metadata wraps whole keyword chips.
- Colors: shared Studio/Model tokens; blue primary creation action, neutral secondary actions, muted runtime text, and orange exception states. No new app-wide palette or gradients.
- Assets: existing Typeflux brand and native SF Symbols. No generated raster UI assets are used at runtime.
- Content: existing workflow names, descriptions, keyword chips and creation choices are preserved. Repeated healthy/off badges and successful run summaries are hidden in the list. Trust, validation, conflict and failed-run information stays visible and actionable.

## Validation

`swift test --scratch-path /tmp/typeflux-workflow-redesign-build --skip-update --filter 'AskWorkflowSettingsTests|LauncherSettingsPolishTests'`

Final run: 13 tests in 2 suites passed. Tests cover default/minimum native window sizes, light/dark appearance, Chinese/English narrow headers, action geometry, title/switch separation, switch persistence, blocked pending-trust switches, trust/repair callbacks, successful-run suppression, and failure-detail access. The native build and standard signed development-app packaging also succeeded.

Live desktop checks confirmed that clicking an installed workflow name opens its editor and that the row context menu exposes edit, external editor, Finder, and Trash actions. The signed development app was packaged and relaunched. Once its settings window was opened, the final live screenshot confirmed matching button chrome, the blue primary creation action, and the grouped list. The Manage menu opens and its editor entry works with native Down/Return keyboard selection. The New Workflow menu exposes AI generation and all four existing templates and closes with Escape. The gallery button opens the example library and its close button returns to the workflow list. The development app is left on the workflow settings page. No production workflow was executed or deleted for verification.

## Remaining polish

The mock uses shorter sample descriptions than the actual workflows. The implementation keeps installed content, limits descriptions to one line and exposes the complete text on hover. This is an intentional content-preserving choice.
