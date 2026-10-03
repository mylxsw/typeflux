# GUL-167 validation record

Tested on 2026-10-03, macOS 26.6.2 (25G83), arm64, Apple Swift 6.4.
Base: `41d207accecf2f33583be670ead46cf60d32769b` (`main`). No unmerged dependency.
See [execution contract](managed-analysis-execution.md) for the production gate.

## Executed tests

| Run | Actual result |
| --- | --- |
| Unmodified base: `swift test --enable-code-coverage --jobs 4` | 2,547 XCTest cases, one failure; 557 Swift Testing cases, one failing case with four issues |
| Final implementation: `make coverage` (invokes `swift test --enable-code-coverage`) | 2,574 XCTest cases, zero failures; 557 Swift Testing cases, the same failing account-click case with four issues |
| Relevant suites in final full run | 44 cases, zero failures: ManagedProcess 10, secure directory 7, isolation 10, existing sandbox 5, AskAgentTools 12 |
| Isolated `swift test --skip-build --filter accountNameClickTogglesTheAccountCard` | One Swift Testing case passed |
| Changed production files: strict SwiftLint and `git diff --check` | Passed |

No tests in the new acceptance suites were skipped. Real macOS child processes,
Seatbelt, CLT Python and sockets were used; these are not mock sandbox tests.

The full-suite failure is
`AskComposerInteractionTests.accountNameClickTogglesTheAccountCard`, assertions
at `AskAccountFooterClickTests.swift:37`, `39`, `43`, `44`. It reproduces on the
unmodified base and passes when run alone. This is evidence of an existing
suite interaction, not proof of its precise cause; no UI assertions were removed
or weakened. The base additionally failed
`WorkflowControllerProcessingTests.testOpeningPersonaPickerDoesNotPlayCueWhenSoundEffectsAreDisabled`
at line 791; both implementation full runs passed that case.

Consequently `make coverage` exits nonzero at the test step. The full run's raw
LLVM profiles were merged and exported manually with `llvm-profdata merge
-sparse` and `llvm-cov export/report` against
`.build/out/Products/Debug/TypefluxTests.xctest/Contents/MacOS/TypefluxTests`.
The isolated rerun was performed **after** saving the full-run profiles and does
not replace or inflate these coverage numbers. No all-green full-suite claim is
made.

## Coverage scope and actual results

The 90% target is measured as LLVM executable-line coverage of changed core
production files, including success and error handling. Region coverage is also
reported rather than being represented as line coverage.

| Core file | Covered / executable lines | Line coverage |
| --- | ---: | ---: |
| AskCodeSandbox.swift | 231 / 234 | 98.72% |
| Execution/AskSecureDirectory.swift | 194 / 200 | 97.00% |
| Execution/ManagedProcess.swift | 266 / 277 | 96.03% |
| Combined | 691 / 711 | 97.19% |

Combined function coverage: 104/109 (95.41%). Combined region coverage: 335/381
(87.93%). Untaken paths include OS error paths and the pre-macOS-26 spawn API
compatibility branch. Swift emits no branch coverage counter for these files.

Whole-repository production coverage uses the same `llvm-cov` filter as the
repository script (`.build|Tests` excluded), with every included source under
this repository's `Sources`:

- Base: 61,830 / 122,680 executable lines (50.40%).
- Final: 62,246 / 123,114 executable lines (50.56%).

## Acceptance evidence

- Exclusive no-follow writes preserve the sentinel through a preexisting script
  symlink, a directory substitution between open and write, and 200 concurrent
  file/symlink substitutions. Root/component symlinks and unsafe private-directory
  permissions are refused. Cleanup and artifact reads do not follow links;
  artifacts reject FIFOs, hardlinks, traversal and oversized reads.
- Fake environment credentials, a sibling session sentinel and an external temp
  file cannot be read by the program. Explicit skill content remains readable
  but not writable. Python's standard library and image output work. Loopback
  socket creation fails with permission denied; the existing curl test also passes.
- Parent-exits-first pipe holders, ignored TERM, stdout/stderr floods, cancellation,
  cancellation/timeout races, and the drain deadline after parent exit are tested.
  The 200 ms timeout fixture returns within its asserted 2.2 s total budget and
  checks that the leader and child cannot run afterward. Ordinary descendant
  zombies awaiting launchd reaping are distinguished from live processes.
- The inherited-descriptor test deliberately omits CLOEXEC on a host descriptor;
  the spawned process still cannot access it, and stdin is closed for input.
- Cancellation removes the private script directory and releases the session lock.
  Concurrent access fails and pruning preserves an active session.
- A finite real fork/setsid fixture demonstrates escape from the managed group.
  The production gate remains closed, and the tool is not advertised. This is
  **not** a claim that arbitrary process trees or resource exhaustion are contained.

## Remaining validation and compatibility limits

Other supported macOS versions, a manually driven signed desktop app, live model
sessions and production rollout were not validated. The automated desktop suite
has the baseline failure above. No database behavior changes in this PR.

The integration path supports system zsh and CLT Python only; arbitrary PATH,
Homebrew, nvm, pyenv, Node and third-party Python packages are not enabled.
Legacy v1 workspace files remain on disk but are not reused. Session workspace
artifacts intentionally persist; per-run control scripts do not. Re-enabling
production code execution requires the stronger containment acceptance described
in the contract, not merely passing the ordinary-process-group tests.
