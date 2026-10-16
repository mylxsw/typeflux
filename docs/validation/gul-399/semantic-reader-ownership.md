# Semantic file reader ownership prerequisite

GUL-399; base `8603d3200cd0d7c8029e0861bba586e8b03cb680` (#573).
This increment is stacked on file-index-health. It does **not** register semantic
health domains or change the filename-index adapter. Main remains a separate
landing target; its storage-only automatic quarantine reset must not be enabled
for semantic workers.

## Behavior and ownership

`SemanticFileSearchService` previously constructed a new permission validator
reader on each start, plus fresh discovery and priority readers in detached
indexing jobs. An old query could retain its validator while a new scope started
another child/host lineage. Awaiting the indexing task alone did not join those
query consumers.

`SemanticFileReaders` now owns three fixed, independent serial lanes per service:
permission validation, discovery/content, and priority documents. Each lazily
constructs one reader and retains its native `AskFileReaderOwnership` across
scope changes and child restarts. Injected factories remain explicit constructor
seams; production constructs distinct readers without full DI or a global test
switch. A factory is called at most once per lane, not once per service start.

Scope tokens revoke old access permanently. A lane admits one synchronous
factory/read/stream/consumer at a time, rejecting occupied admission as
unavailable rather than queuing or constructing a replacement. Cancellation is
checked before factory work, before/after native calls and before/after consumer
delivery. Effects of a callback already entered cannot be rolled back.
Unavailable/revoked permission validation reports incomplete results, never a
successful empty validation that proceeds to model inference.

Service start/scope changes, clear and owner release revoke the three lanes.
Index/priority scopes are captured **before** scheduling detached work, so an old
job cannot issue a new scope after replacement. Indexing completion explicitly
stops both scopes. Stop coalesces at most one cleanup block per lane on a private
utility queue. It does not close reader descriptors on the UI thread or race a
host call: cleanup waits for the lane lock, and cancelled host work also stops
its reader before releasing admission. The off-UI waiter closes the narrow
cancellation-versus-unlock race; blocked cleanup retains the lane. There is no
task per frame, global cleanup worker, or replacement capacity.

The existing native lineage additionally holds admission until actual child
collection **and** synchronous host completion. Its 250 ms collection grace,
16-child global reaper ceiling, owned PID/group signalling, restricted Darwin
spawn QoS mapping and no-waitUntilExit behavior remain unchanged. Input/output
newline ABI, 8 MiB response bound, 5 s idle/default 30 s startup budgets and
advancing directory scans with **no total deadline** remain unchanged. No new
executable, parser, native fallback or packaging target.

No capability/retirement callback scans, resolves, embeds, downloads, rebuilds,
copies or writes. An explicit later operation may reuse the lane once its host
and child ownership permit it. Existing caller-triggered indexing/watch events
are preserved, not replaced by a recovery replay mechanism. Root/FDA/exclusion
checks, source revisions, service tokens, selected scope and lexical/filename
fallback remain in their existing owners. Health cleanup was not added and does
not call `clear`; existing explicit user clear/removal remains separate.

## Audit boundaries and remaining work

- File-content parsing already runs in the main executable's early worker mode;
  it was not duplicated or moved back into the host. Lexical/vector readers are
  separate read-only SQLite connections, not subprocesses.
- `SemanticEmbeddingWorker` retains one reader/queue internally, but service
  replacement can still construct a new query/model worker while an old host
  operation or queued stop survives. Index and media model factories, idle
  release, pending queries, model ownership and explicit removal need their own
  retirement audit before lifecycle binding. This PR does not repair or claim
  those model lifetimes, and does not change their existing retry policy.
- `reportProgress`, `reportCurrent` and download reporting still create existing
  main-actor tasks. Their backpressure is a separate remaining change; no index
  throughput or model-consent change is claimed here.
- Semantic persistent health/conditions are still unregistered. Future readiness
  must be read-only capability checks, never follow/start/warm/prepare/scan or
  database replay; use independent fault domains and explicit reset.
- Bounds are per service's three file-reader lanes. There is no new global bound
  on arbitrarily constructed independent services, existing validator-lock
  waiters or detached SQLite/FDA/model work. Uncooperative host work/FS/cleanup
  can remain occupied indefinitely. Cancelling an object is not proof that it
  has retired, and there is no whole-app quit, kernel or power-loss guarantee.
- Already-dispatched filesystem/index writes cannot be rolled back by these
  tokens. This increment neither deletes/recreates databases/models for recovery
  nor changes recording unknown candidates, receipts or authorized publication.

## Focused validation

Implementation and self-review preceded functional validation. Five builds:

| Command | Seconds | Result |
| --- | ---: | --- |
| Build 1 | 42.78 | Failed: nonescaping cancellation closure forwarding |
| Build 2 | 177.44 | Failed: two new test dispatch closures inferred throwing; invalid nil Date fixture |
| Build 3 | 33.38 | Passed |
| Prebuilt inventories | 4.254 + 1.005 | Corrected suite names; 56 exact methods |
| Initial focused command | 108.90 | Aborted new service fixture after 47 completed passes |
| Build 4 | 65.83 | Passed: cleanup race hardening and one-shot fixture block |
| Affected command | 43.21 | 35/35 passed: 9 XCTest + 26 Swift Testing |
| Build 5 | 49.92 | Passed: retain stop requests arriving while cleanup exits |
| Final affected command | 33.57 | 35/35 passed: XCTest 5.976 s / Swift Testing 17.113 s |

Tracked command wall time: **560.289 s**, excluding source audit, sampling/abort
overhead, archival, coverage extraction and platform delivery. Existing unrelated
Sendable/deprecation warnings remain. No source/test inputs changed after build 5.

The initial attempt completed 18 XCTest and 29 Swift Testing methods. The new
service fixture accidentally blocked both an old permission read and a new
indexer's metadata read; its single semaphore release could not release both.
A foreground sample identified the injected `RetainedSemanticValidation` wait in
the indexer. Only this run's exact swift-test PID was interrupted; its testing
child was confirmed gone before edits/archival. The fixture now blocks one read
and has an 8 s test-only guard. This was not a production deadlock. Separately,
self-review replaced cleanup's try-lock with one off-UI waiter to close a missed
cleanup race. Delivery review then added a pending-stop flag so a stop arriving during cleanup exit cannot be lost; a fresh build and the same affected 35 methods passed again. No assertion failures occurred in completed passes.

**56 distinct methods completed successfully across the two passes.** Final 35
cover every changed behavior and service integration; the other 21 initial
passing compatibility methods were not repeated:

| Scope | Methods | Mapping |
| --- | ---: | --- |
| SemanticReaderOwnershipTests | 9 | Lazy reuse, old generations, blocked factory/consumer/cleanup, owner release, late callback, independent lanes, actual/delayed child retirement, incomplete validation |
| SemanticReaderServiceTests | 1 | Old/new service scope with blocked validation; no queued query/inference replay; explicit later search |
| SemanticFileValidatorTests | 3 | Preparation preemption, shared deadline, permission/source revision |
| SemanticFileServiceTests | 8 | Injected model setup, disable/settings/watchers/rebuild/clear; real-model/download/UI-only methods excluded |
| SemanticRealtimeSearchTests | 8 | Lexical/filename fallback, source/permission changes, cancellation and selection; real-model method excluded |
| SemanticPreparationServiceTests | 1 | Search/voice cancellation and truthful degraded validation |
| SemanticIndexFairnessServiceTests | 1 | Real private reader, priority document publication |
| SemanticMediaServiceTests | 4 | Injected media waiting/failure/owner release and document priority |
| AskFileReaderRetirementTests | 9 | Inherited owned process, actual reaping, faults, QoS, host callback barrier |
| AskFileStreamingTests | 6 | Long advancing 10,050-entry directory, idle failures, partial batches, mounts and explicit limits |
| SemanticFilePolicyTests | 2 | Explicit scope/credential exclusions and denied permission |
| SemanticFileContentTests | 2 | Private bounded text/PDF and worker round trip |
| SemanticFileIndexerTests | 1 | Changes, deletion, failure and cancellation |
| SemanticFileCapacityTests | 1 | Storage failure retains previously committed file |

Build command (using `scripts/test_runtime.child_environment`):

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
```

`otool -l` confirmed `__llvm_covmap` and `__llvm_prf_cnts` in the test binary and
app. Prebuilt discovery used `native_environment`/`native_tools` and
`swiftpm-testing-helper`, not xctest as a program and not a discovery rebuild.
Functional commands used:

```sh
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '<explicit regex>'
```

Exact initial regex:

```text
^Typeflux(?:Focused)?Tests[./](?:SemanticReaderOwnershipTests[./]|SemanticReaderServiceTests[./]|SemanticFileValidatorTests[./]|SemanticFileServiceTests[./](?!liveModel|`actual model|nativeControls|nativeManagement)|SemanticRealtimeSearchTests[./](?!`real file)|SemanticPreparationServiceTests[./]|SemanticIndexFairnessServiceTests[./]|SemanticMediaServiceTests[./]|AskFileReaderRetirementTests[./]|AskFileStreamingTests[./]|SemanticFileCapacityTests[./]storageFailureIsReportedAndKeepsThePreviouslyCommittedFile|SemanticFilePolicyTests[./](?:`explicit scope|deniedPermission)|SemanticFileContentTests[./](?:`bounded text|`pdf text)|SemanticFileIndexerTests[./]`changes deletion)
```

Exact final regex:

```text
^Typeflux(?:Focused)?Tests[./](?:SemanticReaderOwnershipTests[./]|SemanticReaderServiceTests[./]|SemanticFileValidatorTests[./]|SemanticFileServiceTests[./](?!liveModel|`actual model|nativeControls|nativeManagement)|SemanticRealtimeSearchTests[./](?!`real file)|SemanticPreparationServiceTests[./]|SemanticIndexFairnessServiceTests[./]|SemanticMediaServiceTests[./])
```

Only private fixture directories/documents, injected readers/encoders/models and
harmless shell children were exercised. No real home/network-mount/FDA probe,
model weights/CoreML/download/provider/network, capture/mic/TCC/audio output,
user clipboard/paste/wheel/apps, full suite, full Xcode, signing or hardware
validation. No presentation, entrypoint or packaging change; no screenshot or
separate packaging/copied-bundle probe. The actual built main worker was used
with private file fixtures. macOS 13 app minimum is not Intel hardware proof.

## Coverage evidence

Changed executable lines against the actual #573 base: **108/109 (99.08%)**:
reader lanes 95/96, service integration 11/11, validator 2/2. Guard line hits do
not prove both branches, every cancellation interleaving, native allocation,
kernel/FS behavior or real quit/device behavior. The uncovered line is the cleanup closure end at `SemanticFileReaders.swift:75` (the loop exits through an explicit return); line attribution is not branch proof.

Only **three fresh final host profiles**, one final binary/layout, were used.
Each raw profile passed `llvm-profdata show`; the sparse merge was warning-free.
Matching app worker was included with `llvm-cov --object`; no child coverage is
claimed. New Sources were included with `git add -N`. Initial aborted-attempt
profiles (two), intermediate 35-pass profiles (three), and root inventory `default.profraw` were archived and excluded.
No cross-layout merge or old results. All children, copy, merge and extraction
commands completed before dependent reads; production source hashes match.

Evidence: `.build/semantic-ownership-validation/final`.

- XCTest SHA256: `f6c4e695f2f607b00f15ee51969780a370394e46145b4f368a16b112c671202d`
- App SHA256: `2609767217b6614e1755d837c06d007462e4b26136d9e6be41c06bb234e276df`

All run-owned build/test/sample/archive/extraction jobs were collected. No
run-owned XCTest/testing-helper or file-index worker remained at delivery.
