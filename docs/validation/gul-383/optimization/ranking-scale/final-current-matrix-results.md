Final-source query matrix. Production source recorded in `final-source-head.json`; baseline `262135bc`, current main base `ceeaaef5`. Full command timings and failures are in `matrix-run-final-current*.json` and retained baseline metadata and per-cell command reports. The host is shared, not isolated.

Native input is an actual committed NSTextView edit; drawing uses actual layout/display plus accessibility, not a WindowServer result fence. Scale fixtures contain two files with repeated chunks. Cold readiness/reopening is excluded from the timed edit, and OS caches may remain warm. Real-noise rows repeat an actual geology embedding. Actual contention adds 512 real documents and production inference; voice calls actual SenseVoice through the production busy boundary without microphone/hotkey capture.

Recorded cells: 17/24. Complete reports: 17. Failed commands: 0. Missing/failed bodies are retained in each denominator.

| Chunks | Build | Entry | Scenario | Noise | n / missing | p50 / p95 / p99 / max ms | 100k hot limit |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 10000 | before | file-mode | cold | synthetic-controlled | 10 / 0 | 505.35 / 514.69 / 514.69 / 514.69 | reported separately |
| 10000 | before | file-mode | fts-cache | synthetic-controlled | 100 / 0 | 38.00 / 40.50 / 42.91 / 42.91 | reported separately |
| 10000 | before | file-mode | hot-new-semantic | synthetic-controlled | 100 / 0 | 120.26 / 122.88 / 123.08 / 123.08 | reported separately |
| 10000 | before | file-mode | index-writer | synthetic-controlled | 100 / 0 | 38.87 / 46.88 / 134.73 / 134.73 | reported separately |
| 10000 | before | file-mode | semantic-cache | synthetic-controlled | 100 / 0 | 105.64 / 108.56 / 121.33 / 121.33 | reported separately |
| 10000 | before | mixed | cold | synthetic-controlled | 10 / 0 | 790.96 / 838.00 / 838.00 / 838.00 | reported separately |
| 10000 | before | mixed | fts-cache | synthetic-controlled | 100 / 0 | 111.47 / 127.67 / 133.66 / 133.66 | reported separately |
| 10000 | before | mixed | hot-new-semantic | synthetic-controlled | 100 / 0 | 143.53 / 151.68 / 165.34 / 165.34 | reported separately |
| 10000 | before | mixed | index-writer | synthetic-controlled | 100 / 0 | 91.45 / 94.75 / 157.72 / 157.72 | reported separately |
| 10000 | before | mixed | semantic-cache | synthetic-controlled | 100 / 0 | 133.49 / 562.39 / 13457.53 / 13457.53 | reported separately |
| 10000 | after | file-mode | cold | synthetic-controlled | 10 / 0 | 538.61 / 547.05 / 547.05 / 547.05 | reported separately |
| 10000 | after | file-mode | fts-cache | synthetic-controlled | 100 / 0 | 54.83 / 59.00 / 63.38 / 63.38 | reported separately |
| 10000 | after | file-mode | hot-new-semantic | synthetic-controlled | 100 / 0 | 132.87 / 137.06 / 138.40 / 138.40 | reported separately |
| 10000 | after | file-mode | index-writer | synthetic-controlled | 100 / 0 | 55.56 / 59.43 / 82.79 / 82.79 | reported separately |
| 10000 | after | file-mode | semantic-cache | synthetic-controlled | 100 / 0 | 118.83 / 131.79 / 150.83 / 150.83 | reported separately |
| 10000 | after | mixed | cold | synthetic-controlled | 10 / 0 | 825.92 / 1282.09 / 1282.09 / 1282.09 | reported separately |
| 10000 | after | mixed | fts-cache | synthetic-controlled | 100 / 0 | 110.38 / 129.65 / 135.82 / 135.82 | reported separately |
| 10000 | after | mixed | hot-new-semantic | synthetic-controlled | 100 / 0 | 149.67 / 182.80 / 195.52 / 195.52 | reported separately |
| 10000 | after | mixed | index-writer | synthetic-controlled | 100 / 0 | 83.14 / 88.34 / 134.94 / 134.94 | reported separately |
| 10000 | after | mixed | semantic-cache | synthetic-controlled | 100 / 0 | 165.23 / 184.79 / 194.05 / 194.05 | reported separately |
| 10000 | before | file-mode | cold-fts | synthetic-controlled | 10 / 0 | 55.25 / 59.72 / 59.72 / 59.72 | reported separately |
| 10000 | before | mixed | cold-fts | synthetic-controlled | 10 / 0 | 98.88 / 124.76 / 124.76 / 124.76 | reported separately |
| 10000 | after | file-mode | cold-fts | synthetic-controlled | 10 / 0 | 70.26 / 73.03 / 73.03 / 73.03 | reported separately |
| 10000 | after | mixed | cold-fts | synthetic-controlled | 10 / 0 | 113.92 / 950.67 / 950.67 / 950.67 | reported separately |
| 10000 | before | file-mode | hot-new-semantic | actual-geology-embedding | 100 / 0 | 121.70 / 126.35 / 131.97 / 131.97 | reported separately |
| 10000 | before | mixed | hot-new-semantic | actual-geology-embedding | 100 / 0 | 150.96 / 171.49 / 1878.80 / 1878.80 | reported separately |
| 10000 | after | file-mode | hot-new-semantic | actual-geology-embedding | 100 / 0 | 136.30 / 143.06 / 148.63 / 148.63 | reported separately |
| 10000 | after | mixed | hot-new-semantic | actual-geology-embedding | 100 / 0 | 153.12 / 164.79 / 194.10 / 194.10 | reported separately |
| 10000 | before | file-mode | fts-real-index | synthetic-base-plus-real-index | 100 / 0 | 38.12 / 40.40 / 49.22 / 49.22 | reported separately |
| 10000 | before | file-mode | semantic-real-index | synthetic-base-plus-real-index | 100 / 0 | 158.11 / 170.48 / 242.90 / 242.90 | reported separately |
| 10000 | before | file-mode | voice-idle | synthetic-base-plus-real-index | 10 / 0 | 570.62 / 658.49 / 658.49 / 658.49 | reported separately |
| 10000 | before | file-mode | voice-preempt-index | synthetic-base-plus-real-index | 10 / 0 | 585.30 / 677.18 / 677.18 / 677.18 | reported separately |
| 10000 | before | mixed | fts-real-index | synthetic-base-plus-real-index | 100 / 0 | 94.25 / 98.88 / 122.69 / 122.69 | reported separately |
| 10000 | before | mixed | semantic-real-index | synthetic-base-plus-real-index | 100 / 0 | 198.67 / 210.57 / 225.46 / 225.46 | reported separately |
| 10000 | before | mixed | voice-idle | synthetic-base-plus-real-index | 10 / 0 | 560.26 / 838.85 / 838.85 / 838.85 | reported separately |
| 10000 | before | mixed | voice-preempt-index | synthetic-base-plus-real-index | 10 / 0 | 577.47 / 585.67 / 585.67 / 585.67 | reported separately |
| 10000 | after | file-mode | fts-real-index | synthetic-base-plus-real-index | 100 / 0 | 56.64 / 59.82 / 84.99 / 84.99 | reported separately |
| 10000 | after | file-mode | semantic-real-index | synthetic-base-plus-real-index | 100 / 0 | 133.30 / 136.18 / 156.64 / 156.64 | reported separately |
| 10000 | after | file-mode | voice-idle | synthetic-base-plus-real-index | 10 / 0 | 564.23 / 569.45 / 569.45 / 569.45 | reported separately |
| 10000 | after | file-mode | voice-preempt-index | synthetic-base-plus-real-index | 10 / 0 | 562.28 / 567.42 / 567.42 / 567.42 | reported separately |
| 10000 | after | mixed | fts-real-index | synthetic-base-plus-real-index | 100 / 0 | 86.04 / 103.97 / 131.06 / 131.06 | reported separately |
| 10000 | after | mixed | semantic-real-index | synthetic-base-plus-real-index | 100 / 0 | 160.22 / 165.09 / 174.37 / 174.37 | reported separately |
| 10000 | after | mixed | voice-idle | synthetic-base-plus-real-index | 10 / 0 | 575.99 / 761.04 / 761.04 / 761.04 | reported separately |
| 10000 | after | mixed | voice-preempt-index | synthetic-base-plus-real-index | 10 / 0 | 572.51 / 579.79 / 579.79 / 579.79 | reported separately |
| 100000 | before | file-mode | cold | synthetic-controlled | 10 / 0 | 589.87 / 599.14 / 599.14 / 599.14 | reported separately |
| 100000 | before | file-mode | fts-cache | synthetic-controlled | 100 / 0 | 38.18 / 39.69 / 40.73 / 40.73 | reported separately |
| 100000 | before | file-mode | hot-new-semantic | synthetic-controlled | 100 / 0 | 219.06 / 271.73 / 415.90 / 415.90 | reported separately |
| 100000 | before | file-mode | index-writer | synthetic-controlled | 100 / 0 | 38.92 / 114.48 / 176.68 / 176.68 | reported separately |
| 100000 | before | file-mode | semantic-cache | synthetic-controlled | 100 / 0 | 202.23 / 225.20 / 300.61 / 300.61 | reported separately |
| 100000 | before | mixed | cold | synthetic-controlled | 10 / 0 | 620.25 / 671.25 / 671.25 / 671.25 | reported separately |
| 100000 | before | mixed | fts-cache | synthetic-controlled | 100 / 0 | 90.74 / 92.68 / 93.85 / 93.85 | reported separately |
| 100000 | before | mixed | hot-new-semantic | synthetic-controlled | 100 / 0 | 240.44 / 252.97 / 369.98 / 369.98 | reported separately |
| 100000 | before | mixed | index-writer | synthetic-controlled | 100 / 0 | 90.42 / 92.60 / 147.56 / 147.56 | reported separately |
| 100000 | before | mixed | semantic-cache | synthetic-controlled | 100 / 0 | 232.59 / 236.39 / 354.52 / 354.52 | reported separately |
| 100000 | after | file-mode | cold | synthetic-controlled | 10 / 0 | 698.39 / 744.92 / 744.92 / 744.92 | reported separately |
| 100000 | after | file-mode | fts-cache | synthetic-controlled | 100 / 0 | 54.70 / 58.86 / 60.97 / 60.97 | 100 ms: pass |
| 100000 | after | file-mode | hot-new-semantic | synthetic-controlled | 100 / 0 | 140.89 / 145.92 / 146.74 / 146.74 | 300 ms: pass |
| 100000 | after | file-mode | index-writer | synthetic-controlled | 100 / 0 | 54.39 / 58.86 / 60.05 / 60.05 | 100 ms: pass |
| 100000 | after | file-mode | semantic-cache | synthetic-controlled | 100 / 0 | 126.76 / 133.82 / 141.25 / 141.25 | reported separately |
| 100000 | after | mixed | cold | synthetic-controlled | 10 / 0 | 737.04 / 755.69 / 755.69 / 755.69 | reported separately |
| 100000 | after | mixed | fts-cache | synthetic-controlled | 100 / 0 | 84.10 / 85.86 / 89.40 / 89.40 | 100 ms: pass |
| 100000 | after | mixed | hot-new-semantic | synthetic-controlled | 100 / 0 | 155.15 / 160.49 / 166.38 / 166.38 | 300 ms: pass |
| 100000 | after | mixed | index-writer | synthetic-controlled | 100 / 0 | 80.34 / 87.60 / 92.86 / 92.86 | 100 ms: pass |
| 100000 | after | mixed | semantic-cache | synthetic-controlled | 100 / 0 | 141.81 / 146.08 / 163.99 / 163.99 | reported separately |
| 100000 | before | file-mode | cold-fts | synthetic-controlled | 10 / 0 | 55.03 / 59.75 / 59.75 / 59.75 | reported separately |
| 100000 | before | mixed | cold-fts | synthetic-controlled | 10 / 0 | 99.20 / 124.46 / 124.46 / 124.46 | reported separately |
| 100000 | after | file-mode | cold-fts | synthetic-controlled | 10 / 0 | 70.06 / 70.64 / 70.64 / 70.64 | reported separately |
| 100000 | after | mixed | cold-fts | synthetic-controlled | 10 / 0 | 111.87 / 138.16 / 138.16 / 138.16 | reported separately |
| 100000 | before | file-mode | hot-new-semantic | actual-geology-embedding | 100 / 0 | 220.51 / 225.88 / 230.93 / 230.93 | reported separately |
| 100000 | before | mixed | hot-new-semantic | actual-geology-embedding | 100 / 0 | 252.74 / 259.12 / 269.04 / 269.04 | reported separately |
| 100000 | after | file-mode | hot-new-semantic | actual-geology-embedding | 100 / 0 | 158.61 / 171.56 / 189.62 / 189.62 | 300 ms: pass |
| 100000 | after | mixed | hot-new-semantic | actual-geology-embedding | 100 / 0 | 175.62 / 184.74 / 198.08 / 198.08 | 300 ms: pass |
| 100000 | before | file-mode | fts-real-index | synthetic-base-plus-real-index | 100 / 0 | 38.18 / 40.29 / 51.12 / 51.12 | reported separately |
| 100000 | before | file-mode | semantic-real-index | synthetic-base-plus-real-index | 100 / 0 | 272.08 / 395.54 / 860.88 / 860.88 | reported separately |
| 100000 | before | file-mode | voice-idle | synthetic-base-plus-real-index | 10 / 0 | 600.98 / 1244.42 / 1244.42 / 1244.42 | reported separately |
| 100000 | before | file-mode | voice-preempt-index | synthetic-base-plus-real-index | 10 / 0 | 871.08 / 1038.80 / 1038.80 / 1038.80 | reported separately |
| 100000 | before | mixed | fts-real-index | synthetic-base-plus-real-index | 100 / 0 | 95.53 / 107.66 / 154.71 / 154.71 | reported separately |
| 100000 | before | mixed | semantic-real-index | synthetic-base-plus-real-index | 100 / 0 | 298.31 / 483.67 / 653.26 / 653.26 | reported separately |
| 100000 | before | mixed | voice-idle | synthetic-base-plus-real-index | 10 / 0 | 582.95 / 894.05 / 894.05 / 894.05 | reported separately |
| 100000 | before | mixed | voice-preempt-index | synthetic-base-plus-real-index | 10 / 0 | 596.04 / 604.12 / 604.12 / 604.12 | reported separately |
| 100000 | after | file-mode | fts-real-index | synthetic-base-plus-real-index | 100 / 0 | 50.63 / 70.49 / 105.40 / 105.40 | 100 ms: pass |
| 100000 | after | file-mode | semantic-real-index | synthetic-base-plus-real-index | 100 / 0 | 147.03 / 160.94 / 166.34 / 166.34 | 300 ms: pass |
| 100000 | after | file-mode | voice-idle | synthetic-base-plus-real-index | 10 / 0 | 596.49 / 805.58 / 805.58 / 805.58 | reported separately |
| 100000 | after | file-mode | voice-preempt-index | synthetic-base-plus-real-index | 10 / 0 | 618.32 / 796.25 / 796.25 / 796.25 | reported separately |
| 100000 | after | mixed | fts-real-index | synthetic-base-plus-real-index | 100 / 0 | 127.27 / 169.80 / 308.92 / 308.92 | 100 ms: FAIL |
| 100000 | after | mixed | semantic-real-index | synthetic-base-plus-real-index | 100 / 0 | 238.94 / 746.12 / 1227.44 / 1227.44 | 300 ms: FAIL |
| 100000 | after | mixed | voice-idle | synthetic-base-plus-real-index | 10 / 0 | 720.50 / 1307.69 / 1307.69 / 1307.69 | reported separately |
| 100000 | after | mixed | voice-preempt-index | synthetic-base-plus-real-index | 10 / 0 | 678.64 / 703.42 / 703.42 / 703.42 | reported separately |
| 1000000 | before | file-mode | cold | synthetic-controlled | 10 / 0 | 6684.37 / 14865.29 / 14865.29 / 14865.29 | reported separately |
| 1000000 | before | file-mode | fts-cache | synthetic-controlled | 20 / 0 | 39.21 / 86.78 / 86.78 / 86.78 | reported separately |
| 1000000 | before | file-mode | hot-new-semantic | synthetic-controlled | 20 / 0 | 12258.62 / 16069.27 / 16069.27 / 16069.27 | reported separately |
| 1000000 | before | file-mode | index-writer | synthetic-controlled | 20 / 0 | 43.20 / 159.61 / 159.61 / 159.61 | reported separately |
| 1000000 | before | file-mode | semantic-cache | synthetic-controlled | 20 / 0 | 10615.92 / 17525.83 / 17525.83 / 17525.83 | reported separately |
| 1000000 | before | mixed | cold | synthetic-controlled | 10 / 0 | 12329.41 / 14757.28 / 14757.28 / 14757.28 | reported separately |
| 1000000 | before | mixed | fts-cache | synthetic-controlled | 20 / 0 | 91.78 / 124.81 / 124.81 / 124.81 | reported separately |
| 1000000 | before | mixed | hot-new-semantic | synthetic-controlled | 20 / 0 | 16295.66 / 39076.20 / 39076.20 / 39076.20 | reported separately |
| 1000000 | before | mixed | index-writer | synthetic-controlled | 20 / 0 | 90.70 / 352.10 / 352.10 / 352.10 | reported separately |
| 1000000 | before | mixed | semantic-cache | synthetic-controlled | 20 / 0 | 12626.08 / 13672.46 / 13672.46 / 13672.46 | reported separately |

Voice rows show ASR completion, not body drawing. FTS-during-voice, observed batch counters, transcript failures and per-sample timing remain in the JSON. An observer-active interval includes worker startup/interruption; it is not a hardware inference-kernel trace. Main-thread gaps include accessibility/polling work and cannot replace desktop-response evidence.

Every per-cell resource folder retains adjacent-process CPU/IO inputs and external compiler/test presence. Summed RSS double-counts shared pages. Privileged energy metrics and physical monitor/HID latency are unavailable. This matrix does not establish the original user incident root cause.
