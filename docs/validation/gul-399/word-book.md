# GUL-399 stage 2b: supervised word-book storage

This increment depends on #512 (`69ce9fab`), which depends on #511. It completes the word-book adapter and caller migration, not the entire approved stability plan.

## Behavior and boundaries

- `AskWordBookStoring` now has an asynchronous, throwing contract. `RecoveringAskWordBookStore` uses the existing typed supervisor for lazy construction/readiness, bounded admission and deadlines, generation fencing, backoff, disable and shutdown. The DI container owns a replaceable factory; the launcher, translation panel and word-book window share its stable facade. App shutdown fences new work synchronously.
- SQLite opens, reads, mutations and decoding execute behind that facade in production. Failed initialization closes its connection. Reads report unavailable/corrupt storage instead of returning empty history. Corrupt rows/cards and counter overflow fail explicitly. Diagnostics exclude SQL, paths and user content.
- Each mutation is one transaction. A failed lookup increment, batch delete or restore rolls back; failed writes do not emit change notifications. Recovery reopens the same database; it never deletes/recreates the file or replays an operation. A timed-out mutation may already have committed. Replacement waits for that outstanding operation to return; no automatic write retry is permitted without durable mutation/result identity.
- The recorder marks a lookup recorded only after confirmed persistence, rejects overlapping mutations and fences session accounting across awaits. Launcher recording and starring execute sequentially within one admitted task. Confirmed stars survive older streaming snapshots in both launcher and panel.
- The word-book window loads complete snapshots asynchronously and rejects superseded reloads. Read failures retain the prior list/counts. Failed saves retain new/regenerated cards; failed undo retains its restore data. Success messages and star state follow confirmed persistence. Window presentation, reload and retention tasks are owned/cancelled. Localization covers the five existing languages.

The supervisor bounds asynchronous callers, not arbitrary native execution. SQLite and JSON decoding still run in the host process; this is not protection against native crashes, process-wide memory exhaustion or cooperative-executor starvation. Application termination may end the event loop before asynchronous cleanup finishes; the synchronous admission fence still prevents new work. This increment does not add a persisted health store, dependency-graph registry or recovery UI.

## Focused validation

Self-review preceded test execution. Test targets were built directly with LLVM instrumentation, and the binary was checked for `__llvm_covmap` and `__llvm_prf_cnts`. No test-discovery rebuild occurred between build and execution. Commands used the sanitized environment from `scripts/test_runtime.py::child_environment`.

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
otool -l .build/arm64-apple-macosx/debug/TypefluxPackageTests.xctest/Contents/MacOS/TypefluxPackageTests
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '<explicit scope below>'
```

The initial scope included these suites:

- `RecoveringAskWordBookStoreTests`, `WordBookStorageFailureTests`, `WordBookUnknownOutcomeTests`: real invalid paths, locked databases, trigger-aborted transactions, corrupt data, reopen, circuit/admission boundaries, committed-but-timed-out writes, no replay, session accounting.
- `WordBookCallerFailureTests`: truthful launcher/panel/history errors and retained translation results.
- `AskWordBookStoreTests`, `AskWordBookRecorderTests`, `AskWordBookViewModelTests`, `AskWordBookWindowTests`: storage/query behavior, counts, drafts/results, undo, export, retention, async snapshot and window lifecycle migration.
- `AskTranslateWordBookTests`, `AskTranslateRecentWordsTests`, `AskWordBookDictTests`, `AskWordBookOpenTests`, `AskPluginSessionWordBookTests`, `AskWordCardTranslationTests`, `AskTranslationRoutingTests`: translation/cache/history and session callers.
- `AskTranslationPanelModelTests`, `AskConversationWindowServicesTests`: panel persistence and production workspace service wiring.
- `ModuleSupervisorTests`: shared deadlines, task bounds, cleanup, generations and shutdown.
- Only these `AskQuickResultsInteractionTests` methods: `commandSStarsTheWordAndUsingTheResultKeepsIt`, `dictWithAWordOpensTheWordBookOnReturn`, `translationStackRegeneratesOnlyTheCardStarsAndCopiesIt`, `translationStackCanStarACardWhileOtherServicesAreRunning`, `translationStackCopiesCompletedCardBeforeOtherServicesFinish`, `commandBOnATranslationOpensTheWordBookOnItsWord`, `theKeywordAloneListsRecentWordsAndCommandBOpensTheWordBook`. Unrelated launcher and full-suite tests were not executed.

The first pass ran 113 methods: 108 passed; five failed (eight assertions). Three launcher tests exposed record/star task competition and stale streaming star state, which were fixed in production. Two fault tests compared `Date()` values across SQLite's epoch conversion; fixed integral fixture timestamps preserve meaningful whole-record equality. The retry covers those failures, the newly added panel streaming regression, and directly affected session/panel caller suites. Passing unrelated scopes were not repeated.

Final result: **114 distinct methods passed** across the initial pass and focused retries. The first retry passed 20 methods in six suites; the eight other methods whose timestamp fixtures changed were then rerun and passed. No full suite was run.

Changed executable-line coverage: **428/451 (94.90%)**, relative to `69ce9fab`; per-file counts and uncovered lines are in `word-book-coverage.json`. This is changed-line coverage, not repository-wide coverage. Uncovered integration lines include the live DI default factory and application-termination hook; shutdown/admission itself is exercised through injected handles.

Coverage is attributed to matching source versions: the three files changed after the first pass (`AskConversationModel+Plugins.swift`, `AskPluginSession.swift`, `AskTranslationPanelModel.swift`) use only the final retry profile. Unchanged production files use this run's initial profile. A trial merge of pre/post-fix profiles reported Swift function-counter mismatches and was discarded; its numbers are not reported. LLVM identifies many Swift functions with hash zero, so blindly merging differing counter layouts can silently omit executable lines. The JSON records the selected profile for every file.

Command wall times (including runner preparation, not just test-body time):

| Command | Wall time | Outcome |
| --- | ---: | --- |
| Initial direct instrumented build | 207.74 s | Stopped after compile diagnostics |
| Test-call migration build | 341.62 s | Compile errors; no tests executed |
| Preflight build stopped for fixture correction | 16.80 s | Cancelled; no tests executed |
| Incremental build | 53.70 s | Two test argument errors |
| Corrected build | 34.17 s | Passed |
| Final pre-test build | 31.10 s | Passed; instrumentation verified |
| Initial focused coverage execution | 18.53 s | 113 methods; five failures |
| Post-fix instrumented build | 63.64 s | Passed; instrumentation verified |
| Failed cases and affected caller retry | 15.15 s | 20 methods passed |
| Remaining changed timestamp fixtures | 3.56 s | Eight methods passed |

No cached passing result from #511 or #512 was used. The final tests used the prebuilt instrumented binary; external CI was not awaited.

## Remaining approved work

Notebook storage remains synchronous and still collapses read failures into empty/nil. Its compare-and-replace save already retains drafts on failure, but a failed baseline read is reported as a conflict. The next increment must migrate that contract and callers together, preserve drafts/revisions/approval receipts, and add supervised reopen without replaying note writes or Agent actions. Do not delete or recreate user databases.

Further stage 2 work includes the remaining module factories/lifecycle wiring and health persistence/observation. Later required stages remain native-system-call and local-model process isolation, followed by audio/TCC/signing/performance verification before audio isolation. The overall issue remains `in_progress`.

## Reproduction filters

Use this explicit initial/final scope with the `--filter` argument above (the final tree includes the new panel regression, so it selects 114 distinct methods):

```text
^Typeflux(?:Focused)?Tests[./](?:(?:RecoveringAskWordBookStoreTests|WordBookStorageFailureTests|WordBookUnknownOutcomeTests|WordBookCallerFailureTests|AskWordBookStoreTests|AskWordBookRecorderTests|AskWordBookViewModelTests|AskWordBookWindowTests|AskTranslateWordBookTests|AskTranslateRecentWordsTests|AskWordBookDictTests|AskWordBookOpenTests|AskPluginSessionWordBookTests|AskWordCardTranslationTests|AskTranslationRoutingTests|AskTranslationPanelModelTests|AskConversationWindowServicesTests|ModuleSupervisorTests)[./]|AskQuickResultsInteractionTests[./](?:commandSStarsTheWordAndUsingTheResultKeepsIt|dictWithAWordOpensTheWordBookOnReturn|translationStackRegeneratesOnlyTheCardStarsAndCopiesIt|translationStackCanStarACardWhileOtherServicesAreRunning|translationStackCopiesCompletedCardBeforeOtherServicesFinish|commandBOnATranslationOpensTheWordBookOnItsWord|theKeywordAloneListsRecentWordsAndCommandBOpensTheWordBook))
```

The first retry selected `WordBookCallerFailureTests`, `AskTranslationPanelModelTests`, `AskPluginSessionWordBookTests`, the three failing launcher star methods, `RecoveringAskWordBookStoreTests.failedMutationIsNotReplayedWhenTheConnectionRecovers`, and `WordBookStorageFailureTests.lockedWritesDoNotNotifyOrChangeCounts`. The second selected the remaining methods in those two storage suites plus `WordBookUnknownOutcomeTests`.
