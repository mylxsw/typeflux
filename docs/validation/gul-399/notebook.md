# GUL-399: supervised notebook storage (stage 2c)

This increment is stacked on PR #514 (`agent/arch-gpt-astra/gul-399-wordbook`,
`7e2e6b80`), which depends on #512 and #511. It completes the notebook storage and
caller migration within stage 2. The overall four-stage stability plan is still
in progress.

## Delivered behavior

- `AskNoteStoring` is asynchronous and throwing. `nil` means a successful lookup
  found no note; empty collections mean a successful query found no rows.
  Connection, locking and malformed-data failures are explicit, redacted errors.
- `RecoveringAskNoteStore` forwards each operation once through the existing
  typed supervisor. A count probe establishes readiness; connection replacement,
  admission, deadlines, generations, recovery budgets and shutdown fencing use
  the supervisor from #512. Invalid row data requires explicit recovery.
- `DIContainer` owns a replaceable notebook factory shared by the launcher,
  notebook, Agent tools and result windows. `AppCoordinator` stops admission and
  shuts down this facade. Default SQLite construction and access run in the
  supervisor's detached work rather than on the UI actor.
- SQLite keeps its existing schema and transactional compare-and-replace/revision
  behavior. A false conditional save denotes a snapshot mismatch. Failed writes
  throw and roll back; only committed changes notify observers. Failed initialization
  closes its connection. The default SQLite busy timeout is 250 ms, independently
  injectable for fault tests. No user database is deleted or recreated.
- Notebook reloads publish a complete successful snapshot and fence superseded
  reads. Failures preserve the previous list, selection, drafts and undo state.
  A failed baseline read reports unavailable storage, not a fabricated conflict.
  A save records the submitted body/title; newer edits remain pending. Confirmed
  title changes update the local snapshot before clearing pending state.
- Window close uses the asynchronous save barrier. Direct close retains dirty
  drafts for reopening. UI gestures have one owned admission slot; repeated
  gestures are not queued for later replay. Closing cancels pending window work.
- Launcher and result-window badges change only after confirmed persistence.
  Failed reads do not clear confirmed stars or create a replacement note from an
  unverified answer mapping. Opening a notebook result dismisses the launcher
  only after a successful read; a changed launcher generation rejects late results.
- Agent notebook calls retain approval fingerprints and transactional snapshot
  checks, and recheck the live privacy policy after storage suspensions. Existing
  execution claims, receipts and unknown-execution handling are unchanged.

Recovery never repeats note creation, replacement, trash, deletion, revision
changes, toggles or Agent operations. A timed-out write can already have committed:
the tests explicitly release a blocked write after timeout, reopen, read its
result, and verify that the mutation ran once. Future write retry requires stable
mutation/result identity; this change adds no retry mechanism.

## Validation and scope

**118 distinct focused test methods were validated across the initial pass and
targeted corrections. The final functional correction pass ran 49 methods, all passing;
a subsequent test-fixture cleanup check passed all 5 entry regression methods. Changed executable
line coverage is 930/991 (93.84%).** This is changed-code coverage, not project-wide
coverage. See `notebook-coverage.json` for file counts and uncovered lines.

The scope maps to the changes as follows:

| Scope | Behavior covered |
| --- | --- |
| `RecoveringAskNoteStoreTests` | Failed open/reopen, disable/shutdown, every facade operation, SQLite locks/corruption, CAS/revisions, retained uncertain write and no replay |
| `NotebookCallerFailureTests` | Preserved snapshots/drafts/undo on failure, body/title edits during blocked saves, unavailable tool/plugin results, privacy revocation, late result-window save after close |
| `AskNotesStoreTests`, `AskNotebookStoreTests` | Existing schema migration, query/metadata round trips, transactional revisions and conflicts, explicit storage errors |
| `AskNotebookViewModelTests`, `AskNotesViewModelTests` | Autosave, editing/navigation barriers, categories, title/body conflicts, undo, import/export callers and window lifecycle |
| `AskNotebookToolTests`, `AskNotebookAuthorizationTests`, `AskNotebookEntryTests`, `AskNotebookEntryRegressionTests` | Agent consent/privacy and concurrent edits; conversation/launcher note identity and answer mappings |
| `AskNotesPluginTests`, `AskPromptResultFlowTests`, `AskResultDocumentTests` | Search versus unavailable storage, save/unsave, streaming completion, result-window handoff and badges |
| `AskNotesRenderTests`, `AskNotebookVisualTests` | Directly affected notebook/result UI, both styles, narrow layouts and native controls |
| `AskConversationWindowServicesTests`, `ModuleSupervisorTests` | Shared production service wiring and supervisor invariants |
| Two `AskQuickResultsInteractionTests` methods and one `AskScreenshotTextOrganizationTests` method | Native launcher save/open paths and screenshot-to-notebook caller |

The two launcher methods were
`anAIPromptIsSavedWhileStreamingThenMovesToAWindow` and
`theNoteKeywordListsAndOpensNotes`. The screenshot method was
`launcherActionOrganizesRestoresRetriesAndRecaptureResetsAI`.
Other snapshot fixture files were migrated to compile against the new interface;
their unrelated snapshot suites were not executed.

### Commands and measured wall time

All commands used `scripts/test_runtime.py::child_environment()` to sanitize the
Swift child environment. No full test suite, test-discovery rebuild, external CI
wait or PR merge was performed.

```sh
/usr/bin/swift build --build-system native --build-tests --enable-code-coverage --jobs 4
otool -l .build/arm64-apple-macosx/debug/TypefluxPackageTests.xctest/Contents/MacOS/TypefluxPackageTests
/usr/bin/swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter "$SCOPE"
```

Both `__llvm_covmap` and `__llvm_prf_cnts` were verified before each test pass.
To reproduce the sanitized launch, call `subprocess.run(command, cwd=repository,
env=test_runtime.child_environment())` from Python with `scripts` on `sys.path`.
The explicit scopes were:

```text
INITIAL:
^Typeflux(?:Focused)?Tests[./](?:(?:RecoveringAskNoteStoreTests|NotebookCallerFailureTests|AskNotesStoreTests|AskNotebookStoreTests|AskNotebookViewModelTests|AskNotesViewModelTests|AskNotebookToolTests|AskNotebookAuthorizationTests|AskNotebookEntryTests|AskNotebookEntryRegressionTests|AskNotesPluginTests|AskPromptResultFlowTests|AskResultDocumentTests|AskNotesRenderTests|AskNotebookVisualTests|AskConversationWindowServicesTests|ModuleSupervisorTests)[./]|AskQuickResultsInteractionTests[./](?:anAIPromptIsSavedWhileStreamingThenMovesToAWindow|theNoteKeywordListsAndOpensNotes)|AskScreenshotTextOrganizationTests[./]launcherActionOrganizesRestoresRetriesAndRecaptureResetsAI)

RETRY 1:
^Typeflux(?:Focused)?Tests[./](?:(?:AskNotebookViewModelTests|AskNotesViewModelTests|NotebookCallerFailureTests|AskNotesPluginTests)[./]|AskNotebookEntryRegressionTests[./]savedAnswersAreFoundBeyondTheFirstPageAndOtherConversations|AskPromptResultFlowTests[./](?:theModelSavesRemovesAndOpensNotes|commandOMovesAStreamingResultIntoAWindow)|AskQuickResultsInteractionTests[./]anAIPromptIsSavedWhileStreamingThenMovesToAWindow)

FINAL RETRY:
^Typeflux(?:Focused)?Tests[./](?:(?:AskNotebookViewModelTests|AskNotesViewModelTests|NotebookCallerFailureTests|AskPromptResultFlowTests|AskNotebookEntryRegressionTests|AskNotebookEntryTests)[./]|AskQuickResultsInteractionTests[./](?:anAIPromptIsSavedWhileStreamingThenMovesToAWindow|theNoteKeywordListsAndOpensNotes))
```

| Command phase | Total wall time | Result |
| --- | ---: | --- |
| Nine preparation builds | 709.13 s | Compile-only migration corrections; three stopped after known compiler failures; no tests executed |
| First completed instrumented build | 28.09 s | Passed |
| Initial focused execution | 66.38 s | 118 methods; 8 failed with 13 assertions/issues |
| First correction build | 102.25 s | Passed |
| First focused retry | 23.36 s | 40 methods; 2 failed |
| Final correction build | 53.48 s | Passed |
| Final focused retry | 17.75 s | 49 methods passed |
| Test-fixture cleanup build | 73.02 s | Passed; removed redundant `await` in two fixtures, no production changes |
| Test-fixture cleanup check | 7.88 s | 5 entry regression methods passed |

Measured build-command time totals 965.97 s; execution-command time totals 115.37 s.
The cleanup check used `^Typeflux(?:Focused)?Tests[./]AskNotebookEntryRegressionTests[./]`.
Execution timings include
preparation/runner startup, not only test-body durations.

The first pass exposed an overly strict save-in-flight barrier after a successful
commit and a missing empty-category fallback. Several fixtures still observed
asynchronous admission synchronously, or expected an unavailable store to look
empty. The first retry then exposed a stale local title snapshot after autosave
and an eager launcher dismissal before checking whether a note existed. The
final corrections retain the latest committed title locally and defer dismissal
until the asynchronous open succeeds. The final scope covers these changes and
their directly affected callers; already-passing unrelated suites were not rerun.

### Coverage attribution

Coverage uses executable added lines from `git diff --unified=0 7e2e6b80 -- Sources`
and `xcrun llvm-cov show --instr-profile=... --use-color=false` line counters.
Raw profiles from each pass were collected before the next test invocation and
merged only within that pass using `xcrun llvm-profdata merge -sparse`.

Swift 6.4 can emit zero function hashes, so profiles from different counter
layouts must not be blindly merged. The report uses the final retry profile for
the four production files edited after the initial execution:
`AskNotesViewModel.swift`, `AskComposerViews.swift`,
`AskConversationModel+Notes.swift`, and `AskConversationModel+Plugins.swift`.
It uses this run's initial profile only for unchanged production files. The
intermediate retry profile is not included in the coverage calculation. No
previous increment's test result or profile was reused.

Uncovered lines are listed explicitly. In particular, the new DI construction and
`AppCoordinator` shutdown lines were reviewed but not executed in these tests;
facade lifecycle tests exercise their underlying admission/shutdown behavior.
Some individual native UI gesture closures remain uncovered despite the scoped
rendering and interaction tests. The aggregate 93.84% exceeds the 90% changed-code
target; it is not a claim that every application path was exercised.

## Remaining approved work

The three supervised stores are concrete production fault domains. A dependency
registry, persisted `ModuleHealthStore`, complete health observation/recovery UI,
and other module factories/lifecycle adapters still need stage 2 integration.

SQLite, JSON parsing, file import/export and the UI remain in the host process.
Bounded async callers and connection recovery do not contain native crashes,
process-wide memory exhaustion or executor starvation. Native system-call,
media/local-model worker isolation, followed by audio/TCC/signing/performance
validation before audio isolation, remain required later stages. This notebook
increment is not acceptance of the whole stability issue.
