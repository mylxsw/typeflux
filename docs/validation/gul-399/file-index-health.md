# GUL-399: filename-index worker health

This increment targets `agent/arch-gpt-astra/gul-399-file-reader-retirement` at `b40cf9b9d921e4fa174b91f5a76c0f47dda92221` (PR #572), which remains open. It registers the filename index only. Semantic indexing, embedding, query validation and preview-reader ownership remain separate work. No PR was merged, no CI result was awaited.

## Behavior and ownership

- `FileIndexModule` registers `ModuleID.fileIndex` / `fileIndex.json`, alongside nine media domains, native commands, Whisper, playback and three stores (16 registrations). It reuses the core gate, supervisor and bounded content-free health store. Persistent reservation is once per factory generation, never per file, directory or request. Corrupt health is preserved until explicit reset. Storage behavior is unchanged; this domain does not opt into main's storage-only automatic reset.
- Factory readiness checks executable availability off the UI actor and that the same lineage is empty. It never launches a worker, checks Full Disk Access, calls index `start`, loads snapshots, scans, resolves paths, embeds or downloads models. This is availability, not signing/native-format proof. Typed reader calls do not enter the supervisor's generic operation timeout.
- Production `AskFileIndex.shared` requires lifecycle readiness; the existing XCTest configuration-off privacy guard remains. Explicit constructor/reader seams stay available without full DI or a global mutable bypass. DI retains the adapter; existing registry startup, disable/recover and quit fencing include it.
- The original lineage/generation admits one child. `AskFileReaderProcess.stop` and ownership observation now share a narrow lock; the installed weak stop handle can cancel the owned child across threads. Reader file descriptors and buffers remain serial-owner-only. Lifecycle cleanup fences the index immediately, queues watcher/reader cleanup on the original index queue, and waits for both host completion and actual child collection. A two-second supervisor cleanup deadline does not free occupied capacity or replace the lineage. A late stop installation is cancelled; releasing a rejected duplicate adapter cannot stop the real owner.
- Quiet health stop preserves the last authorized published cache and existing snapshot; it does not call `clear`/`turnOff`. It stops further scan publication, queued changes and scheduled saves. Recovery does not restart the watcher or re-run an old scan. The next explicit rebuild, or a new caller-requested scope when available, may scan. Opening the launcher still performs the existing off-UI permission refresh; configuration/FDA changes withdraw old cache and status paths even while the worker is unavailable. Health is not permission. Explicit clear retains its original delete-cache semantics. Explicit forget while paused removes only the published cached entry, without publishing other uncommitted working-scan entries.
- Valid typed POSIX input refusals remain successful transport responses and do not fault health. Cancellation, revoked generations and reaper capacity refusal do not count as crashes. Missing replies, malformed JSON, oversized framing, timeout and post-launch transport errors fence the generation. Launch EACCES/EPERM/ENOENT/ENOEXEC wait for explicit recovery. No raw source paths, queries or diagnostics are added to health persistence.

The existing newline protocol has no UUID/version envelope; this change does **not** claim response identity validation or change the external semantic-helper ABI. An idle child exit is observed by the next request or stop, not a new unsolicited process monitor. The 8 MiB receive buffer, five-second idle timeout, default startup allowance up to 30 seconds, and progress-based idle extension are retained. Large advancing directory scans still have no total deadline. The 250 ms lineage collection grace, one serial filename-index owner and existing 16-child global reaper ceiling remain; other owners have independent lineages. No global limit on arbitrary independent host callbacks is claimed.

Permission checks, snapshot encoding/writes and other filesystem work can block. Queue-fenced cleanup retains lifecycle work while the index queue is blocked. The preparation queue remains serial and generation-fenced; it is not a hard-cancellable filesystem worker. Already-dispatched snapshot filesystem writes or entered consumer effects cannot be rolled back. No automatic scan, database write, model download or user action replay is added. No cache/database/model deletion is used for health recovery. Whole-app quit latency, arbitrary host crash, system OOM and power-loss guarantees are not provided.

## Audit scope

Reviewed `AskFileIndex` start/follow/rebuild/apply/forget/clear/save/observers, the launcher call through `AskConversationModel+QuickResults`, background activity, DI/quit, reader protocol/CLI, repaired process lineage and reaper. The filename index's default factory already shares its lineage across replacements. `SemanticFileSearchService` separately constructs query validation, index and priority readers; `SemanticEmbeddingWorker` retains an immutable serial reader; lexical/vector readers are read-only SQLite connections. Those fault domains were not merged or duplicated. Main's concurrent storage/chat/background changes remain outside this feature tree and must be preserved at landing.

## Validation and failure history

Implementation/self-review preceded the focused functional run. All Swift builds used:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
```

All functional runs used the prebuilt binary:

```sh
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '<explicit regex below>'
```

The wrapper uses `scripts/test_runtime.child_environment`. Prebuilt inventory used `native_environment`, `native_tools` and `swiftpm-testing-helper`, never xctest as a discovery program. Both `__llvm_covmap` and `__llvm_prf_cnts` were verified. No discovery rebuild or simultaneous own SwiftPM/UI job was run.

Initial inventory matched **78 distinct methods**: 9 new FileIndexModule, 1 new actual health UI, 9 reader-retirement, 3 reaper, 6 streaming, 10 reliability, 7 index-service (excluding real FDA probe), 5 scope, 3 preview-reader, 5 injected semantic-worker (excluding opt-in real model), 12 registry, 6 health-store, 1 storage compatibility and 1 localization. The completed broad pass was **78/78** (22 XCTest + 56 Swift Testing). After a final explicit-forget compatibility correction, the smallest affected suites passed **16/16** (9 XCTest + 7 Swift Testing). The remaining 62 methods were not redundantly rerun.

Before the successful 78-method run, the first attempt blocked in its first reader test: the newly composed cancellation callback re-entered `AskFileReaderOwnership` while `reserve` held its lock. A sampled stack confirmed that path. The exact run-owned Swift test process was interrupted, which also collected its XCTest child; a subsequent explicit child lookup found it already gone. No methods completed in that attempt. The fix evaluates caller cancellation outside the lock. This failed attempt is excluded from coverage. No assertion failures occurred in either completed functional pass.

The first build failed on a non-escaping closure capture; the explicit-forget correction's first build failed on missing explicit `self` inside a nested closure. Both were fixed before their functional runs. Other existing unrelated Sendable/deprecation warnings remain.

New regression coverage includes: readiness without FDA/scan, one reservation across repeated requests, independent media budget, simulated clock/recovery, corruption preservation/reset, controlled input refusal, reaper saturation, malformed/truncated/crashed/oversized/stalled transports, launch configuration, stale generations, cancel-before-attach, delayed collection, blocked consumer/cleanup deadline, duplicate owner binding/release, actual private-directory index and snapshot preservation, no recovery scan, explicit rebuild, explicit forget while stopped, and configuration/permission retirement. Existing regressions preserve long progressing directories, partial batches, healthy siblings, scope filtering, stream cancellation, real main-worker reuse and injected semantic queues. The actual settings restore button was exercised and the 640×190 screenshot inspected.

Native filesystem/worker fixtures use private temporary directories; semantic engine fixtures use harmless injected scripts. No actual home/network mount scan, native FDA database probe, model/weight download, CoreML inference, capture/microphone/TCC request, audio output, user clipboard/paste/wheel, external app/provider/network operation, full suite, full Xcode, signing or hardware validation was performed. No packaging/entrypoint change, so no separate packaging or copied-bundle probe was added; the built main-executable file worker was exercised.

### Exact scopes

Broad pass:

```text
^Typeflux(?:Focused)?Tests[./](?:FileIndexModuleTests[./]|FileIndexHealthViewTests[./]|AskFileReaderRetirementTests[./]|OwnedProcessReaperTests[./]|AskFileStreamingTests[./]|AskFileReliabilityTests[./]|AskFileIndexServiceTests[./](?!fullDiskAccessProbe)|AskFileScopeTests[./]|AskFilePreviewReaderTests[./]|SemanticEmbeddingWorkerTests[./](?!realModel)|ModuleRegistryTests[./]|ModuleHealthStoreTests[./]|StorageModuleRegistryTests[./]|LocalizationResourceTests[./]testLocalizedStringTablesParseForAllSupportedLanguages)
```

Final affected pass:

```text
^Typeflux(?:Focused)?Tests[./](?:FileIndexModuleTests[./]|AskFileIndexServiceTests[./](?!fullDiskAccessProbe))
```

### Timings

| Command | Wall seconds | Result |
| --- | ---: | --- |
| Build 1 | 45.44 | Failed non-escaping capture |
| Build 2 | 162.95 | Passed |
| Build 3 | 43.79 | Passed self-review publication/condition changes |
| Prebuilt inventory | 3.925 | 78 methods |
| Functional attempt 1 | 57.31 | Interrupted confirmed lock reentrancy; no completed methods |
| Build 4 | 52.45 | Passed lock and scope-status correction |
| Broad functional pass | 82.88 | 78/78; XCTest 17.109, Swift Testing 21.851 |
| Build 5 | 18.87 | Failed nested explicit-self correction |
| Build 6 | 42.48 | Passed |
| Final affected pass | 19.59 | 16/16; XCTest 10.685, Swift Testing 0.700 |

Tracked total **529.685 seconds**, including failed commands and runner startup/planning, excluding source audit, sampling/termination tool overhead, archival/extraction, screenshot inspection and platform/GitHub delivery. Each build/test and each archive/extraction process was collected before dependent edits/reads. No source/test input changed after the final build.

## Coverage evidence

Changed executable lines against actual PR base `b40cf9b9`: **183/187 = 97.86%**. Ownership/process 63/63; adapter 31/31; reader 21/22; index 68/69; DI 0/2. The four uncovered lines are two DI bridges, the production shared-index configuration closure and the default no-op protocol stop seam. Guard/line hits do not prove every branch, allocation failure, PID interleaving, OS hang or device behavior.

Attribution is deliberately per-file, without merging incompatible Swift counter layouts:

- All files except `AskFileIndex.swift`: the 78-method pass's **12 fresh profiles** (3 host + 9 actual app/file-worker), with its matching test/app binaries. Production hashes were verified unchanged for these files after the final correction.
- `AskFileIndex.swift`: only the final 16-method pass's **3 fresh host profiles**, with its matching final test/app binaries. No final-child coverage claim.
- Every raw profile was individually validated with `llvm-profdata show`; each separate merge was warning-free. `llvm-cov show` included the matching main application `--object`; new Sources were added with `git add -N` before extraction. Inventory, older-run and interrupted-attempt profiles were excluded. No profile was merged across the two test-binary layouts.

Evidence folders: `.build/file-health-validation/{initial,final}`; `initial` denotes the successful 78-method pass, not the interrupted attempt. Matching hashes:

| Pass | Binary | SHA-256 |
| --- | --- | --- |
| 78-method | tests | `d45d927064421547815a68d5fdf50d3727c6a4c364df4ce04d81ad305d3629d6` |
| 78-method | app | `d43e8af7d633b0fd470a3f6bfdba3e0fafebad4363f07c890130691d297cb2da` |
| Final 16-method | tests | `3e51ec656d44020e0239e7ba4516fc2f4817629c4d2e0e101b9b9409e4100fe9` |
| Final 16-method | app | `84853cadc1ac64febd570f1bcb8dbb7e288142f33eb179eef6bb9b8ba52c66ed` |

The app's build metadata retains macOS 13 minimum; this is not macOS 13 Intel hardware proof. The screenshot and coverage JSON are committed alongside this report. All run-owned commands and test children were collected. Other workspaces' processes were not touched.

## Remaining approved work

Semantic reader/model-worker lifecycle and ownership, other feature adapters and broader condition-driven integration remain. Capture/live audio ownership, real models/performance, audio/TCC, Developer ID/notarization, macOS 13 Intel, full Xcode and real quit-during-recording validation remain unverified. Host filesystem/JSON/raw memory/AppKit/pasteboard/SQLite/UI/GPU boundaries remain. Encoding unknown candidates/receipts and single authorized publication are untouched. GUL-399 is not ready for overall acceptance.
