# Background indexing investigation

The additional user report is a separate acceptance requirement. This patch does not establish that the reported Mac's fan, repeated work or pointer stalls are fixed. The user's installed revision is unknown. Synthetic chunk-scale tests do not reproduce that device's workload.

## Findings from the inspected implementation

- `SemanticFileChangePlan.make` turns any in-scope directory structural event into a full scan. Events inside the index/model directory are excluded from this rescan branch. Ancestor events can still request a full scan. There is no affected-subtree discovery queue.
- `receiveChanges` coalesces file paths in a set and uses a 150 ms debounce after indexing. A directory event sets `dirty`; reconciliation then calls `start(force: true)`, replacing the lifecycle, watcher, query worker and metadata validator. The active document scheduler also consumes a document scan request, so a structural event can cause both an immediate document discovery and a subsequent full discovery.
- The pending unique-file set has no explicit event-memory backpressure. Media extraction writes a private snapshot under the system temporary directory, outside the index-directory exclusion. If a configured scope includes that directory, generated media writes are another event-feedback case to test. This conditional source-code finding does not identify the user's configured scope or incident cause.
- A full discovery does not itself delete compatible completed document vectors. `beginDiscovery` retains job checkpoints; `prepareDocument` compares metadata version and extraction recipe, and `mediaUnchanged` checks committed provenance. The screenshot's scan denominator cannot identify how many vectors were actually recomputed.
- A model profile mismatch resets incompatible data; a document/media recipe change invalidates the relevant job. These are distinct operations from ordinary metadata revalidation, but the current progress summary does not expose their causes or independent reuse/extraction/inference counts.
- This patch's Unicode FTS recipe migration rebuilds lexical terms in one transaction on initialization while preserving vectors. Its one-time large-existing-index cost is not measured by the fresh scale fixture, and it has no resumable migration budget/progress. It also needs attention under the additional background-resource contract; preserving vectors does not make a lexical rebuild free.
- Work is primarily serial: one durable work queue, up to eight document chunks per encoding request, bounded text extraction and staged media segments. The current helper uses all GPU layers. Serial files and lower QoS do not impose a GPU/memory-bandwidth duty cycle.
- The pause gate checks manual pause, foreground voice, power/thermal policy and active semantic queries. It has no memory-pressure hysteresis, ordinary keyboard/pointer activity budget, maximum active-work duty cycle, or published resource-wait reason. Some reader/helper calls can continue until their existing cancellation/timeout boundary. Pausing between batches does not guarantee immediate helper release.
- The new resident Float16 query snapshot halves matrix representation bytes relative to Float32, but adds resident memory compared with the baseline's streaming reader. It therefore needs a memory-pressure/release policy before a low-memory safety claim.

## Evidence boundaries

The retained Release matrix measures committed native editor input to body publication/drawing, descendants' sampled RSS, actual document inference throughput and real SenseVoice contention. It records external compiler/test activity, and later runs include host swap and free disk before/after. The host is shared. Host swap already in use cannot be attributed to this app. The two-file base and optional synthetic writer do not represent the user's many-file event load.

These runs do not measure physical pointer delivery, compositor latency, GPU occupancy/power, per-process disk I/O or a 15-minute active document/image/audio/video steady state. Thermal/power policy is deliberately overridden for the isolated latency fixture. The heartbeat metric is not a substitute for system interaction evidence.

## Open acceptance work

No background duty-cycle/pressure-controller implementation, privacy-safe run diagnostics, affected-subtree event scheduling or progress-copy change is included in this patch. The added resource requirements remain unfulfilled. They must not be accepted on the strength of the query latency or coverage results.

A follow-up technical adjustment needs to keep resumable checkpoints, distinguish metadata reuse from actual extraction/encoding, suppress index/cache feedback events, and budget discovery, extraction and individual inference calls. Defaults need reference-device measurements while valid indexing continues, with cancellation, activity/query/voice preemption and hysteresis tested before final coverage. The required same-host steady-state input/resource comparison remains an acceptance gate, not optional future polish.
