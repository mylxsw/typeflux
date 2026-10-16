Frozen production source `3c3de617`; this handoff changes only two test preparations and evidence. Existing product coverage remains valid. Current Release build/discovery took 448.16 seconds; no 221-method regression, baseline, ranking, cold or million-scale run was executed.

ON and all 400 hot samples completed. Contention was canceled for the 20-minute checkpoint; its partial groups do not satisfy the 100-per-entry/scenario requirement.

| Entry | Scenario | n / expected | Complete | p50 / p95 / p99 / max draw ms |
| --- | --- | --- | --- | --- |
| mixed | fts-cache | 100/100 | True | 81.11 / 85.26 / 143.54 / 143.54 |
| file-mode | fts-cache | 100/100 | True | 44.15 / 48.34 / 72.03 / 72.03 |
| mixed | hot-new-semantic | 100/100 | True | 157.26 / 160.03 / 193.44 / 193.44 |
| file-mode | hot-new-semantic | 100/100 | True | 129.10 / 132.86 / 136.00 / 136.00 |
| mixed | fts-real-index | 100/100 | False | 81.65 / 84.30 / 111.02 / 111.02 |
| mixed | semantic-real-index | 55/100 | False | 160.77 / 163.38 / 165.57 / 165.57 |

ON lasted 303.06 s: 302 inputs, zero missing handlers/presentations, merged p95 30.84 ms and max 215.31 ms. Published 105 vectors / 235 chunks with all four modalities and zero failed jobs; 130 vectors remain pending and raw queues remain nonempty. Effective throughput 0.346 vectors/s. This is short progress evidence, not long-term load stability.
Observed CPU lower bound 40.53% of one core; peak summed RSS 2.22 GiB (shared pages overlap). External compiler processes occurred in 45 samples. Raw GPU, pressure, swap, physical IO, thermal and per-process metrics are retained. Historical OFF remains a reference from earlier source, not a paired measurement.

Query boundaries are committed NSTextView input to production publication and layout/accessibility drawing, not a WindowServer query-result fence. The 100k corpus repeats synthetic noise plus one real passage. Contention uses actual document inference through an observer adapter; cancellation partials remain unaccepted. The independent resource probe measures CGEvent.postToPid through an own-window WindowServer pixel observation, not physical HID/monitor scanout. Helper/model/probe fingerprints match the retained artifacts; all Release products and frozen production source have fingerprints.

Self-review: the ON selector preserves default OFF/ON behavior; the inert contention watcher now uses explicit rescan outside input timing because normal startup reuses discovery. No product changes or tuning. Remaining required verification: rerun only the 100k real-index contention cell, both entries and both scenarios, 100 samples each, using this already built artifact. Do not repeat completed ON/hot cells.
