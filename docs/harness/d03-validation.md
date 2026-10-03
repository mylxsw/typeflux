# GUL-178 / D03 validation

Validation date: 2026-10-03. Environment: macOS 26.6.2 (25G83), arm64,
Xcode 27.0 (27A266a), Swift 6.4, WebKit 21624.5.1.11.3. Base: `main@68a503282b022607e2091482afc2aa5bd5b0b0b5`
(D01 #271 merged). P06 API #97 and Swift #262/#265 were independently confirmed
merged through the platform's PR records. D02 was active on its own branch and
was not used as a dependency. The PR base is `main`.

## Behavior and scope

- Immutable device-only artifact IDs; MIME/size/SHA-256, owner/conversation/run,
  optional workspace, creation time and 30-day retention. Explicit resource
  manifests use staged bytes, verify every declared source version and publish
  only after snapshot validation succeeds. Source trees are never modified.
- Approved `artifact` dispatch with independent default-false creation/preview
  gates. P00 DTOs and P06 wire capability negotiation remain unchanged. A metadata
  receipt supports legacy Cloud history without uploading artifact bytes.
- Native text/image previews, offline HTML/JS, visible errors/truncation, and
  original-entry export with integrity and authorization checks. Existing image
  card export errors are now visible too. Export does not create a multi-file ZIP.
- Static previews have a separate WebKit configuration and origin, a manifest-only
  scheme handler, CSP sandbox, content rules, denied native pickers and engine
  restrictions. D04's dynamic-service seam explicitly rejects addresses today.

The detailed limits, retention behavior and integration contract are in
[`device-artifacts.md`](device-artifacts.md).

## Test evidence

The clean main baseline ran `make coverage` in this task: **2,681 XCTest cases,
4 existing skips, zero failures; 708 Swift Testing cases passed**. This is fresh
evidence, not a reused D01 report.

The first implementation-wide coverage attempt reproduced four assertions in
`AskComposerInteractionTests.accountNameClickTogglesTheAccountCard` (visibility
and pointer containment). That failure was already documented in the parent
plan, but it did **not** occur in this task's clean-main baseline. No assertions
were removed or changed. The final run below includes the subsequent lifetime
cleanup fix and retains the unchanged account test.

Final `make coverage` **passed**: **2,706 XCTest cases (2,702 passed, 4 existing
skips), and 708 Swift Testing cases passed**. The unchanged account-popup test
passed in this final run. All 25 new artifact/preview XCTest cases ran with no
skips or failures. No previous results or optional skips are counted as passes.

Core executable-line coverage from the final full run:

| File | Covered / executable lines | Coverage |
| --- | ---: | ---: |
| `AskArtifactCapture.swift` | 52 / 52 | 100.00% |
| `AskArtifactStore.swift` | 164 / 167 | 98.20% |
| `AskLocalTools+Artifacts.swift` | 99 / 100 | 99.00% |
| `AskPreviewEnginePolicy.swift` | 38 / 39 | 97.44% |
| `AskPreviewHost.swift` | 176 / 194 | 90.72% |
| **New core modules** | **529 / 552** | **95.83%** |
| Native card/preview UI (`AskStoredArtifactCard.swift`) | 159 / 224 | 70.98% |

The core denominator is the five files listed, not the pre-existing Ask model,
view and dispatch files; UI coverage is not included in the core claim. Full
production Swift coverage includes all of those files and increased from
**67,934 / 128,195 = 52.99%** on main to **68,726 / 129,082 = 53.24%**. Tests,
dependencies and the two C/Objective-C audio-safety files are excluded from this
Swift percentage. The unfiltered production total including those two files is
68,797 / 129,253 = 53.23%.

`git diff --check` and strict lint of the new `Ask/Artifacts` directory passed.
Full-repository strict lint still fails: **972 diagnostics on clean main and
972 on this branch**. Existing large shared functions have changed complexity/
length values, but no diagnostic category/file count was added. The lint baseline
file and existing assertions were not modified.

The targeted artifact suites cover real file mutation/replacement, symlink and
hardlink rejection, hash corruption, path traversal and aliases, file/resource
limits, owner/run/conversation mismatch, staging precedence, revoked grants,
failed capture without publication, durable reopen, expiry cleanup and export
errors. A real SQLite cache/journal test exercises tool output → request/message
→ cache → reopen → selected-session access. It caught and fixed fractional-date
roundtrip mismatch; creation/expiry now use canonical whole seconds.

Real WebKit tests run JavaScript and load declared local JS/CSS, with no native
bridge or persistent storage. Actual loopback TCP listeners observe zero
connections for external scripts/styles/images, CSS imports, preconnect, fetch,
WebSocket, beacon, iframe, worker, form and navigation probes. Cross-artifact and
file access fail; page exceptions, missing resources, revoked access, cancelled
opening and process failure are surfaced/closed. Native UI rendering covers
light/dark cards, long-text truncation, unsupported MIME, invalid encoding,
bounded image decoding and the disabled HTML state. Screenshots are attached to
the issue; they are presentation evidence, not proof of isolation.

## WebRTC finding and compatibility boundary

The initial real UDP/STUN probe **failed**: WebRTC sent traffic despite CSP and
WebKit content rules. The implementation now disables peer connections, media
devices, screen capture and DNS prefetching at the WebKit engine level. The same
UDP probe passes after this fix. Runtime method signatures and disabled values
are checked; missing, incompatible or ineffective switches fail closed before
any artifact is loaded. Tests cover those failure cases.

These switches are **WebKit SPI**, described in the upstream
[implementation](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKPreferences.mm).
This is suitable only for evaluation in the existing Developer ID distribution;
it is not an App Store-compatible implementation. Other macOS/WebKit versions
need acceptance before enabling HTML preview. Public CSP/content-rule APIs alone
must not be substituted and described as equivalent isolation.

## Remaining acceptance limits

- All production creation/preview gates remain false. No production rollout,
  merge, remote file upload, or dynamic-service integration was performed.
- Tested with real WebKit on this macOS host. Safari/Chrome automation and
  Automation/Accessibility/screen-recording acceptance remain separate and
  unverified. The existing optional Chrome, Safari and desktop-drag acceptance
  cases were skipped; the fourth existing skip is the optional memory-settings
  failure screenshot test.
- No real model, external MCP server or cross-device Cloud service was used.
  Legacy/typed receipts and device absence are deterministic local fixtures.
  No API/database server code changed; no PostgreSQL results are claimed.
- Actual file writes and failure paths were tested. Interactive NSSavePanel
  acceptance is still manual; native UI coverage is reported separately from
  the core modules. Resource archive export and automatic resource discovery
  are intentionally absent and explicitly described in the tool contract.
- The WebKit process sandbox is relied on; this does not defend against browser
  engine vulnerabilities or an unrestricted malicious same-user process.

Self-review checked descriptor lifetimes, postvalidation publication, captured
versus live resource bytes, authorization after suspension/save dialogs, exact
cache reference equality, preview cancellation/teardown and shared Ask wiring.
No new dependencies, database migrations, permission reuse or wire capabilities
were introduced.
