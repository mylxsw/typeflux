# GUL-455 C3 validation

Baseline: `307ae12f` (main after #693). This correction updates PR #694 from
`19ccc081`; the earlier 100-test run and its 32/32 coverage result are historical,
recorded in `validation-19ccc081.md`. Its raw LCOV and intersection remain in
`changed-files-19ccc081.lcov.gz` and `changed-coverage-19ccc081.txt`.

## Streaming snapshot contract

`AskLocalSnapshotStoring.forEachSnapshot` takes a synchronous, nonescaping,
non-Sendable consumer. The concrete store enumerates immediate JSON URLs and
reads one payload, invokes the consumer, then reads the next. It does not retain
consumed bytes or collect payloads. The engine decodes, marks recoverable default
bindings and inserts records inside that callback on its actor. Its loaded guard,
malformed-input skipping, unknown-binding handling and write/error ordering stay
unchanged. Array collection exists only in a test helper.

The concrete regression seeds four distinct JSON payloads. During the first
callback it identifies the current payload and deletes every other snapshot.
Exactly one callback must occur, regardless of enumeration order; an eager read
would consume the deleted payloads. The recording visitor also checks that a
reopened engine visits all seeded snapshots once, skips malformed JSON, preserves
unknown bindings and marks recovery in memory without writes or execution.

## Focused validation

The correction runs `make coverage` with `SUITE=AskStoragePortsTests` and these
five method filters (joined with `|`):

- `AskLocalEngineTests/testRecoveryCheckRemainsReadOnlyAfterRestartAndRetry`
- `AskLocalEngineTests/testConversationRunsOnDeviceWithToolsAndPersists`
- `AskLocalEngineTests/testLegacyReopenedTypedReceiptPreparesWithoutRepeatingTool`
- `AskLocalEngineTests/testTypedResultThroughLocalRunAndReopen`
- `AskBudgetTests/testJournalContractFailuresAndDurableThrowingStop`

The eight storage methods exercise the concrete visitor, injected send/receipt/
history/delete/keep/purge/summary paths, temporary exclusion, failed writes and
load-once recovery. The four existing engine cases cover restart and persisted
receipt behavior. The budget storage contract case refreshes coverage for the
shared identifier guard and its error branch in the complete C3 line map.
Unrelated suites from the earlier 100-test run were not repeated. No full suite,
real provider calls or CI wait is included.

The first command stopped during test-target compilation (exit 2, **527.133 s**
wall time; runner **524.66 s**), before any tests executed. `XCTAssertNoThrow`
inside the new consumer made Swift infer a throwing closure, incompatible with
the required nonthrowing visitor. Replaced that assertion with explicit
`do/catch`; the production visitor signature is unchanged. The exact same focused
command was retried. Raw first-use output: `coverage-correction.log.gz`.

The retry passed **13/13 XCTest methods**, exit 0, in **79.274 s** total
(**53.78 s** incremental build, **68.44 s** build/discovery, **7.49 s** execution
phase, **75.93 s** runner). This was an incremental rebuild, not a verified cache
hit. No test failures occurred. Both coverage attempts together took **606.407 s**.
Raw successful command/output: `coverage-correction-final.log.gz`. Correction
environment: `environment-correction.log.gz`.

Fresh LLVM export against the final production source map reports **36/36 changed
executable lines (100%)**, with no uncovered changed executable lines:

| File | Covered / executable |
| --- | --- |
| `AskStorageIdentifier.swift` | 4 / 4 |
| `AskBudgetJournaling.swift` | 0 / 0 (declarations only) |
| `AskBudgetStore.swift` | 3 / 3 |
| `AskLocalEngine+Budget.swift` | 1 / 1 |
| `AskLocalEngine.swift` | 8 / 8 |
| `AskLocalSnapshotStore.swift` | 20 / 20 |

The denominator is physical added/modified production lines with LLVM `DA`
records versus `307ae12f`; it excludes comments, declarations without executable
records, tests and deleted lines. This is neither whole-project nor branch
coverage. Raw export: `changed-files.lcov.gz`; exact export command, denominator
and uncovered lists: `changed-coverage.txt`. OS lock/open failures and power loss
remain outside these changed paths.

## Portable artifact recomputation

Run `python3 docs/validation/gul-455/changed_coverage.py` to recompute using only
committed source, Git diff and raw LCOV; no binary, profile, Xcode export or build
is needed. Use `--export` only after a fresh focused instrumented test run.

LCOV `SF` entries retain their original absolute checkout paths. The script maps
exactly one `Sources/Typeflux` suffix, rejects ambiguous/noncanonical paths and
checks the six known changed production files. All five implementation files
must contain changed executable `DA` records. The protocol-only file may have
no LCOV entry. `changed-executable-lines.json` records source hashes and exact
expected executable line numbers; artifact-only recomputation rejects stale
source or missing individual executable records rather than reporting an empty
or reduced denominator. Hit counts always come from raw LLVM output.

Four Python regressions cover foreign/relative source paths, ambiguity/traversal,
missing implementation files or executable records, and invalid/orphan `DA`
records. Raw command/results/timing: `python-regressions.log.gz`.

Verified in a separate detached checkout directory, populated with the final six
source files and committed-format coverage artifacts. Running the command above
without `--export` produced **36/36 (100%)**; `.build` was absent before and after.
Removing one expected snapshot-store `DA` record then failed with exit 1; restoring
LCOV and modifying a source hash also failed with exit 1. These intentional
negative cases changed only temporary verification copies. The raw original
artifacts remain untouched. The temporary checkout was removed afterward.
All three portability checks and checkout/cleanup took **5.116 s**; raw commands
and results: `artifact-portability.log.gz`.

## Self-review

Reviewed the visitor's full path from fixed-directory enumeration through
synchronous actor-isolated decode/insertion. No new task, await, callback escape,
Sendable conversion, lock or resource lifetime is introduced. Only URL names
remain collected; payload lifetime is scoped to each iteration. Write/delete ID
validation, protected atomic options and journal lock/error ordering are unchanged.
Tests cover missing/unreadable directories, malformed records, recovery, unknown
bindings, temporary snapshots and failure without publishing state. No new
filesystem fallback, credentials, migration or public settings were added.

Lint initially flagged the enlarged test class; the new concrete regression was
moved to a same-file extension before compilation. The concrete store passes
strict lint. Engine and test lint findings match `19ccc081` exactly (68 and 7
respectively), with no increased rule counts; see `lint-correction.json`.
`git diff --check` passes. Shared host authority and full Agent replaceability
remain outside this increment; GUL-456 is unchanged.
