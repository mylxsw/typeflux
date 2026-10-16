# Recording timeline batch authority

Validated base: main `b463b30929462b7e60b7ff8e35384dd36f5a60de`, including the launcher-home changes already on that base. Focused validation does not independently validate launcher-home behavior.

## Behavior and self-review

MediaWorker can snapshot existing availability before deferred caller preparation and accept that immutable authorization at native operation admission. The stamp binds a unique worker identity, its current gate and original managed generation. It reserves no capacity, spends no recovery budget and performs no IO. Pre-ready, foreign-worker, rebound and retired managed-generation stamps cannot become current after recovery. Callers omitting the optional stamp retain their existing entry-time admission contract.

Timeline and video/GIF poster loaders capture the stamp at loader entry, before reserving pixel/slot leases or inspecting the source. Their detached work checks original cancellation/authorization before and after source preparation, supplies the original stamp to native admission, and checks again before returning the result. An old batch held in metadata preparation cannot adopt a recovered native lane. Existing UI generation/account/source checks remain in the callers. Work preceding loader entry has not acquired this new stamp; this change does not claim a single epoch spanning every earlier UI action.

Metadata-only inspect remains independent of native availability. It now propagates cancellation into its detached entry and still joins actual source preparation before releasing its shared slot. A narrow immutable SourceReader constructor dependency permits held/counting fixtures; production uses the same ClipboardPlaybackSource constructor. That constructor performs lstat/statfs metadata checks; it does not open or retain a source FD. Earlier handoff wording describing it as opening the source was imprecise. Native input copying/FD and child ownership remain in MediaWorker.

Caller cancellation is evaluated outside the worker state lock, since the composed predicate can query worker authorization. Capacity, identity and generation admission remain under the existing lock; the existing post-admission cancellation check still fences the body. Pixel/provider, directory/FD, child and host leases retain their existing physical collection rules. No helper protocol/packaging, pool, per-view ModuleHandle, full DI, mutable bypass, new authority grant or health-triggered work was added. No export/write retry, rollback, recovery deletion or replay.

Self-review traced timeline/poster/inspect, toast generation/account retirement/source checks, coordinator preview completion, managed gate generations, standalone binding, capacity and actual retirement. Unmanaged/custom workers retain their contract: there is no managed generation for a standalone cooldown. An entered filesystem/native effect cannot be rolled back, and checks do not form a linearizable permission/filesystem transaction.

## Focused validation

Using scripts/test_runtime.child_environment:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '<explicit inventory in timeline-batch-authority-methods.json>'
```

Prebuilt native_tools/native_environment/swiftpm-testing-helper inventory, not XCTest as a program. **45/45 distinct methods passed on the first functional run:** 40 XCTest methods across five suites (2.110s execution), five Swift Testing methods in one suite (0.104s). Five new methods/eight cases cover pre-ready/foreign/rebound/shutdown stamps, reentrant cancellation, timeline/video/GIF preparation spanning managed recovery, canceled preparation retaining pixels until actual return, metadata-only fallback and canceled metadata work retaining both slots until collection. Fresh explicit batches after recovery succeed using injected raw pixels. All held fixtures are released and tasks joined.

Existing selected methods cover malformed envelopes/geometry/input bounds, source mutation/deletion, canceled producer retirement, delayed child reaping, health budgets/reset, account retirement and late UI decoder results. Selected tests use private bytes/raw rasters/FIFO/sparse files/injected runners and private in-process panels. No real helper, generated-media decoding, actual recording/capture, audio playback, TCC, apps, home/network files, weights/CoreML/provider/network/download/full suite/signing/hardware. Real-helper/attachment and managed real-media batch methods were explicitly excluded, rather than run as opt-in skips.

Build132.71s passed without changed-file warnings (unrelated warnings remain); inventory4.804s; test command31.44s; archive3.901s. Tracked total168.954s, or172.855s including archive, excludes extraction/audits/platform work. No functional retries, timeout relaxation or Source/test edits after build. Each build/test/archive/extraction was collected before dependent evidence work.

## Coverage evidence

Changed executable lines vs stated base: **61/61 (100%)**, MediaWorker27/27 and timeline loader34/34. This is line coverage, not every branch/race/errno/device or native allocation.

Three fresh matching HOST profiles from one binary: XCTest discovery, XCTest execution and Swift Testing host. Each raw individually validated; warning-free merge; llvm-cov show/export use matching app --object and empty stderr. Both binaries contain __llvm_covmap and __llvm_prf_cnts. Old live/root default profiles excluded; no cross-layout merge or child-process coverage claim. All1,127 Source and811 test Swift hashes verified against prebuild inputs and archive after extraction, together with both binary hashes. No new production Source file. Zero Swift function hashes cannot establish compatible coverage layouts; matching inputs/binaries provide that evidence.

Private archive .build/timeline-batch-authority-validation/final:

- Test host SHA-256: `61420e06f2653599c8cc71ca6ef135b830b84684e5d828a9d05132c06c8fa08f`
- App SHA-256: `fc982fc4c031253fcf4a6e187ca235f5800e0d87a4dfc500642a9ca5f79f2f9c`

## Remaining boundaries

Broader feature/native/media original-batch audits remain, including preparation before other existing native consumers. This opt-in API does not retrospectively stamp legacy callers. Account/source/control consent still follows existing caller contracts. Concurrent settings writers/binding, direct defaults/separate defaults objects sharing a suite and external preferences/OS FDA ordering remain outside earlier settings receipts. Health recovery remains availability-only with no probe/load/prepare/download/query/scan/rebuild/replay. Stable mutation identity is required before any future write retry.

No presentation/helper ABI/entry/package change, so no screenshot/copied probe. Audio/TCC/signing/performance precede microphone ownership; real CoreML/model performance/full Xcode/DeveloperID/notarization/macOS13 Intel/actual quit recording remain unverified. HostFS/JSON/SQLite/raw memory/UI/AppKit/GPU/system memory remain boundaries; no arbitrary host/native crash, OOM or power-loss immunity.
