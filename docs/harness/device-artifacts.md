# Device artifacts and static previews (GUL-178 / D03)

Artifacts are immutable copies in the local `AskArtifacts` store. They are delivered
as P00 `AskArtifactRef` IDs and P06 outcome references, never as internal paths.
The `artifact` tool requires both `projectModeEnabled` and the independent
`artifactCreationEnabled` gate, a host-bound owner/conversation/run, a current
workspace version, and a single-use approval binding every resource version.
`artifactPreviewEnabled` independently gates executable HTML. All gates default
to false; production composition does not enable them.

## Capture contract

The tool accepts `workspace_id`, `expected_version`, `entry`, and `resources`.
Paths are workspace-relative; `resources` is the **complete explicit file list**,
including the entry. There is no recursive directory discovery. Callers must not
claim a truncated project listing is a complete resource list. Directories,
missing files, traversal, symlinks, hardlinks, `.git`, ambiguous case/Unicode
aliases and URL-special path components are rejected. Unlisted dependencies
produce visible resource errors instead of falling back to the source tree.

`AskArtifactCapture` uses D01 `withValidatedSnapshot`. The callback only prepares
bounded in-memory bytes; it applies `entries.updated` over source snapshots,
records and rechecks the version of **every** declared file (including unstaged
files), and retains no source descriptors. The outer operation must succeed,
and live authorization/workspace revision must be revalidated, before publishing.
No artifact becomes visible when capture or postvalidation fails. Directory
enumeration and its truncation/races are avoided by the explicit manifest.

Limits are 128 resources, 16 MiB per file, 32 MiB total and 1,024 retained store
entries (new creation fails when full). Capture fails as a
whole on a limit; it never publishes a partial success. Like D01, this is not a
filesystem-wide atomic snapshot against arbitrary external editors. Changes
after the final validation do not change the already captured artifact bytes.

`AskArtifactStore.publish` also accepts host-produced bytes, allowing screenshots
and logs to be associated with a trusted run, with an optional workspace. It is
not a model-facing arbitrary-path import API. MCP resource URLs are not fetched.

## Storage, compatibility and retention

The private manifest records creation time, the optional workspace reference,
entry name, and the MIME, size and SHA-256 of every resource. The wire reference's
hash/size identify the original entry bytes; its version hashes the sorted
resource manifest. Blobs are stored under flat internal names, through pinned
directory descriptors, and published with an atomic directory rename. Reopening
verifies ownership, scope, expiry, the manifest and all resource hashes.

Retention is `device_30_days`, measured from creation. Expired references are
unavailable immediately. Create/open/export operations sweep expired private
records; no source directory or user-managed worktree is deleted. Unknown or
corrupt records are retained instead of guessing deletion authority. Disabling
creation or HTML preview leaves metadata and explicit download available, subject
to the existing retention and authorization rules.

Workspace artifacts require current folder authorization and the original root
identity on reopen/export. Revocation or root replacement denies access. Later
legitimate edits do not invalidate immutable retained copies. Account and
conversation checks come from the selected authenticated UI session, not a DTO.
During HTML preview these checks repeat for resource requests and once a second;
revocation, expiry or account switching closes the executable page.

The public DTO is unchanged. A small JSON receipt containing the same reference
also survives legacy text-only Cloud history, while negotiated typed content
retains outcome artifacts. Only metadata crosses the existing result path; no
artifact bytes are uploaded. A different device displays an explicit unavailable
error. This change does not enable new wire/provider capabilities.

## Preview boundary

Each HTML preview uses a new nonpersistent WKWebView and a random custom-scheme
origin. Its scheme handler serves only verified bytes named by that artifact's
manifest. It never calls `loadFileURL`, passes a source descriptor to WebKit,
registers a native script message handler, or opens an external URL. The response
applies CSP `sandbox allow-scripts` without `allow-same-origin`, a resource-origin
allowlist, and `connect-src/frame-src/worker-src/object-src/base-uri/form-action`
denials. A compiled WebKit content rule list independently blocks all requests
except the random artifact origin. Navigation is limited to that origin and the
manifest; new windows, downloads, file selection and media capture are denied.
JavaScript dialogs cannot invoke native permission flows. Generated-page errors,
policy violations, missing resources and process termination are visible.

**WebKit SPI dependency:** a real UDP test demonstrated that CSP and content
rules alone allow WebRTC/STUN traffic. Before loading content the host therefore
disables peer connections, media devices, screen capture and DNS prefetching in
the browser engine. It verifies the Objective-C method signatures and reads back
the disabled values; a missing or incompatible switch disables executable
preview. These switches are WebKit SPI, not App Store APIs. This application uses
Developer ID distribution; an App Store build would need a different backend or
keep executable preview disabled. The feature remains off in production pending
combination/OS acceptance. This is not a JavaScript monkey patch: a page cannot
restore the removed WebRTC engine capability from another JavaScript realm.

Text/JSON use a native, visibly bounded preview; raster images use bounded ImageIO
thumbnails. Other MIME types remain downloadable with an unsupported-preview
message. Save exports the **original entry file**, not a rewritten HTML page or
an archive of all dependencies, and verifies the exact entry hash after the save
dialog. Multi-file offline archive export is not part of this backend.

The `AskPreviewSource.developmentService(process:address:)` seam is reserved for
D04. It currently rejects all service addresses, including loopback: a URL alone
is never a runtime lease or execution authorization.

The trust boundary relies on macOS WebKit's process sandbox and web security
implementation. It does not claim protection against WebKit vulnerabilities or
an unrestricted same-user process that can alter Typeflux itself. See the
validation report for actual OS/WebKit tests and remaining acceptance limits.

API references: [WKURLSchemeHandler](https://developer.apple.com/documentation/webkit/wkurlschemehandler),
[WKContentRuleListStore](https://developer.apple.com/documentation/webkit/wkcontentruleliststore).
Engine switches: [WebKit WKPreferences implementation](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKPreferences.mm)
and [SPI declarations](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKPreferencesPrivate.h).
