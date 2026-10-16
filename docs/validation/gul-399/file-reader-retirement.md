# GUL-399: file reader retirement prerequisite

Stacked on #571, actual base `5d29cdf42456342e0b6d38893b2f31f1fc37a866` (`agent/arch-gpt-astra/gul-399-playback-health`). Main remains `ceeaaef5bf4f2e5625a0654d6f3d31702821f174`; its storage-only automatic quarantine reset, chat/background-task changes must be preserved. This increment repairs ownership before file-index health registration; it does **not** register another module or claim all file/semantic lifecycle integration is finished.

## Behavior

`AskFileReader` previously launched Foundation Process, sent a raw SIGKILL after checking isRunning, then immediately cleared its Process reference. Neither a nil reference nor that check proves actual collection, and a separate Foundation reaper can race later raw PID signaling. Index settings/rebuild/event paths can replace a reader while an old child remains uncollected.

New `AskFileReaderProcess` owns a POSIX child and process group. It reserves the existing OwnedProcessReaper capacity before spawn, duplicates only stdin/stdout (stderr remains null), uses close-on-exec defaults and resets the child's signal mask/dispositions. It retains the leader's PID through the last group/direct signal using waitid(WNOWAIT), then hands collection to the existing nonblocking reaper. A failed ownership observation never authorizes another signal. Spawn failure releases its reservation; repeated stop is inert. This preserves the former immediate SIGKILL cancellation policy while also cleaning ordinary same-group descendants. Escaped process groups, arbitrary competing collectors and kernel-uninterruptible calls are not a hostile-process-tree guarantee.

`AskFileReaderOwnership` represents one serial reader lineage. UUID-fenced admission remains occupied until **both actual child collection and all admitted synchronous host/callback work finish**. Old completion cannot release a newer lineage. Stop during a callback cannot make the old stream return success afterward; reentrant reads are rejected. Already-entered callback effects are not rolled back. The reaper callback only changes small locked ownership state; it never waits for a consumer or filesystem operation.

The default AskFileIndex factory captures one ownership object across reader replacements. Other standalone readers have their own lineage; the immutable reader inside each SemanticEmbeddingWorker consequently retains its own admission across restarts. No new global worker, helper, health budget, per-request supervisor or DI initialization. The existing global reaper still bounds unreaped children (16); this is a physical collection ceiling, not a merged health domain. Separate SemanticFileSearchService factories/feature lifetimes still need their later adapter audit. Arbitrarily creating separate reader lineages does not acquire a new global bound on blocked host callbacks.

A subsequent explicit operation may wait up to a **250 ms monotonic collection budget**, checking cancellation and sleeping in relative 10 ms increments, before reporting unavailable if the old lineage remains occupied. There is no queued producer or replay. Scheduling and lock/syscall delays are outside a hard real-time guarantee. Normal killed-child collection permits the existing next healthy sibling request; an uninterruptible child cannot be replaced repeatedly. stop itself never calls waitUntilExit. The reader remains a serial-owner API, not a new concurrently callable object; a queue blocked inside a consumer cannot instantly execute a queued stop.

## Compatibility and boundaries

Newline JSON, bounded 8 MiB receive buffer, typed operations and partial directory delivery are unchanged. Five-second idle / maximum-30-second default startup budgets remain; each received frame/chunk extends progress, so a large advancing directory still has no new short total deadline. No automatic scan, resolve, embedding, model download, index rebuild or write retry was introduced. Existing caller source/root/exclusion/generation and cancellation policies remain; directory/native filesystem snapshots are not immutable transactions.

The same executable/arguments, inherited environment/cwd and main-executable early `file-index-worker` entry remain. Background and utility process demotion use Darwin's public spawn QoS API. That API accepts **only** BACKGROUND and UTILITY; foreground/default requests use the normal process class rather than invalid spawn attributes. Separate query/index host queues remain. Exact effective foreground priority and real model throughput were not measured.

Audited AskFileReader/protocol/worker entry, AskFileIndex replacement/queue/watch/quit paths, preview reader, SemanticFileSearchService factories, SemanticEmbeddingWorker and SemanticMediaWorker. SemanticFileContentWorker is an existing decoder path; SemanticLexicalReader/VectorReader are separately owned read-only SQLite readers, not new subprocesses. None was duplicated or given a new decoder. No source/model/private output ownership outside this reader lineage was claimed solved. Existing database/snapshot behavior is unchanged; no database recreation or destructive migration was added.

## Focused validation

**50 distinct methods** were exercised: initial **44/50 passed**, with six failures caused by one real QoS mapping defect. The new five-class launch fixture and all five injected semantic-worker methods exposed EINVAL for foreground/default values. After restricting the spawn attribute to its two supported classes, the final affected **16/16 passed** on a fresh build (9 XCTest + 7 Swift Testing). The other 34 initial passing methods were not rerun without a new dependency change.

Initial scope: 9 new AskFileReaderRetirementTests, 3 OwnedProcessReaperTests, 6 AskFileStreamingTests, 10 AskFileReliabilityTests, 7 AskFileIndexServiceTests (excludes the real Full Disk Access database probe), 5 AskFileScopeTests, 3 AskFilePreviewReaderTests, 5 SemanticEmbeddingWorkerTests (excludes real model opt-in), 2 SemanticFileContentTests. Final scope: all 9 new methods, all 5 injected semantic methods, actualWorkerReusesConnectionAndHandlesLargeResponse and buildsWatchesAndFollowsChanges.

The new tests cover host/child retirement in either order, delayed collection, occupied replacement and independent owners, callback stop/reentrancy/late success, stale UUID completion, cancellation before launch, invalid executable/arguments, exhausted reaper capacity, malformed/truncated/oversized output, harmless crash/hang, five priority requests, externally collected child observation and same-group descendant termination. Compatibility covers real private file/PDF worker requests, 10,050 slowly advancing entries, stalled directories with healthy siblings, partial batches, aliases/exclusions/private index updates and injected semantic connection reuse/idle release/stop/cancellation. No model weights, real inference/download/provider/network, home/network-mount scan, capture/microphone/TCC, audio output, user clipboard/paste/wheel or external application launch was requested. No full suite, signing/full Xcode/device validation. No presentation change or screenshot. Packaging and early-entry contracts did not change; actual built main-executable worker was exercised, without a separate copied-bundle probe.

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
# Verify __llvm_covmap and __llvm_prf_cnts in XCTest and the app/worker binary.
# Prebuilt inventory: native_environment/native_tools + swiftpm-testing-helper.
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '^Typeflux(?:Focused)?Tests[./](?:AskFileReaderRetirementTests[./]|OwnedProcessReaperTests[./]|AskFileStreamingTests[./]|AskFileReliabilityTests[./]|AskFileIndexServiceTests[./](?!fullDiskAccessProbe)|AskFileScopeTests[./]|AskFilePreviewReaderTests[./]|SemanticEmbeddingWorkerTests[./](?!realModel)|SemanticFileContentTests[./])'
# After the QoS correction, final affected scope:
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '^Typeflux(?:Focused)?Tests[./](?:AskFileReaderRetirementTests[./]|SemanticEmbeddingWorkerTests[./](?!realModel)|AskFileIndexServiceTests[./]buildsWatchesAndFollowsChanges(?:\(|$)|AskFileReliabilityTests[./]actualWorkerReusesConnectionAndHandlesLargeResponse(?:\(|$))'
```

Build commands: 48.65 s failed (wrong QoS API arity); 169.67 s failed (throwing inference in a new nonthrowing callback fixture); 91.01 s passed after fixes and monotonic waiting/PID observation review; 46.22 s passed after correcting a test predicate that would consume waitpid twice; 30.49 s passed after the functional QoS correction. Both compile fixes and the predicate correction preceded functional tests. Inventory 8.071 s. Test commands 62.03 s initial and 19.63 s final (final XCTest 6.705 s / Swift Testing 4.557 s). Tracked total **475.771 s**, excluding audit, archival, extraction and platform/git actions. Existing unrelated compiler warnings remain. No source/test inputs changed after the final build.

## Coverage

Changed executable lines against actual base `5d29cdf4`: **113/113 = 100%** (ownership/process 94, reader 17, index factory 2). These are line hits, not proof of every errno/native allocation/QoS/device/clock-jump/PID-reuse interleaving or real application quit.

Only **three fresh host profiles from the final binary** contribute. Each raw profile was individually validated and the merge was warning-free; matching app/worker included with llvm-cov --object, new source included via git add -N. No child-coverage claim: final persistent native workers are killed/collected and did not emit profiles. Initial 12 profiles and binaries were archived but entirely excluded. The initial archival command was collected after the correction build had started; no initial source-hash/artifact attribution is used. Final archive and extraction were completed before dependent reads, and final production hashes were checked. Inventory and prior codecov files excluded; no mixed counter layouts.

Local evidence `.build/reader-retirement-validation/final`:

- XCTest SHA-256 `ca82044ed639f261a7d4d54d1108674b072174042581c8a81458a30619046f05`
- app/worker SHA-256 `41b809e717add9f48effcecc9f6d7bac0b7ff9cb7d01123a65ce45839d343331`

App minOS remains 13.0; this is not macOS 13 Intel verification. File-index independent health registration, semantic/other feature adapters, broader condition integration and audio/TCC/signing/performance/model/device/real-quit validation remain. Host filesystem/JSON/raw memory/SQLite/UI/AppKit/GPU/system memory remain boundaries. No arbitrary host/native crash, systemwide OOM or power-loss guarantee. GUL-399 stays in progress.
