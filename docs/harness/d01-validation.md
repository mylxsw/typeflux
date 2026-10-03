# D01 validation (GUL-176)

Validated on 2026-10-03, macOS 26.6.2 (25G83), Apple Swift 6.4, arm64. Implementation and frozen integration seam: `30eac8ab002024e4c3f3415988997ba2d1d1b2ad`. PR base: `main` at `92fddf8d59baf2a4e9b03f3055ba9617ee417ee8`. Subsequent documentation/screenshot commits do not change executable code.

## Dependencies and scope

The starting main contains P01 #258 (`67b3f563d56fe2d634ece2422ef64e2e871cc5e0`), P02 #261 (`fe1d68e446d715ad9f20e3517d2c170191ec4af9`), P06 Swift core #262 (`2506ffcdd9dc17e1108bc6a65ddfc8df39cd9684`) and adapter #265 (`bfc927cdfb1fdfd91acfa4a17710acdf741a4c75`). Multica confirmed these PRs and P06 API #97 are merged. The dependency implementations, current comments and validation reports were read; the full Swift suite and focused P02 regressions below were rerun for this task. No earlier task's results are counted here. D02/D03 remain backlog and had no active runs at the integration check.

The [workspace contract](project-workspaces.md) describes the descriptor boundary, immutable ownership, `withValidatedSnapshot` seam, limits and rollback. The existing harness DTO/wire contract is unchanged. Git and non-Git folders both use a private change manifest; this backend does not create worktrees or automatically apply patches. D02 must materialize a controlled execution copy before starting programs; D03 supplies artifact delivery/preview. The default production composition does not advertise or dispatch `project_files`.

## Commands and outcomes

| Revision / command | XCTest | Swift Testing | Command outcome |
| --- | --- | --- | --- |
| Unmodified main, `swift test` before implementation | 2,668 reported: 2,664 passed, 4 skipped | 704 tests; account-card click test failed 4 assertions | Failed; retained baseline |
| Final implementation, `make coverage` | 2,681 reported: 2,677 passed, 4 skipped | 708 passed | **Passed**, HTML generated |
| Final focused regression, `swift test --enable-code-coverage --filter 'AskProject\|AskFileToolsTests\|AskLocalApprovalTests\|AskScopedApprovalTests'` | 17 passed | 21 passed, including parameterized cases | **Passed** |
| Unmodified main, fresh `make coverage` after implementation | 2,668 reported: 2,664 passed, 4 skipped | 704 passed | **Passed**, HTML generated |

An intermediate implementation coverage run had four assertions fail in `recordingHintStaysCenteredAndFollowsTheCapsuleDuringMorphing` (native raster geometry). It was not counted as a pass. The final full run passed without skipping this test or weakening its assertions. The initial main account-card failure also did not recur in the final main coverage run. Native UI timing/rendering remains intermittent; these results do not claim that this task fixes those tests.

The four skips are unchanged: real Chrome, real Safari, real desktop drag/window movement, and the opt-in memory-settings failure screenshot. All new project tests executed. Focused coverage includes actual filesystem replacement, symlink/hardlink/FIFO denial, stale hashes, task/owner isolation, directory locking, corrupted manifests, restart/reopen, revocation, Unicode byte bounds, extreme pagination, and applying the exported patch with real `git apply --check` / `git apply` to a dirty disposable Git repository. No user repository is changed by these fixtures.

The focused run also asserts that both local and cloud conversation loops bind the authenticated owner, conversation and actual run to the executor. Ordinary `files` and scoped-approval regression suites pass. Five localization bundles pass `plutil -lint`; `git diff --check` passes. Production review views were rendered and visually checked in light and dark appearances; screenshots are in `docs/images/ask-project-review-{light,dark}.png`.

## Coverage denominator

Full-run profiles were exported **before** any subsequent focused run or baseline rebuild, so no filtered or historical profile is mixed into these totals. Values below are LLVM executable **lines**; regions are reported separately. App totals include files under `Sources/Typeflux/`, excluding `.build`, tests and the separate Objective-C audio-safety target. Generated accessors/dependencies in the coverage script's broader total are consequently outside this denominator.

| Module | Covered / executable lines | Line coverage |
| --- | --- | --- |
| `AskProjectWorkspace.swift` | 357 / 358 | 99.72% |
| `AskProjectFileAccess.swift` | 111 / 113 | 98.23% |
| `AskProjectChangeSet.swift` | 99 / 102 | 97.06% |
| `AskLocalTools+Project.swift` | 126 / 128 | 98.44% |
| Modified `AskFileTools.swift` | 168 / 173 | 97.11% |
| **Core aggregate above** | **861 / 874** | **98.51%** |
| `AskProjectReviewView.swift` (UI, separately reported) | 50 / 70 | 71.43% |
| Main Swift app baseline | 67,131 / 127,376 | 52.70% |
| Final Swift app | 67,933 / 128,195 | 52.99% |

Core region coverage is **454 / 483 = 94.00%**. The core 90% line target is met and the full-app baseline increases. The full-app 90% target is not met; no whole-app coverage claim is substituted for the scoped module result. Interactive save-panel callbacks are not automated by the rendering test, which accounts for the lower UI coverage; store/export authorization, revisions, full bytes and patch hashes are tested independently.

Reproduce with `make coverage`. The explicit archive/export used for comparison was:

```sh
xcrun llvm-profdata merge -sparse .build/out/Products/Debug/codecov/*.profraw -o full.profdata
xcrun llvm-cov export .build/out/Products/Debug/TypefluxTests.xctest/Contents/MacOS/TypefluxTests \
  -instr-profile=full.profdata > full-coverage.json
```

`swiftlint lint --strict --quiet Sources/Typeflux/Ask/Project` passes with zero violations. Whole-repository `swiftlint lint Sources --strict --baseline .swiftlint-baseline.json --quiet` remains nonzero: **969 main / 972 implementation diagnostics**. New diagnostics are two shared dispatcher complexity thresholds (`AskLocalTools` / approval dispatch) and one statement-position warning in the existing conversation error handler; existing size/complexity diagnostics also reflect the small additions. No baseline suppressions were added to hide them. The project read/write boundary documents one narrowly scoped parameter-count exception to keep ownership, authorization and expected version explicit.

## Environment acceptance still outstanding

| Surface | Evidence / limitation |
| --- | --- |
| Local files and Git | Real disposable filesystem and Git integration verified on this Mac. Other macOS/filesystem versions were not tested. |
| Desktop UI | Production view bitmap renders checked; interactive save dialog/destination selection was not manually accepted. |
| Real model | Not invoked. Tool/schema and conversation-loop tests use fixtures. |
| External MCP | Not connected. Existing deterministic MCP tests ran in the full suite. |
| Safari / Chrome | Real automation acceptance tests skipped without their explicit opt-in/interactive permissions. |
| Accessibility / Automation / screen recording | No permission changes requested; real desktop action acceptance not performed. |
| Database / API | No database/API changes in this local Swift task; no PostgreSQL acceptance claimed. |

No remote push/PR operation is added to the product, no runtime/preview is launched, and no production capability is enabled. This development PR is for human review; production rollout and the D02/D03/D04 combination remain separate acceptance steps.
