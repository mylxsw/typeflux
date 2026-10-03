# GUL-177 / D02 validation

## Environment and baseline

- macOS 26.6.2 (25G83), Apple Silicon; Apple Swift 6.4 / Xcode's macOS 27 SDK;
  preinstalled CLT Python 3.9; SwiftLint 0.65.1.
- Base: `68a503282b022607e2091482afc2aa5bd5b0b0b5`, containing D01 #271,
  P01 #258 and P02 #261. PR base is `main`, not a sibling's active branch.
- D03 was active concurrently; this change adds D02-only files and does not
  modify shared DTOs, `AskLocalTools`, DI, Settings, localization, artifact cards
  or PreviewHost. The host integration contract is in `project-runtime.md`.
- An actual unmodified-main `make coverage` run completed 2,681 XCTest cases
  (2,677 passed, four skipped) and 708 Swift Testing cases (707 passed, one failed).
  The failure was `AskAccountFooterClickTests.accountNameClickTogglesTheAccountCard`,
  with assertions at lines 37, 39, 43 and 44. No assertion was removed or relaxed.
  Later full runs demonstrate that this UI test is intermittent.

## Final verification

Final `make coverage` on the final implementation ran all **2,716 XCTest cases**:
**2,712 passed, four inherited skips, zero failures**. All **35 new D02 cases**
passed. Swift Testing ran **708 cases: 707 passed and one failed**, with exactly
the same four account-popup assertions as the unmodified-main baseline.
Consequently the final `make coverage` command exited 2; it is not reported as
green. An intermediate full run was green, which does not replace this final
result. The raw final profiles were exported independently for the measurements
below. No D02 failure remains.

The targeted command was:

```sh
swift test --enable-code-coverage --filter 'AskProjectRuntimeTests|AskProjectServiceTests|AskProjectExecutionCopyTests'
```

It passed all 35 new XCTest cases. An earlier integration run on this branch
also passed 64 XCTest cases plus four Swift Testing cases, including D01 project
approval/workspace integration, `ManagedProcessTests`, and real analysis sandbox
isolation. The final whole-suite run above is authoritative for the final code.

The four inherited skips are:

- `AskAutomationAcceptanceTests.testRealChromeFixture` and `testRealSafariFixture`:
  interactive browser permissions and `TYPEFLUX_AUTOMATION_ACCEPTANCE=1` unavailable.
- `AskAutomationAcceptanceTests.testRealDesktopDragCancellationAndWindowMovement`:
  interactive Accessibility authorization unavailable.
- `AskMemoryNotesSettingsTests.testRenderRemovalFailure`: optional snapshot flag
  `TYPEFLUX_MEMORY_NOTES_SNAPSHOTS` not set.

New D02 tests have no environment skips. Failed development runs exposed a Data
cursor indexing bug under output eviction and a readiness probe that was too
short for split responses under load; both were fixed with retained regression
cases. No skipped or predecessor-task result is counted as a D02 pass.

## Coverage and lint

| Production file | Covered / executable lines | Line coverage |
| --- | ---: | ---: |
| `AskProjectExecutionCopy.swift` | 144 / 146 | 98.63% |
| `AskProjectPortLease.swift` | 110 / 113 | 97.35% |
| `AskProjectProcessIO.swift` | 126 / 127 | 99.21% |
| `AskProjectRuntime.swift` | 207 / 207 | 100.00% |
| `AskProjectRuntimePolicy.swift` | 90 / 92 | 97.83% |
| `AskTerminalSession.swift` | 237 / 245 | 96.73% |

New core line coverage: **914/930 = 98.28%** (90% target met).
Core region coverage: **453/500 = 90.60%**.
Application Swift line coverage: **67909/128195 = 52.97% → 68825/129125 = 53.30%**.

The coverage denominator is LLVM executable source lines, not an estimate from
test counts. The new core comprises exactly the six new production Swift files.
Application baseline comparison includes `Sources/Typeflux/` only; it excludes
test sources, generated code, third-party dependencies, CLI entry points and the
C audio helper. No UI or external-environment acceptance is inferred from it.

Coverage was exported from the test bundle with `xcrun llvm-cov export
-summary-only`. For failed whole-suite runs, `xcrun llvm-profdata merge -sparse`
merged both current XCTest and Swift Testing raw profiles; no previous run's
profiles or targeted-only result was substituted for whole-suite coverage.

All ten added Swift files pass strict SwiftLint. A full-repository lint run found
2,948 diagnostics in unchanged files (including test sources); they remain
outside D02. The new files add zero diagnostics. `git diff --check` passes.

## Real acceptance evidence and remaining gates

The tests launch actual sandboxed CLT Python through POSIX spawn, use real files,
pipe/PTY descriptors and loopback sockets. They cover:

- staged source overlays, local imports, binary assets, explicit `.git` exclusion,
  no source writes, new directory depth limits, oversized listings/files,
  source changes/replacements and revocation during copy;
- symlink/hardlink/FIFO rejection, reads and writes outside the execution copy,
  a minimal child environment and no inherited host/source descriptors;
- real fork/posix-spawn/subprocess/foreign-exec denial, real outbound socket
  denial with a live loopback listener as the target, public-IP connect denial,
  wildcard/extra-port bind denial, and dependency-installation rejection;
- PTY isatty, canonical input/EOF and overlong-line rejection; pipe EOF and UTF-8
  bytes split across one-byte cursor pages; 2.2 MB output flooding, bounded log
  retention, explicit cursor loss and late input rejection;
- single-use start/input approval, changed arguments, expired/revoked grants,
  wrong owner/run/session and forged handles, process capacity, pre-launch task
  cancellation, Stop, run cancellation, revocation, workspace deletion and
  injected app-termination notification;
- nonzero and signal exit, a SIGTERM-ignoring process with closed output,
  actual HTTP readiness including fragmented responses, wrong nonce,
  readiness timeout, port occupation, listener closure and direct-child reaping;
- reopening the runtime store, journal invalidation, retained outputs, refusal
  to replay old leases, and exclusive runtime-store ownership.

Limitations remain explicit:

- Only the single-process preinstalled Python backend is implemented. Shells,
  npm/pip installation, arbitrary child trees and external runtimes are denied.
- Graceful app-exit handling is tested via the real notification handler with an
  isolated notification center. Store restart is tested by reopening on disk;
  this is not a real signed-app crash/relaunch acceptance test. After host
  SIGKILL/crash, old handles are invalidated but orphan cleanup is not guaranteed.
  No persisted PID is killed. A stronger guardian is a production rollout gate.
- D04 still owns model-tool registration, approval/terminal UI, cancellation
  wiring and D03 dynamic preview integration. Those user flows have not been
  enabled or presented as complete desktop acceptance.
- Real models, external MCP, Safari/Chrome, Automation, Accessibility, screen
  recording and other macOS/CLT versions were not validated. No database or API
  changes are involved. No CI result is substituted for these missing conditions.

Production gates remain false; analysis execution and its network behavior are
unchanged. Copies/logs are retained for review, and no user-owned root is deleted.
