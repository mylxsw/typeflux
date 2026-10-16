# GUL-399: semantic embedding ownership prerequisite

Base: `104f8e57d650bf7e9663cbf0a3c86857a8d1765a` (#574). This increment repairs the production service's native embedding replacement and explicit-clear boundary. It does **not** register semantic health domains. Filename-index health and the three semantic file-reader lanes are unchanged.

## Behavior and ownership

`SemanticEmbeddingOwners` gives each service three independent, fixed native lineages: query, document indexing, and media embedding. Default worker factories reuse the corresponding `AskFileReaderOwnership` across service/scope replacements. A nonwaiting host lock covers request processing, vector validation, cache lookup and synchronous trace consumers. A new host operation fails unavailable while that lane is occupied. Native admission additionally retains the existing child reservation through actual collection; replacing a worker object cannot enlarge that capacity.

Every default native worker receives the original service cancellation token. A stopped old scope cannot acquire fresh permission from a new service start, including cached query delivery. Cancellation is checked before and after host work and before final query continuation delivery. Already-entered consumer effects cannot be rolled back. Standalone workers retain their own owner; this is not a global capacity limit across arbitrary service instances.

Service start, clear and release signal only the thread-safe owned-process stop handle. Reader FD/buffer/cache cleanup remains on its existing serial owner. Indexing also releases its encoder on every exit. No new process, parser, global worker, per-view supervisor or full-DI construction was added. Existing external semantic helper newline ABI, vector validation, priorities, source/root checks, lexical and filename fallback, and partial committed index state remain.

`clear(removeModel:)` still represents an explicit user action. After its existing work/download joins, it waits up to two seconds for these native lineages to become idle. A blocked host or unreaped child makes clear fail while preserving the database and model files. Retirement never retries clear; a later explicit clear can succeed. This two-second bound covers only the added confirmation loop, not the existing joins, filesystem work, scheduling or whole application shutdown. No clear or database/model deletion was added to recovery.

The old automatic retry of `AskFileReadError` during query embedding has been removed. A missing acknowledgement can follow model loading or inference; the current operation fails once. A subsequent explicit request may start a retired helper. Pending same-query continuations are capped at 32; with a drained batch and a pending batch, an instance retains at most 64 such continuations. New typing still supersedes pending older text; cache remains 16 queries. This is not a new global text-byte or memory budget.

Explicit injected factories remain supported and retain responsibility for their own resource lifetimes. All production service factories use the new default native ownership. Model verification and media download work remain joined to the index/service work as before. This increment does **not** establish a global filesystem path lease against another service/process, protect arbitrary model installation/replacement against every concurrent reader, coalesce existing idle/stop/progress task queues, or register semantic persistent health. Those are remaining audit/integration work. No native failure classification or protocol schema change was made.

## Validation

Implementation and self-review preceded the focused functional pass. **56 distinct methods passed in one completed pass: 23 XCTest and 33 Swift Testing.** No functional failures or retries.

| Scope | Methods | Purpose |
| --- | ---: | --- |
| SemanticEmbeddingOwnershipTests | 5 | Independent lanes, blocked host after actual child collection, delayed collection, revoked generation, bounded waiters, media refusal and malformed vectors |
| SemanticEmbeddingServiceOwnershipTests | 2 | Clear retains private artifacts on timeout, no clear replay, default native query/index replacement using a private shell protocol fixture |
| SemanticEmbeddingWorkerTests (exclude real model) | 5 | Vector validation, idle/cache, same-query coalescing, no automatic retry, voice cancellation and explicit restart |
| AskFileReaderRetirementTests | 9 | Owned PID/group/reaper and host retirement compatibility |
| SemanticReaderOwnershipTests | 9 | Existing three reader lanes and late-result behavior |
| SemanticReaderServiceTests | 1 | Scope replacement and no query replay |
| SemanticFileServiceTests (safe selected methods) | 8 | Model fixture lifecycle, explicit clear/rebuild, settings, corruption and partial index compatibility |
| SemanticRealtimeSearchTests (exclude real file/model) | 8 | Lexical fallback, privacy, scope/cancel, foreground and selection behavior |
| SemanticMediaWorkerTests (exclude real weights) | 3 | Injected model transfer and private helper cache compatibility |
| SemanticMediaServiceTests | 4 | Media failure, idle, document priority and service release |
| SemanticPreparationServiceTests | 1 | Cancelled preparation |
| SemanticIndexFairnessServiceTests | 1 | Partial index and priority compatibility |

Private shell children supply synthetic vectors or fail harmlessly. The built main file worker touches only private test fixtures. Model download tests use injected fixture files/transfer implementations; no real model/weights/CoreML, download, network/provider, home/network-mount scan, FDA/TCC probe, capture, microphone, audio output, user clipboard, paste/wheel or external app action was executed. No full suite, full Xcode, signing, hardware or real-model performance validation. No presentation or helper packaging/entrypoint change, so no new screenshot or packaging probe.

Commands (workspace scripts use `scripts/test_runtime.child_environment`):

```text
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
otool -l TypefluxPackageTests  # verified __llvm_covmap and __llvm_prf_cnts
native_environment/native_tools + swiftpm-testing-helper prebuilt inventory
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter <scope below>
```

Exact filter:

```text
^Typeflux(?:Focused)?Tests[./](?:SemanticEmbeddingOwnershipTests[./]|SemanticEmbeddingServiceOwnershipTests[./]|SemanticEmbeddingWorkerTests[./](?!realModel)|SemanticMediaWorkerTests[./](?!realImage|realMediaFiles)|SemanticFileServiceTests[./](?!liveModel|`actual model|nativeControls|nativeManagement)|SemanticRealtimeSearchTests[./](?!`real file)|SemanticPreparationServiceTests[./]|SemanticIndexFairnessServiceTests[./]|SemanticMediaServiceTests[./]|AskFileReaderRetirementTests[./]|SemanticReaderOwnershipTests[./]|SemanticReaderServiceTests[./])
```

First build: **178.74 s**, failed only because the new fixture's throwing `??` expression needed an outer `try`. Fixed after build exit. Final build: **36.26 s**, passed. Prebuilt inventory: **3.788 s**. Functional command: **58.17 s** (XCTest 11.765 s; Swift Testing 18.034 s). Total tracked command wall time **276.958 s**, excluding source/platform audit, archive/coverage extraction and inspection. No discovery rebuild, simultaneous own SwiftPM/UI jobs or source/test edits after the final build. Existing unrelated warnings remain.

## Coverage evidence and limits

**77/77 changed executable lines (100%)** against the actual base: ownership 27/27, worker 30/30, service 20/20. The JSON companion records per-file counters. Definition/guard line hits are not proof that every factory branch, errno, allocation, reaper interleaving, callback race, watchdog, model or device behavior was exercised.

Only **three fresh host profiles**, collected with one final binary/layout, are used. Every raw profile was individually validated; sparse merge completed without warnings. The matching app executable is included with `llvm-cov --object`; new Sources were marked intent-to-add before diff coverage. Persistent native children killed and collected by the tests did not contribute coverage; there is no child-coverage claim. No old profiles or layouts were merged. Inventory profiles are excluded.

Evidence: `.build/semantic-embedding-validation/final`. SHA-256:

- XCTest: `1200d9eba5b44d6773a2b287c76566c0dafeaef75521e672468cab021614b23c`
- App/worker: `35609a5a08078c49cca901ba7615180148bce15f04a0d140d57f5864a546462a`

All production source hashes match the archived final binary inputs. Build, test, archive, merge and extraction commands were collected before dependent reads. The app's existing macOS 13 deployment setting and this macOS 14 XCTest runtime are not macOS 13 Intel hardware proof. No arbitrary host crash, systemwide OOM, power-loss cleanup or rollback guarantee is made. GUL-399 remains in progress.
