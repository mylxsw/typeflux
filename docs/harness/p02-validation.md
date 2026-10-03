# P02 approval validation — 2026-10-03

Tested implementation: `2c61e3892b76bbace00fc7f79ba2a5a9bc56d08f`.
Baseline: `67b3f56` (the main checkout at task start), including P00 merge
`b75081908c702e44041221bebc544a453c317e73`. PR base is `main`.
Environment: macOS 26.6.2 (25G83), arm64, Apple Swift 6.4
(`swiftlang-6.4.0.34.1`), Xcode's Swift Build backend. No API/DB schema changes.

## Results

| Check | Result |
|---|---|
| Final scoped approval, target adapter, policy, MCP, screenshot consent and approval UI filter | 13 XCTest + 55 Swift Testing tests passed; zero failures/skips. Parameterized cases are included in their parent test count. |
| Final `make coverage` (runs `swift test --enable-code-coverage`) | XCTest: 2,628 reported, 2,627 passed, 1 skipped. Swift Testing: 593 reported, 592 passed, 1 failed with 4 assertions. Nonzero exit is retained. |
| Baseline full `swift test --enable-code-coverage` in an independent detached worktree | XCTest: 2,627 reported, 2,626 passed, 1 skipped. Swift Testing: 569 reported, 568 passed, the same 1 failed with 4 assertions. |
| Earlier plain `swift test`, before the final additional regression cases | XCTest: 2,627 reported, 1 skipped, no failures. Swift Testing: 584 reported, the same account UI test failed with 4 assertions. This earlier run is not the final approval acceptance result. |
| Opt-in approval rendering | Light and dark PNGs rendered from production `AskApprovalCard` with synthetic data; both inspected for clipping and readable action/target/content/single-use copy. |
| Self-review | Verified no wire DTO/fixture changes, no tool-name grants, no raw argument/target/hash diagnostics, and no new rollout capability enabled. `git diff --check` passed. |

The repeated baseline failure is
`AskAccountFooterClickTests.accountNameClickTogglesTheAccountCard`, at lines
37, 39, 43 and 44 (panel visibility and pointer containment). It is unrelated to
the approval changes and reproduces on the base commit in this same run.

An intermediate instrumented run also failed two parameter cases of
`OverlayTransitionRenderingTests.recordingHintsKeepTheirRoundedEndsInsideTheWindow`
at line 185. Neither the baseline comparison nor the final instrumented run
reproduced these rendering failures. They are recorded as intermittent native
rendering failures; no assertion or production overlay code was changed.

The one explicit XCTest skip is the pre-existing opt-in
`AskMemoryNotesSettingsTests.testRenderRemovalFailure`, which requires
`TYPEFLUX_MEMORY_NOTES_SNAPSHOTS`. Other opt-in visual/live test methods may
return without running their optional scenario when its environment flag is
absent. Test-runner pass counts do not imply live environment acceptance.

## Coverage denominator

Swift coverage below is llvm-cov **executable lines**, including its synthesized
closures/accessors. Production totals sum non-`.build` `Sources/` files; tests
and package dependencies are excluded identically on the baseline and candidate.
Profiles from baseline, candidate full suite, and focused renders were kept
separate. These numbers use only each full-suite run, not merged focused runs.

| Scope | Covered / executable lines | Coverage |
|---|---:|---:|
| New policy and grant store (`AskToolPolicy.swift`) | 110 / 110 | 100.00% |
| New executor target boundary (`AskLocalTools+Approval.swift`) | 198 / 214 | 92.52% |
| New core files combined | 308 / 324 | 95.06% |
| Conversation model, entire file | 1,247 / 1,327 | 93.97% |
| MCP registry, entire file | 235 / 242 | 97.11% |
| Approval UI, entire file | 339 / 351 | 96.58% |
| Existing local executor, entire file | 295 / 444 | 66.44% |
| Existing conversation views, entire file | 1,845 / 2,402 | 76.81% |
| Baseline production total | 62,886 / 123,655 | 50.86% |
| Candidate production total | 63,304 / 124,099 | 51.01% |

The new core modules exceed 90%; the whole local executor and conversation view
files remain below that target. Their denominators include real desktop event
posting and interactive UI paths, not just the changed approval logic. No claim
is made that every modified file or the full application exceeds 90%.

Because the full suite returns nonzero, `scripts/coverage.sh` stops before HTML
generation. This toolchain also emits `TypefluxTests.xctest` and separate
`codecov/*.profraw` files instead of the older script's expected
`TypefluxPackageTests.xctest`/`default.profdata`. Coverage was extracted without
suppressing the failed test exit:

```sh
xcrun llvm-profdata merge -sparse "$BIN"/codecov/*.profraw -o full.profdata
xcrun llvm-cov export "$BIN/TypefluxTests.xctest/Contents/MacOS/TypefluxTests" \
  -instr-profile=full.profdata -summary-only > full-coverage.json
```

`BIN` is the path returned by `swift build --show-bin-path` for that checkout.
The baseline used the same scratch directory sequentially to reuse dependency
builds; its source worktree and resulting profiles were separate.

## Reproduction and acceptance matrix

```sh
swift test
make coverage
TYPEFLUX_ASK_SNAPSHOTS=/absolute/output/directory swift test --enable-code-coverage \
  --filter 'Ask.*Approval|AskToolPolicyTests|AskMCPToolsTests|AskHarnessUITests|renderScopedApprovalCards'
```

- A navigation grant cannot authorize pay/publish/send/delete/click/fill/key/hotkey
  or unknown actions. Repeated memory/file/code/MCP/desktop mutations ask again.
- Exact UTF-8 argument hashing distinguishes JSON whitespace/key ordering and
  different Unicode byte sequences. Unknown parameter constraints deny.
- Owner, conversation, run/step/call, target/path/domain/version, tool/schema,
  MCP identity/reconnect, expiration, revocation and risk changes deny the old
  grant. Forty concurrent single-use consumers produce exactly one success.
- A same-ID server call with changed arguments never executes. Cancellation,
  stale approval-card callbacks, steering, and revocation during executor
  preparation cannot authorize dispatch.
- Canonical file/symlink changes and file replacement at the executor boundary
  are rejected. Desktop coordinates outside the approved bounds are rejected
  without sending real events.
- MCP annotations cannot reduce risk. A live mock registry rejects changed
  schemas, removed tools and reconnected server instances before `callTool`.
- Submitted screenshot consent remains submission-scoped. Historical images,
  other-device messages and unrelated tools do not inherit it.
- Legacy/missing trusted capability paths never offer reusable conversation
  grants. Public P00 contract tests remain part of the full run.

## Limits and rollout

Production reuse remains off. No true model, external MCP service, real browser
page or Accessibility-controlled user application was used for side-effect
acceptance. Browser scripts were checked against installed Safari/Chrome
scripting dictionaries; unit runners exercise target changes and pinned script
construction. Native process/window failures are tested with injected evidence.
The two delivered images are synthetic UI renders, not live desktop captures.

Code approval is tested with a fake executor; P01's host-dependent sandbox gate
is preserved. This report does not claim a new successful real sandbox run.
PostgreSQL was not involved in this Swift-only policy change.

P09 still owns hostile-page-resistant observation identity and effect evidence.
The module does not infer which account is selected inside an arbitrary external
app, and file approval checks are not a replacement for descriptor-based file
isolation. See [scoped-approval.md](scoped-approval.md) for the binding and rollback
contract. P06 must retain the shared result adapter when integrating its MCP
schema/content path. No later phase or production rollout was started.
