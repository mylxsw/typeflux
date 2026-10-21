GUL-438 bounds the existing files tool and both AskLocalTools dispatch paths. It adds scalar-aligned read continuation, lazy search/list budgets, metadata versions and coordinated conditional mutations. See `review.md` for the threat model, guarantees, residual rename gap and self-review.

Base: `151b334206180a762a2cf1ce80d176d457aba31b`, accepted stage-4 main. Implementation head: `62730ae06f39603f0bff46b0bf9f30c95798efa3`. It is also recorded in `changed-coverage.json`; source SHA-256 values bind the coverage evidence to the exact production files. The PR head includes an additional evidence-only commit. A final fetch confirmed main remained at the same base.

Environment: macOS 26.6.2 / 25G83, arm64, Apple Swift 6.4 (swiftlang-6.4.0.34.1), Xcode's llvm-cov / llvm-profdata.

Only focused local tests ran. The existing runner builds/discovers the package's complete test target for coverage, but executes only the explicit selected methods. No full test, full UI run, concurrent SwiftPM build, CI wait, self-merge or stage-6 work was performed.

The original coverage command (also used for both build retries):

```sh
python3 scripts/test_groups.py --coverage \
  --suite AskBoundedFileToolsTests --suite AskFileToolsTests \
  --suite AskFileDispatchTests --suite AskLocalApprovalTests \
  --suite AskSecureDirectoryTests --suite AskProjectWorkspaceTests \
  --suite AskRecoverySafetyTests
```

`focused-coverage.log.gz` records the fresh-checkout dependency/build preparation failure (864.12s): a Substring/String predicate mismatch, followed by an input-modified diagnostic when corrected before the failed compiler process exited. No tests executed. `focused-coverage-build-retry.log.gz` records the same scope's test-target build failure (212.19s): SwiftFormat had rewritten a for-loop closure type, and XCTest's Objective-C exposure collided on overloaded test helpers. These were corrected using a typed closure array and non-Objective-C helpers. Again no tests executed.

`focused-coverage-test-build-retry.log.gz` records 52 XCTest methods and 14 Swift Testing methods (174.22s). All production-behavior assertions passed; one schema assertion incorrectly inspected JSONValue's debug description. The assertion now decodes the actual schema JSON and verifies both additive properties.

Only the failed method was retried, together with a directly affected existing host caller that had not been included in the first scope:

```sh
python3 scripts/test_groups.py --coverage --filter \
  'AskBoundedFileToolsTests/testToolSchemaAndArgumentBounds|AskAgentToolsTests/testLocalToolsExecuteFilesCodeSkillsAndMemory'
```

Both passed (61.59s), recorded in `focused-method-retry.log.gz`. The retry also checks malformed expected_version types and NUL write input.

Final self-review removed an unused private helper and encapsulated the thread-safe UserDefaults/AskFolderGrants grant check to remove a Sendable capture warning. Only the host/approval scope was rerun after each cleanup:

```sh
python3 scripts/test_groups.py --coverage \
  --suite AskFileDispatchTests --suite AskLocalApprovalTests
```

`final-host-scope.log.gz` and `final-host-sendable-scope.log.gz` retain both actual runs. The final host run covers the final grant-check source, including current-setting revocation and cancellation around publication/commit. Each includes five XCTest methods and six Swift Testing methods.

Coverage is changed executable-line coverage, not project-wide coverage. `initial.lcov.gz` and `retry.lcov.gz` retain coverage for the seven unchanged production files from their respective test invocations. Their earlier host-extension record was dropped because cleanup shifted its source lines. `host-final.lcov.gz` supplies fresh coverage for the final host extension; unchanged-source records may be unioned as well. Source paths are normalized relative to this repository; counts are unchanged. Profiling uses the XCTest bundle plus the actual raw profiles from both XCTest and Swift Testing:

```sh
xcrun llvm-profdata merge -sparse .build/arm64-apple-macosx/debug/codecov/*.profraw -o scope.profdata
xcrun llvm-cov export -format=lcov \
  .build/arm64-apple-macosx/debug/TypefluxPackageTests.xctest/Contents/MacOS/TypefluxPackageTests \
  --instr-profile=scope.profdata <the changed production source paths>
python3 docs/validation/gul-438/changed_coverage.py
```

The script unions the portable LCOV line counts and intersects them with `git diff --unified=0` additions against the stated base. It also records uncovered line numbers and source hashes. The report lists every uncovered line, including root-/ opening and defensive/system-error paths; no whole-project coverage percentage is claimed.

`format.log.gz`, `lint-initial.log.gz`, `lint-final.log.gz` and `parse.log.gz` retain auxiliary checks. Focused syntax parsing and final lint succeeded. Lint retains style warnings. The compiler also emits existing package/test warnings and two search closure-capture reachability diagnostics: the asserted partial/skip paths execute and pass in real-file tests, so those diagnostics do not describe actual runtime reachability. The final host Sendable warning was corrected.

Scope mapping: bounded-file tests cover read continuation, UTF-8/CRLF/scalar/combining boundaries, offset scans, invalid/stale cursors, binary/EOF handling, lazy traversal budgets, partial-empty reporting, identity changes, staging substitution, conditional versions, cleanup and exclusive creation. Dispatch tests exercise the actual raw and approved entry points, deterministic cancellation, grant revocation, commit receipts, concurrent Typeflux writers and an NSFileCoordinator editor. Existing file tests preserve API compatibility; local approvals/recovery cover permission and recovery wiring; secure-directory/project-workspace tests cover the reused descriptor/preview dependencies.

Final results: **67 distinct methods have passing evidence** (53 XCTest and 14 Swift Testing). The two final host runs passed all 11 selected methods each. Coverage commands consumed **1551.03s total wall time**, including dependency preparation, discovery, compilation, startup, execution and all failed-build/method retries; per-command timings are in `test-results.json`. These were fresh/incremental builds, never cached passing results. Final changed executable-line coverage is **757/774 (97.80%)**, above the 80% requirement and 90% target. No further code changes followed the final passing host verification.
