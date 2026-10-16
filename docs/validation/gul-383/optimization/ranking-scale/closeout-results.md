Current integration handoff: [reviewed-main integration](integration-main-b463/results.md). The measurements below describe the earlier production source.

GUL-404 closeout under the current issue policy (2026-10-17)

Production source is frozen at `6a9c18d79561b49d8c5339754193c6a06ee79374`. This closeout changes only the test duration/completeness checks and evidence. It stops the cancelled million-scale matrix and performs no ranking tuning, new holdout, repeated baseline or full test run.

The existing focused coverage remains application **2264/2460 changed executable lines (92.03%)**, helper **38/38 (100%)**, measured against main `ceeaaef5`. Files and uncovered lines are in the LCOV/coverage reports; this is not whole-project coverage. Production source/model/helper fingerprints match the retained measurements. The latest home/capture/native-entry coverage ran67 tests in6 suites in91.945seconds; the preceding missing-test-helper build failed in276.154seconds and remains retained. Earlier budget/event/migration/cancellation/recovery focused passes and failures remain in the history archive.

| 100k chunks, p95 ms | Mixed entry | File entry | Current policy |
| --- | --- | --- | --- |
| Hot body FTS | 85.86 | 58.86 | 100ms target |
| Hot non-cached semantic, controlled noise | 160.49 | 145.92 | 300ms target |
| Hot non-cached semantic, real geology embedding noise | 184.74 | 171.56 | 300ms target |
| Body during real indexing | 169.80 | 70.49 | 200ms temporary contention limit |
| Semantic during real indexing | 746.12 | 160.94 | 800ms temporary contention limit |

Each listed hot/contended stratum contains100 queries per entry with no missing body. Contention passes the newly relaxed limit; the mixed entry does **not** meet the original100/300ms targets. External compiler/test processes appeared in129/136 contention resource samples, so these shared-host timings are not an isolated causal estimate. Input is an actual committed NSTextView edit to layout/display+accessibility, not a physical-HID or query-result WindowServer fence. The scale fixture repeats chunks in two files; real contention adds real document extraction/inference. Raw rows retain p50/p95/p99/max, complete time and failed earlier candidates.

All five frozen200-query cohorts remain intact. No-answer total is3/125 (2.4%); the rework-frozen subgroup remains2/25 (8%), disclosed under the current exception. Minimum supported-group Recall@5 is96%; Chinese-short, identifier and lexical groups retain full recall. Exact-source semantic MRR1.00→0.94 remains a disclosed equivalent-source limitation. New results do not erase earlier failed rows, and this closeout does not retune parameters.

The 300-second-per-condition native resource report is collected separately in `resource-after-closeout-300/`. It measures actual text/PNG/WAV/MOV indexing and independent own-window generated mouse/keyboard/window events to WindowServer event-ID pixels. It is a short controlled comparison, not a27k-file representative corpus, physical monitor/HID test, query-result compositor measurement or long-term thermal proof. GPU counters are system-wide best effort; energy and per-process GPU power are unavailable. The original user incident build and cause remain unknown.

The original extraction oracle's earlier88-file attempt omitted12 supported WAV fixtures. The corrected generator and100-supported-file/audio-timestamp assertions are preserved, but that full oracle is intentionally not rerun in this closeout. Unsupported25 scanned-PDF cases and the incomplete attempt remain explicit limitations.

Self-review covered event cursor/ACK durability, unchanged-file reuse, migration checkpoints/old-writer compatibility, cancellation/generation checks, fresh permissions, helper/process ownership, pressure recovery, diagnostics privacy and five locale labels. It previously fixed buffer lifetime, ownership, FTS recovery and repeated permission-read defects. This closeout's duration guard remains finite and at least300seconds, while probe liveness, exit status, cleanup and raw observations are preserved.

Latest-main compatibility is a separate integration blocker: `closeout-main-audit.json` records the exact fetched main and conflict paths. Main has concurrent semantic supervision/lifecycle protections. No merge/rebase or wholesale conflict resolution was attempted during this bounded run; final coverage/resource claims apply to the pinned production source, not an untested combined main. The new PR must be reviewed and integrated before merge; PR551's externally merged headf22a1950/merge185d6f85 does not include these six rework commits. This agent performs no merge or next-stage dispatch.

Short resource result (300seconds requested per condition;303seconds observed including probe completion):

| Condition | Keyboard p50/p95/p99/max ms | Mouse p50/p95/p99/max ms | Window p50/p95/p99/max ms |
| --- | --- | --- | --- |
| index-off | 17.21/33.26/185.62/185.62 | 17.06/32.43/65.00/66.94 | 20.30/36.59/100.05/106.88 |
| index-on | 23.07/24.84/425.16/425.16 | 22.62/24.09/472.03/589.33 | 23.64/38.78/160.43/309.29 |

Each condition retained302 input events (100keyboard,101mouse,101window), all handled and displayed in valid window context. The ON maximum was589.33ms; no≥1second sample occurred. Producer maximum delay was below1.14ms. ON published92 vectors/205 chunks, completed8 jobs, kept10partial jobs and113pending vectors, with0failed jobs:0.304vectors/s and0.0264completed jobs/s. Backlog grew under the supplied40-file workload; this proves progress, not capacity to match arrivals.

Observed owned CPU lower-bound mean OFF/ON was1.53/40.07% of one core. ON sum RSS/footprint peaks were2242.72/1536.82MiB; shared pages overlap. Global GPU p95 was1% in both phases, maximum8%; watts/energy/per-process GPU attribution are unavailable. Memory pressure stayednominal and ProcessInfo thermal state0. Global swap went3569.69→3553.69MiB OFF and3553.69→3545.69MiB ON, with no observed growth. Per-process physical IO and CPU counters remain in summary.json.

External compiler/test presence was51/143samples OFF and0/142 ON. A separate non-benchmark Typeflux app was also present on the shared host; its activity is not attributed to the benchmark. No owned build, other model/UI experiment or plotting overlapped the timed conditions; only small text/JSON evidence reads/edits occurred. Raw sampling includes global system effects and misses short-lived process tails. These asymmetries prevent isolated causal attribution.

This closeout ran one focused resource test successfully (608.89seconds whole command) after one current-only Release build/discovery (87.47seconds). A report-analysis call initially used the wrong relative folder; it was corrected without rerunning any experiment. All failure/history files are retained.
