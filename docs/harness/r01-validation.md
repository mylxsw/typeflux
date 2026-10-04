# GUL-180 client validation

Validated locally on 2026-10-04 on macOS 26.6.2, Apple Swift 6.4, against main
`f403fbe33cdcbe0bd14a7ff859661501d59778bb`. The compatible API is
[typeflux-api #100](https://github.com/mylxsw/typeflux-api/pull/100).

## Main integration check

On 2026-10-04, merged main `65f2d6fc` into the PR branch while preserving the
R02 budget commit `8bf3c5f7`. The five localization conflicts were independent
appended sections. All parent key/value changes were checked against the merge
base, and all five resolved tables passed `plutil -lint`. `git diff --check`
passed; the Memory, source-context, Skills, and budget changes are retained.

The new `make coverage` run **failed**: XCTest executed 2,804 tests with five
skips and zero failures; Swift Testing executed 793 tests and reported five
assertion failures in two unchanged UI tests:
`accountNameClickTogglesTheAccountCard` and
`recordingHintsKeepTheirRoundedEndsInsideTheWindow` (classic style).
The full overlay suite passed separately (six tests), and the account test passed
separately (one test). These isolated checks do not turn the full run into a pass.
No UI code was changed to suppress the failures, and no new full coverage summary
was produced. The coverage figures below belong to the initial implementation.

## Initial implementation results

- `make coverage` (runs the complete `swift test --enable-code-coverage` suite):
  passed. XCTest executed 2,769 tests: 2,766 passed, three skipped, zero failures.
  Swift Testing passed 749 tests in 101 suites.
- The skipped tests are the real Chrome fixture, Safari fixture, and desktop
  drag/cancellation/window-movement acceptance tests. They require the explicit
  interactive automation acceptance flag and browser/Accessibility permissions;
  they are not counted as passes.
- After a whitespace-only lint fix, additional fixture budget assertions, and
  removing an unused transparent sheet screenshot, the focused provenance and
  native correction interaction tests were rerun: 13 passed, zero failures.
- `git diff --check`: passed. Repository SwiftLint still exits 2. Comparing the
  current and fresh-main source findings by file, rule, and severity yields no
  positive count increments (1,198 main findings, 1,189 current findings). This
  is a count comparison, not a claim that the repository passes lint.

## Coverage scope

The full-run LLVM report excludes `.build` and `Tests`, as the repository's
coverage script does. Whole-source line coverage is **54.34%**, versus **54.09%**
from a fresh main checkout tested during this task. Region coverage is 58.66%
versus 58.41%. The main test run reproduced the account-popup failure described
below; its raw full-run profiles were merged explicitly to obtain that baseline.

| File | Line coverage | Region coverage |
| --- | ---: | ---: |
| `Ask/MemoryProvenance.swift` | 100.00% | 100.00% |
| `Ask/AskMemory.swift` | 95.28% | 92.96% |
| `Ask/AskMemoryNotes.swift` | 96.14% | 88.70% |
| `Workflow/RecentInputMemoryStore.swift` | 98.84% | 93.75% |
| `Workflow/GlobalSoulMemoryStore.swift` | 97.96% | 92.97% |
| `Ask/AskConversationModel.swift` | 94.11% | 84.75% |
| `Ask/Local/AskLocalEngine.swift` | 95.87% | 90.51% |
| `Settings/AskMemoryNotesSettingsModel.swift` | 96.00% | 91.67% |
| `Settings/MemoryNotesEditorView.swift` | 96.36% | 72.22% |
| `Workflow/WorkflowController+RecentInputMemory.swift` | 25.45% | 35.14% |
| `Settings/RecentInputMemoryManagementView.swift` | 0.00% | 0.00% |

Memory persistence/provenance core files exceed the 90% line target. The table
also exposes the remaining workflow/UI coverage gaps; neither all-region 90%
nor all-modified-file 90% coverage is claimed. Unchanged browser-scope resolution
was moved to `RecentInputMemoryScope.swift` so persistence coverage is measurable
separately; it remains included in the whole-source denominator.

## Behaviors exercised

Tests cover old note/Recent JSON and the shared Swift/Go wire fixture, bounded
explicit-note-first injection, default-off provenance/correction rollout,
account isolation including A-to-B-to-A observations, expiry, stale-version
corrections, deletion tombstones, source recovery after interrupted invalidation,
failed atomic writes and retry, stale AX generations, Soul pending/batch fencing,
late fetches, reopened drafts, scoped local/cloud purge routing, and preserving
conversation history while removing pending memory injection. Existing P02 write
approval, P03 latest-record merge, and P04 persistence tests remain in the full run.

The native AppKit/SwiftUI correction test opens the production editor, changes
text, injects a failed save, retries successfully, and verifies persisted version
and supersedes after reopening the store. Source deletion is verified through
store and settings-model tests. An exploratory synthetic native delete click
could not reliably hit the control; native deletion is not claimed as verified.

Production-view evidence:

- [Corrected note and provenance](r01-evidence/memory-corrected-note.png).
- [Retryable source-removal failure](r01-evidence/memory-note-removal-error.png).

## Failures and remaining acceptance

An earlier full run failed four assertions in
`AskAccountFooterClickTests.accountNameClickTogglesTheAccountCard`; the fresh-main
comparison reproduced those assertions. The final full run passed. That existing
native popup instability remains a limitation, not a resolved R01 defect.

No real model calls, external MCP, cross-device source synchronization, or full
browser/desktop permission matrix were exercised. The native tests host views
in this macOS session; they do not establish the full signed-app permission flow.
API tests used a real isolated PostgreSQL 16 container; its report records the
passing Ask race tests and failing full-repository ASR race tests.

GUL-184 PR #277 was checked for shared files: its Skills changes are separate
from this PR's Memory section, but both append localization entries. Preserve
both sets when resolving integration conflicts. No database migration, production
enablement, or merge was performed. Deploy the API first, then the client; keep
`ask.memoryProvenanceEnabled` false until combined human acceptance. See the
[lifecycle and R02 handoff contract](r01-memory.md) for rollback and scope limits.
