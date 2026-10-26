# Local website preview

The file panel and `web_browser.open_file` use `AskFileHTMLPreview` and
`AskPreviewHost`. Do not introduce another `file://` loading path for local HTML.

## Scope and loading

The entry HTML's containing directory is the static website root. Relative and
root-relative resource URLs resolve inside that root. Nested pages can navigate
within the snapshot. Open the site's top-level entry to include shared assets;
opening a nested HTML directly treats its own directory as the root. Never infer
a wider root by walking towards the user's home or workspace directory.

The loader takes a bounded snapshot of HTML, CSS, JavaScript, images and fonts.
It preserves file names, subdirectories and MIME types. Query strings used for
asset versions do not change the selected file. Reopening or refreshing rebuilds
the snapshot, including changed assets. Hidden entries, node_modules, non-web
files, symbolic links and non-regular files are excluded. Reads use no-follow
file descriptors. Limits are 128 files, 16 MiB/file, 32 MiB total, 1024 inspected
entries and fewer than 16 directory levels; exceeding a limit fails explicitly.

The preview uses an isolated nonpersistent WebKit instance and random origin.
It cannot reach external networks, read arbitrary files, upload, spawn windows
or access native bridges. Local fonts and scripts are served by the same bounded
resource handler. CORS responses contain no credentials and expose only snapshot
bytes. Development-server previews retain their existing explicit runtime lease;
a static preview never silently starts a server or installs dependencies.

## Verification contract

An opened HTML document or a screenshot alone is not successful website
verification. Check resource diagnostics and exercise important interactions.
Missing resources include the requested path; browser tools return preview
notices so the agent sees the same failure as the user.

`AskLocalWebsitePreviewTests` renders the same fixture through the file loader
and the actual Agent tool, checking external CSS, nested CSS imports, external
JavaScript, a button interaction, Unicode image paths, query strings, refresh,
missing-resource diagnostics, size/count limits and symlink exclusion.
`AskPreviewHostTests` verifies the shared network and filesystem isolation.

## Validation (2026-10-26)

The focused scope was AskLocalWebsitePreviewTests, AskSidePanelFilePreviewTests,
AskPreviewHostTests, AskEmbeddedBrowserToolTests, AskBrowserWorkspaceTests,
AskArtifactStoreTests, AskDevelopmentPreviewTests and AskBrowserPanelRenderTests:
77 methods passed after updating one legacy assertion to include the resource path.
The initial command took 673.41 seconds including shared build-directory waits;
a build-interrupted retry took 74.71 seconds and the successful method retry took
80.53 seconds. No full-suite execution was requested.

Shared SwiftPM coverage files were replaced by a concurrent task. A separate
LLVM_PROFILE_FILE directory and the built XCTest binary were therefore used to
collect the five directly affected XCTest suites (59 passing tests, 9.58 seconds
of test execution). llvm-cov measured 133/147 executable added or changed lines
covered (90.48%), exceeding the 60% changed-code target. Browser panel rendering
passed in the original focused scope. This validates actual WebKit loading and
interaction, but does not claim that a newly packaged app was installed/launched.
