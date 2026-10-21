# GUL-455 C3 validation

Baseline: main at `307ae12f` (PR #693 merged). Environment details are in
`environment.log.gz`.

The local engine retains one opaque snapshot store and one host budget journal,
selected at construction from the existing directory or supplied by composition.
The engine still owns record encoding/decoding, recovery, revisions and memory.
The journal retains its synchronous callback, file lock, mutation validation and
protected atomic write, including persistence after a valid callback throws.
No Go wrapper, schema, dispatch, shared-state authority or UI setting was added.
This does not establish full Agent replaceability; that scope remains separate.

## Focused checks

Coverage replaces a plain test pass. The normal repository coverage runner built
and discovered the SwiftPM test target, then selected only the listed methods.
No full test/UI execution, provider request or CI wait was performed. Command
wall times include dependency preparation, build, discovery, startup, execution
and report generation.

- First command: `make coverage SUITE='AskStoragePortsTests AskBudgetTests AskLocalEngineTests AskLocalBudgetTests AskLocalEngineReentrancyTests AskLocalLateUsageTests AskLocalUsageTests AskLocalEngineTemporaryTests AskMemoryTests AskAgentBindingTests AskAgentRegistryTests'`.
  Exit 2, **500.563 s** total; first-use build **466.55 s**, runner **495.60 s**.
  Build succeeded, but discovery rejected the nonexistent `AskAgentRegistryTests`
  suite before any tests executed. The composition checks actually live in
  `AskApplicationAPITests`; the corrected command selects its three relevant
  factory/routing methods. Raw output: `coverage-run.log.gz`.

- Corrected command: `make coverage SUITE='AskStoragePortsTests AskBudgetTests AskLocalEngineTests AskLocalBudgetTests AskLocalEngineReentrancyTests AskLocalLateUsageTests AskLocalUsageTests AskLocalEngineTemporaryTests AskMemoryTests AskAgentBindingTests AskSemanticCompactionTests' FILTER='AskApplicationAPITests/(productionConversationFactoryBuildsConfiguredDefaultEngine|productionCallerFactoriesRetainLocalStateAndCloudRoute|routedDefaultSharesLocalEngineStateAndHostAccess)'`.
  Exit 0; **100 selected methods passed** (62 XCTest, 38 Swift Testing), no test
  failure or test retry. **102.803 s** total; incremental build **72.22 s**,
  build/discovery **86.39 s**, execution phase **11.36 s**, runner **97.78 s**.
  This was an incremental rebuild, not a verified cache hit. Raw command,
  test names, results and coverage output: `coverage-final.log.gz`.
  Combined wall time for both coverage commands: **603.366 s**.

The selected scope maps to the changed behavior:

- `AskStoragePortsTests`: seven focused methods cover real snapshot reopen,
  malformed JSON, an unreadable `.json` directory without chmod assumptions,
  missing/non-directory paths, immediate JSON enumeration, layout, identifier
  boundaries, and deletion of only the validated target. Recording stores cover
  send, inference receipt, history, memory purge, canonical deletion, swallowed
  removal errors, late temporary usage, keep once, summary completion, write
  failure without publication, load-once recovery and unknown-binding reads.
  Both stores are injected with budgets enabled; no configured-directory
  fallback is permitted. Temporary snapshots stay in memory while temporary
  budget journals keep their existing policy.
- `AskBudgetTests`: journal invalid root/conversation, missing/corrupt/invalid
  stored state, valid stopped state surviving callback failure, invalid
  postmutation rejection without write, repeated settlement idempotency and
  concurrent updates through separately constructed store instances.
- Existing local engine/budget/usage/late-usage/reentrancy, semantic compaction,
  local temporary engine, memory and binding suites exercise their shared paths.
  Three production factory/routing methods verify default composition.

## Changed executable coverage

**32/32 unique added/modified executable production lines (100%)** relative to
`307ae12f`, exceeding the 90% target. No uncovered changed executable lines.

| File | Covered / executable |
| --- | --- |
| `AskStorageIdentifier.swift` | 4 / 4 |
| `AskBudgetJournaling.swift` | 0 / 0 (declarations only) |
| `AskBudgetStore.swift` | 3 / 3 |
| `AskLocalEngine+Budget.swift` | 1 / 1 |
| `AskLocalEngine.swift` | 8 / 8 |
| `AskLocalSnapshotStore.swift` | 16 / 16 |

This counts changed physical lines having LLVM LCOV `DA` entries, not whole-file,
whole-project or branch coverage. Protocol declarations, synthesized accessors
without `DA` records, comments, blank lines, deleted implementations and tests
are excluded. The focused run does not fault-inject OS open/flock failures or
power loss; those unchanged journal/platform behaviors are outside this changed
line denominator. Atomic/protection options were verified unchanged in source.

The raw selected-file LCOV is `changed-files.lcov.gz`; the export command and
per-file denominator are in `changed-coverage.txt`. Recompute the intersection
from the committed artifact with `python3 docs/validation/gul-455/changed_coverage.py`.
Pass `--export` after the focused instrumented run to refresh the raw artifact.

## Review

Reviewed the full storage call graph: all snapshot reads/writes/deletes and
budget journal updates use the retained instances. `persist` still encodes and
writes before publishing records and clears prepared images afterward; save
ordering, cancellation, temporary handling, late usage and summary ownership
remain in orchestration. No new await, task, lock or resource lifetime exists.
The journal lock scope and error ordering are unchanged. Identifier checks occur
before file operations; snapshots remain opaque at the protocol boundary.
No credentials, public UI changes, migration or unrelated refactor was added.

Strict lint on all affected production files initially found an introduced long
identifier guard, which was wrapped. The remaining engine lint findings also
exist in the baseline: stdin JSON comparison shows 71 baseline findings versus
68 current findings, with no increased rule counts. New interfaces/stores and
the budget sources have zero findings. The whole affected-engine strict lint
check therefore remains non-green due to existing complexity/length/naming and
style findings; no broad cleanup was attempted. Raw initial output and the
baseline/current comparison are retained. `git diff --check` passes.
