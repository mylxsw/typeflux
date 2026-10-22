# Final integration evidence

The new tests join the existing host implementation at its public request boundary. Only external completions and transports are synthetic. The queue journey uses `AskConversationModel`, `AskApplicationAPI.routed`, `AskLocalEngine`, SQLite execution receipts and `AskLocalTools` with a temporary file. No provider, personal files, native permissions or alternate production adapter are activated.

Base: Swift `5e31755bf9801d3ca3270180773bad3ffd37d0a1` (#706). API base: `fd445dcbb587acc7ec187db58f02eda102c45499` (#161). Neither checkout had intervening main changes. Earlier Chat rename/icon changes are retained. Exact commands and total elapsed times are in `swift.json` and the API evidence records. Failed attempts remain in the evidence archive.

## Requirement to executable evidence

Test names below are exact method names; Swift Testing argument variants are recorded in the raw output. Rows combine new journeys with existing detailed regressions rather than copying engines or journals into another harness.

| Requirement | Entry and assertions |
| --- | --- |
| Application, pinned alternate, trusted tool, reopen | `AskAgentTurnTests.testFakeThroughApplicationModelReceiptApprovalToolAndReload`: changed new-run default, original alternate retained, one plan mutation, duplicate inference inert, private state omitted. `testDefaultApprovalReopenKeepsOriginalBindingAndNewRunUsesAlternate`: production default retained after reopen, approval receipt once, next run selects the test alternate. API `TestPostgresFinalPinnedPromptApprovalJourney/default,alternate` repeats both paths through independent SQL connections, original budget attribution and duplicate-budget revision stability. HTTP `TestAskAgentTurnHTTPHostAndPeerAdmission` supplies authenticated peer rejection before effects. |
| Legacy/unknown/malformed binding | `AskAgentBindingTests.testSharedFixturesRemainReadableAndFailClosed`, `testNewRunIdentityLegacyReadAndReplacementRuns`, `testUnsupportedCommandsLeaveSnapshotAndUsageIntact`; API `TestAgentBindingSharedFixtures`, `TestAgentBindingNewRunsAndLegacyRead`, `TestAgentBindingUnsupportedCommandsAreReadOnly`. Exact JSON/readability, no state mutation, no model/tool effects. |
| Prompt compatibility and interrupted continuation | `AskPromptSectionsTests.testSharedScenariosAndFullPayloadSnapshots` and `AskPromptBuilderTests` capture actual constructed requests, effective tools, memory/history/summary/provider fields. `testPolicySwapPreservesPersistedPendingInference` now completes replay and compares the next request's trusted prefix with fresh modular construction. API final pinned journey changes builder at restart, checks byte-equivalent replay projection, then verifies modular prefix on the genuinely new inference. `TestModularPromptScenarios`, `TestPostgresPromptPortDurableRequests` retain full payload/worker checks. |
| Queue, engine, file authority | `AskFinalIntegrationTests.queueEngineAndFolderAuthority(action:)` holds external completions, queues a folder-scoped follow-up, verifies one durable user-message acknowledgement and distinct run, then reads the sentinel via real tools or revokes/stops/resets/removes it. No late sentinel output, no restored grants, no queue duplication. Independent usage-only/optimistic clocks and explicit paused recovery are in `AskQueueOwnershipTests.independentClocksCannotConfirmHeldQueuedSend`, `steerErrorRetainsExactIntentAndNeverFallsBackToReplacementRun`, `accountChangeBeforeQueuedResponseCannotRestoreOrAdvanceOldIntent`; `AskFolderAuthorityTests.testTaskIsolationAndPendingCannotExecute` checks account/device/conversation/task isolation. |
| Actual file host | `AskAgentToolsTests.testActualFileHostContinuationConflictAndRevocation`: giant UTF-8 line traverses multiple production-dispatch pages to EOF; another writer changes the version; edit rejected and bytes unchanged; revoked root cannot be read. `AskBoundedFileToolsTests` retain exact byte reconstruction, stale cursors and descriptor races. |
| Approved command and jobs | `AskAgentToolsTests.testApprovedHostCommandClippingRetainsExitAndFinalSideEffect`: actual approved dispatch drains 90 KB, retains exit 0/7 and clipping notice; a final marker proves execution reached the end. `AskCommandJobTests.testRealExcessOutputDrainsBothStreamsAndPreservesExitAndMarker`, `testPersistenceRestartInterruptedPrivacyCorruptionAndDiskFailure`, `testLocalCancellationAndAccountDeviceChangesPreservePersistentFences`; `AskCommandJobLifecycleTests` join model cancellation, logout, persisted invocation dedup and replacement ownership. |
| Bounded waves and serial admission | `AskBuiltinWaveTests.testReadWavesCrossASeparateSerialPlanAdmission`: 3/1/3/1 admission, peak 3, ordered results, independent serial barrier. Existing stock-host offline transport test verifies actual built-in classification and budget accounting. API `TestCloudWaveSevenStockHTTPReadsAreBoundedAndOrdered` now includes a real plan barrier. `TestPostgresFinalWorkerReadWavesAcrossSerialBarrier` submits through `Engine.Send`, advances `Worker.RunOnce`, proves overlap/peak/order, separate plan checkpoint and seven original read settlements. |
| Late settlement and SQL ownership | `AskBuiltinWaveTests` cancellation/replacement/deletion/purge/missing-original-journal methods; API `TestPostgresCloudWaveLateOwnershipAndPurge` (including exact `prefix_conflict`), `TestCloudWaveDirectDeletionSettlesWithoutPublishing`, `TestPostgresCloudWaveDeletionBeforeInvocationSettlesCapturedStart`. `TestBudgetTombstoneSettlementParity` exercises old-writer rejection and account erasure cascade. `TestPostgresBudgetTombstoneConcurrentIdentityReuse` checks both isolation levels; the exact `TestOwnerTombstoneMissingStateCannotPoisonAccounting` and missing-usage owner regressions are also rerun. SQL coverage is behavioral evidence. |
| Browser, notes and MCP decisions | `AskBrowserBackNavigationTests.testBackRejectsSourceDisabledWhilePaused`, `testBackRejectsDestinationDisabledWhilePaused`, `testBackNavigatesBetweenUnchangedAllowedOrigins` use isolated HTTP origins and actual WebKit history. `AskEmbeddedBrowserToolTests.testGenericMutationsRequireFreshConsentEvenWithActPolicy` and `AskPermissionModeTests` retain mutation consent independent of YOLO. `AskNotebookToolTests` use isolated notes; `AskMCPToolsTests` and `AskTypedContentIntegrationTests` preserve errors, unavailable tools and media projection. State/device/MCP serial barriers are checked by wave tests, not inferred from their names. |

## User decisions

Inspected `AskApprovalViews`, `AskAttachViews`, `AskQueueViews`, `AskRecoveryPresentation`, `AskRecoveryViews`, `AskDesign`, host-command reporting and command-job presentation. No visual behavior or production copy is changed, so no new snapshot is required. `localization-audit.json` records the exact five localized resources, selected keys and placeholder compatibility; this is a resource audit, not a native-speaker translation review.

| Situation | Visible explanation | Action | Consequence |
| --- | --- | --- | --- |
| Tool approval | Action/object, reason and exact command/diff; command-job lifetime | Allow exact action / deny; reusable option only when supported | One bound invocation; mutation consent cannot be borrowed |
| Folder expired or revoked | “Previous folder access has expired. Attach the folder again…”; Settings authority is separately explained | Attach again / revoke attachment | Fresh scope required; attachment revocation does not revoke Settings access |
| Site revoked | “You turned off the AI on [exact origin]. Change it in Sites & Sign-ins.” | Sites & Sign-ins | Source and Back destination both rechecked before navigation |
| Edit conflict | File changed; read first and supply current version | Read again and approve current change | Existing file is untouched by the stale edit |
| Clipped output | Exit code plus “[output truncated; only part of the output is shown]” | Inspect output/current files | Known exit remains known; clipping alone does not imply unknown execution |
| Running command job | Command and run-bounded lifetime; “Check command status”, “Read command output”, “Stop command” | Status / logs / stop | Stop requests cleanup; it does not undo prior changes |
| Stopped or interrupted command | Local stop and interrupted evidence remain distinct from known process exit | Check current state / inspect logs | Restart cannot automatically spawn the same invocation |
| Failed / unknown outcome | “We couldn't confirm the result”; read-only check and stop explanations | Check / refresh saved progress / self-check / stop, as supported | No automatic mutation replay; terminal failure has its own status |
| Queue paused, unconfirmed supplement | “Queue paused…” / “Could not confirm the supplement…” | Continue queued questions / remove / clear | Explicit reconciliation preserves FIFO; no steer-error fallback resend |
| Unsupported runtime | “This version cannot continue this task. Update the app or service…” | Update then try again | Readable history remains available; unsupported run cannot execute |

Selected approval, recovery, queue, command-copy and unsupported-runtime presentation tests accompany this audit. Normal copy does not expose private adapter state, raw ledger/lease identifiers or diagnostic dumps. The command-job handle remains a tool protocol identifier, separate from its user-facing title.

## Deployment and rollback

Apply server migration 80 before new settlement behavior. Do not roll back by dropping retained settlement tombstones: late original receipts must remain accountable. Account erasure continues to cascade. The existing adapter remains the production default; alternates here require the isolated test cohort and peer contract. Prompt rollback to immutable legacyV1 changes new construction only; persisted inference keeps its original request. Tool discovery, auto-connect and native permission behavior are unchanged.

Real-provider quality, provider latency/performance and live MCP compatibility are unverified. Deterministic doubles do not establish a quality improvement. macOS file mutations cannot make an uncooperative external writer obey advisory coordination; descriptor/version checks bound the supported race model. No deployment, alternate activation, self-merge or parent production-readiness decision is part of this change.

## Prior-stage evidence

These figures are historical denominators, not recalculated from this test-only increment. Stage contracts before the numbered feature sequence remain covered by the registry/prompt/model/storage production-port tests referenced above and their own accepted reports.

| Stage | Existing coverage/evidence |
| --- | --- |
| Stage 1 / GUL-434 facade | `AskApplicationAPITests` forwarding, routing, cancellation and production caller factories, rerun here |
| Stage 2 / GUL-435 Go boundary | `TestAskAgentTurnHTTPHostAndPeerAdmission` exercises real handler interfaces and authenticated host dispatch; original boundary acceptance remains in the accepted PR |
| Stage 3 / GUL-450 run binding | `docs/validation/gul-450/validation.md`: 130/137 (94.89%), correction 32/32; binding fixtures/read-only rejection rerun here |
| Stage 3 / GUL-453 prompt host | `docs/validation/gul-453/validation.md`: 120/121 (99.17%); production request and worker prompt paths rerun here; parent acceptance is complete; Swift #692 and API #155 are merged, independent of the stale issue status |
| Stage 3 / GUL-454 built-in host | `docs/validation/gul-454/changed-coverage.json`: 68/68; stock-host and wave suites rerun here |
| Stage 3 / GUL-455 storage ports | `docs/validation/gul-455/changed-coverage.txt`: 36/36; actual snapshot/budget stores used by reopened local journeys |
| Stage 3 / GUL-456 model host | `docs/validation/gul-456/changed-coverage.txt`: 16/16; held completion uses production model-client injection |
| Stage 3 / GUL-457 run archive | `docs/validation/gul-457/final-changed-coverage.txt`: 413/419 (98.57%); actual archive used by pinned/default-replacement journeys |
| Stage 3 / GUL-458 per-run dispatch | `AskAgentTurnTests`, `TestAgentTurn*`, HTTP peer admission and both new SQL pinned journeys rerun here |
| Stage 3 / GUL-436 registry/turn composition | `docs/validation/gul-436/validation.md`: 68/74 (91.89%) |
| GUL-437 recovery | `docs/validation/gul-437/README.md`: 102/103 (99.03%) |
| GUL-438 files | `docs/validation/gul-438/correction/README.md`: full PR 868/887 (97.86%) |
| GUL-439 command clipping | Existing `AskHostCommand` and ManagedProcess evidence; repeated here through approved dispatch |
| GUL-440 jobs | Existing `AskCommandJobTests` plus model lifecycle; selected exact regressions repeated here |
| GUL-441 authority | `docs/validation/gul-441/correction/README.md`: 648/692 (93.64%) |
| GUL-442 queue | `docs/validation/gul-442/README.md`: 479/486 (98.56%) |
| GUL-443 prompts | `docs/validation/gul-443/results.md`: Swift 67/67; Go 93/93 |
| GUL-444 waves | `docs/harness/gul-444-web-waves.md`: Swift 126/127 (99.21%); Go accepted #161 behavioral/line evidence stays separate |
| GUL-445 integration | No changed production executable lines. Measured production-path coverage is exported separately; do not report a synthetic 100% changed-production percentage. |
