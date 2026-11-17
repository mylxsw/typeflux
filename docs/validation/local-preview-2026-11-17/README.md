# Local HTML preview delivery failure

## Evidence and cause

The reported page was `work/preview.html`, with an image reference to
`../outputs/kitten-sniffing-dog.svg`. Local previews snapshot only the entry
file's containing directory. The rendered entry becomes `/preview.html` under
an isolated origin, so the image resolves to `/outputs/kitten-sniffing-dog.svg`,
which is not in that snapshot. The actual SVG exists and parses as XML.

The recorded `open_file` result contained both `Opened local HTML in tab 1`
and `Notice: Resource failed: .../outputs/kitten-sniffing-dog.svg`.
`openFile` collected diagnostics but discarded their result. Thus failure
remained a notice on an otherwise successful tool result.

The agent subsequently changed the HTML to use `./kitten-sniffing-dog.svg`,
which exists beside the entry. It did not reopen the file. Browser reads
returned the old snapshot's text without checking either resource failures
or whether the source files changed. Text availability was incorrectly used
as evidence of a working visual preview.

## Repair

- Load local previews in a candidate WebKit view. Require a complete document,
  no collected loading/script errors, and successfully loaded image elements
  before attaching the view. Failed candidates are closed; an existing working
  view is preserved.
- Agent-created tabs remain unselected and do not request presentation until
  validation succeeds. Failure throws through the tool error path instead of
  returning an opened receipt.
- Before read, snapshot, or screenshot of a local preview, compare the current
  directory snapshot version with the loaded version and validate diagnostics.
  A changed source or asset requires `open_file` again.
- The file-panel HTML entrance uses the same load validation before attachment.
- Keep the directory boundary, symlink exclusion, size bounds, network blocking,
  and explicit snapshot refresh model.

## Regression scope

`AskLocalWebsitePreviewTests`: reported sibling-directory SVG case, successful
repair, changed asset detection for all three observation actions, reopen with
updated pixels, invalid SVG, script failure, preservation of a working view,
and missing-resource failure without presenting a tab.

`AskEmbeddedBrowserToolTests`: existing browser tools and successful local open.
`AskPreviewHostTests`: shared WebKit isolation and diagnostics.
`AskBrowserWorkspaceTests`: tab ownership and file-preview navigation.
`AskSidePanelFilePreviewTests`: file-preview loading and permission checks.

This is a load-time and observation-time gate, not proof against arbitrary
future JavaScript mutations or model claims made without tool evidence.

## Validation result

All 61 selected XCTest methods passed (0 failures), including the real WebKit
regressions. Execution took 19.855 seconds; the final coverage command took
302.86 seconds including build/discovery. Initial build attempts took 27.57 and
111.68 seconds and failed before executing tests because the native SwiftPM
coverage build omitted the Xcode platform SwiftUI and Testing macro search paths.
A temporary compiler wrapper supplied those paths; no project dependency or
machine-wide toolchain files were changed.

The final command returned nonzero after passing tests: SwiftPM searched beside
the temporary wrapper for `llvm-profdata`. Recovered the already-recorded raw
profiles with Xcode's `xcrun llvm-profdata merge -sparse` and inspected the actual
test binary using `xcrun llvm-cov show/export`; no additional test execution was
needed. Added instrumented production-line coverage is **53/58 (91.4%)**; this is
not project-wide or branch coverage. The three file-panel attachment/cleanup
lines are not directly exercised by these tests. See `coverage.json` and
`tests.txt` for details.

The running installed development app was not replaced or restarted. These
results validate source and real WebKit tests, not the installed app version.
