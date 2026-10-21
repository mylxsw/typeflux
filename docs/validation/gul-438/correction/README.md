This correction returns PR #700 for architecture-owner re-review after the two acceptance blockers: cancellation of a queued writer depended on another writer releasing, and an already-revoked grant could leave newly-created parent directories.

Correction base: `dfeff6f5305237a23325c6bf8d03fb42c9ddd717`.
Final implementation: `2134ee69e42cd6b923f1688124d579f0bc957804`.
Original PR base remains `151b334206180a762a2cf1ce80d176d457aba31b`.
The following evidence-only commit does not change production or tests. `environment.txt` records macOS/Swift versions. No full test/UI run, concurrent SwiftPM build, CI wait, merge or later-stage promotion was performed.

The process-wide mutation gate now uses NSCondition with 50 ms timed waits and cancellation checks. It still serializes aliases and overlapping roots. A trusted-host per-operation controller forwards cancellation to both the detached worker and its registered NSFileCoordinator; registration handles earlier cancellation, unregistering is locked, and Foundation cancellation happens outside the controller lock. The actual coordinated mutation remains synchronous and is joined. A direct synchronous Task caller also gets a 50 ms task-cancellation observer, including the small handoff between the last check and starting coordination. This timer is cancelled and its cancellation handler is awaited inside withUnsafeCurrentTask's lifetime. It cannot outlive the operation. Gate waits use no busy spin; there are no orphan mutation workers. Completed commits still return their successful receipts.

Current grant and cancellation checks precede mutation preparation, every descriptor-relative parent-creation call and staging creation. Release-time read/search and precommit identity/content/grant checks remain. An initially revoked grant creates nothing. Revocation at a later boundary prevents that boundary's effect; previously authorized directory creation can remain. Cleanup never removes pre-existing or concurrently-created directories, and staging cleanup remains descriptor-relative.

Deterministic regressions hold writer A, observe B at the occupied gate, cancel B and assert B completion plus no accessor/filesystem effects before releasing A. They cover both same-target and unrelated-target host dispatch and direct synchronous cancellation. The final coordination regression uses a real NSFilePresenter editor: its relinquish request proves B is already waiting inside Foundation before cancellation. It covers direct, raw and approved host dispatch, asserts completion before the presenter relinquishes, checks no later accessor, then runs a successful writer. Other regressions cover pre-registration cancellation, initially revoked grants, per-preparation checks, revocation while queued behind a mutation/coordinated editor, authorized nested creation, subsequent gate/coordinator reuse, stale concurrent writers and postcommit receipts. XCTest timeouts measure failure only; no timing sleeps establish ordering.

Validation ran through the normal focused coverage runner:

```sh
python3 scripts/test_groups.py --coverage --suite AskBoundedFileToolsTests --suite AskFileToolsTests --suite AskFileDispatchTests --suite AskLocalApprovalTests
# focused.log.gz: exit 0, 39 XCTest + 6 Swift Testing methods, 480.76 s total wall time

python3 scripts/test_groups.py --coverage --suite AskBoundedFileToolsTests --suite AskFileDispatchTests
# final-mutation.log.gz: exit 0, 34 XCTest methods, 93.14 s total wall time

python3 scripts/test_groups.py --coverage --filter 'AskFileDispatchTests/testCancelledCoordinationWaitJoinsBeforeEditorRelease'
# presenter-wait.log.gz: exit 0, 1 XCTest method with all 3 dispatch variants, 49.95 s total wall time
```

There are 45 distinct passing methods; total command wall time is **623.85 s**, including dependency preparation, discovery, compilation, startup and execution. The first invocation was a fresh build. No passing-result cache was used. Bounded-file tests retain the giant-line/combining/UTF-8/CRLF/legacy-offset/cursor/growth/target-race cases. Existing file-tool tests cover compatibility; approval tests cover the directly affected host caller. After the first pass, lint found a 101-line function body. Extracting the repeated preparation check fixed that error; the second command verifies the final production source and adds defensive test-holder release. The third command verifies the stronger presenter-based test. No tests failed. Final lint and focused syntax parsing exit 0; style and existing compiler warnings remain. Raw initial/final lint, formatting, parsing and all coverage-run output are included as gzip files.

Coverage is changed executable-line coverage, not project-wide coverage:

- Correction versus returned head: **117/118 (99.15%)**, `changed-coverage.json`.
- Entire PR versus accepted stage-4 base: **868/887 (97.86%)**, `full-changed-coverage.json`.

Each report includes exact source SHA-256 values and uncovered lines. `initial-unchanged.lcov.gz` excludes AskFileMutation because its source shifted during the lint fix; all eight included production sources remained unchanged. `final.lcov.gz` supplies the final production-source mapping after the 34-method run. `presenter.lcov.gz` supplies the final test's additional evidence; production source was unchanged. LCOV paths are repository-relative. Counts are unioned only for identical final production sources. No old evidence from the previous PR head is mixed into these reports.

The export commands, run after each corresponding scope, were:

```sh
xcrun llvm-profdata merge -sparse .build/arm64-apple-macosx/debug/codecov/*.profraw -o scope.profdata
xcrun llvm-cov export -format=lcov .build/arm64-apple-macosx/debug/TypefluxPackageTests.xctest/Contents/MacOS/TypefluxPackageTests --instr-profile=scope.profdata <production sources changed from the original PR base>
# For the first export, exclude Sources/Typeflux/Ask/AskFileMutation.swift.
# Normalize absolute source prefixes to repository-relative paths and gzip LCOV.
python3 docs/validation/gul-438/correction/changed_coverage.py
python3 docs/validation/gul-438/correction/changed_coverage.py --base 151b334206180a762a2cf1ce80d176d457aba31b --output full-changed-coverage.json
```

Final self-review checked the complete raw/approved/direct dispatch paths, cancellation before/during coordination, gate release on every throwing path, controller registration races, timer lifetime/drain, descriptor/staging cleanup, authority before each preparation boundary, target/version conflicts, postcommit success and documentation consistency. It found and fixed the lint length error and strengthened the coordination test to observe an actual presenter wait. No remaining incomplete path was identified. The existing limitation remains: an uncooperative same-user process can race the last check and rename. This is not universal filesystem compare-and-swap, and no unsafe rollback overwrites third-party changes. Owner acceptance and independent race review are still required.
