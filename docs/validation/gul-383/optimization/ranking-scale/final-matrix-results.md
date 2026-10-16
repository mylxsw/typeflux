Final-source query matrix. Production source `1265fea7`; baseline `262135bc`, current main base `ceeaaef5`. Full command timings and failures are in `matrix-run-final.json` and per-cell command reports. The host is shared, not isolated.

Native input is an actual committed NSTextView edit; drawing uses actual layout/display plus accessibility, not a WindowServer result fence. Scale fixtures contain two files with repeated chunks. Cold readiness/reopening is excluded from the timed edit, and OS caches may remain warm. Real-noise rows repeat an actual geology embedding. Actual contention adds 512 real documents and production inference; voice calls actual SenseVoice through the production busy boundary without microphone/hotkey capture.

Recorded cells: 7/24. Complete reports: 7. Failed commands: 1. Missing/failed bodies are retained in each denominator.

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
| 10000 | after | file-mode | cold | synthetic-controlled | 10 / 0 | 537.71 / 548.15 / 548.15 / 548.15 | reported separately |
| 10000 | after | file-mode | fts-cache | synthetic-controlled | 100 / 0 | 55.48 / 59.34 / 71.46 / 71.46 | reported separately |
| 10000 | after | file-mode | hot-new-semantic | synthetic-controlled | 100 / 0 | 132.59 / 141.17 / 160.20 / 160.20 | reported separately |
| 10000 | after | file-mode | index-writer | synthetic-controlled | 100 / 0 | 54.77 / 58.99 / 62.43 / 62.43 | reported separately |
| 10000 | after | file-mode | semantic-cache | synthetic-controlled | 100 / 0 | 119.35 / 128.80 / 136.93 / 136.93 | reported separately |
| 10000 | after | mixed | cold | synthetic-controlled | 10 / 0 | 573.56 / 702.71 / 702.71 / 702.71 | reported separately |
| 10000 | after | mixed | fts-cache | synthetic-controlled | 100 / 0 | 83.37 / 85.67 / 86.71 / 86.71 | reported separately |
| 10000 | after | mixed | hot-new-semantic | synthetic-controlled | 100 / 0 | 182.35 / 204.46 / 232.64 / 232.64 | reported separately |
| 10000 | after | mixed | index-writer | synthetic-controlled | 100 / 0 | 85.96 / 124.99 / 430.17 / 430.17 | reported separately |
| 10000 | after | mixed | semantic-cache | synthetic-controlled | 100 / 0 | 134.70 / 140.87 / 276.53 / 276.53 | reported separately |
| 10000 | before | file-mode | cold-fts | synthetic-controlled | 10 / 0 | 55.25 / 59.72 / 59.72 / 59.72 | reported separately |
| 10000 | before | mixed | cold-fts | synthetic-controlled | 10 / 0 | 98.88 / 124.76 / 124.76 / 124.76 | reported separately |
| 10000 | after | file-mode | cold-fts | synthetic-controlled | 10 / 0 | 70.35 / 76.24 / 76.24 / 76.24 | reported separately |
| 10000 | after | mixed | cold-fts | synthetic-controlled | 10 / 0 | 112.55 / 133.61 / 133.61 / 133.61 | reported separately |
| 10000 | before | file-mode | hot-new-semantic | actual-geology-embedding | 100 / 0 | 121.70 / 126.35 / 131.97 / 131.97 | reported separately |
| 10000 | before | mixed | hot-new-semantic | actual-geology-embedding | 100 / 0 | 150.96 / 171.49 / 1878.80 / 1878.80 | reported separately |
| 10000 | after | file-mode | hot-new-semantic | actual-geology-embedding | 100 / 0 | 137.02 / 140.02 / 142.44 / 142.44 | reported separately |
| 10000 | after | mixed | hot-new-semantic | actual-geology-embedding | 100 / 2 | 154.76 / 169.14 / 633.06 / 633.06 | reported separately |
| 10000 | before | file-mode | fts-real-index | synthetic-controlled | 100 / 0 | 38.12 / 40.40 / 49.22 / 49.22 | reported separately |
| 10000 | before | file-mode | semantic-real-index | synthetic-controlled | 100 / 0 | 158.11 / 170.48 / 242.90 / 242.90 | reported separately |
| 10000 | before | file-mode | voice-idle | synthetic-controlled | 10 / 0 | 570.62 / 658.49 / 658.49 / 658.49 | reported separately |
| 10000 | before | file-mode | voice-preempt-index | synthetic-controlled | 10 / 0 | 585.30 / 677.18 / 677.18 / 677.18 | reported separately |
| 10000 | before | mixed | fts-real-index | synthetic-controlled | 100 / 0 | 94.25 / 98.88 / 122.69 / 122.69 | reported separately |
| 10000 | before | mixed | semantic-real-index | synthetic-controlled | 100 / 0 | 198.67 / 210.57 / 225.46 / 225.46 | reported separately |
| 10000 | before | mixed | voice-idle | synthetic-controlled | 10 / 0 | 560.26 / 838.85 / 838.85 / 838.85 | reported separately |
| 10000 | before | mixed | voice-preempt-index | synthetic-controlled | 10 / 0 | 577.47 / 585.67 / 585.67 / 585.67 | reported separately |

Voice rows show ASR completion, not body drawing. FTS-during-voice, observed batch counters, transcript failures and per-sample timing remain in the JSON. An observer-active interval includes worker startup/interruption; it is not a hardware inference-kernel trace. Main-thread gaps include accessibility/polling work and cannot replace desktop-response evidence.

Every per-cell resource folder retains adjacent-process CPU/IO inputs and external compiler/test presence. Summed RSS double-counts shared pages. Privileged energy metrics and physical monitor/HID latency are unavailable. This matrix does not establish the original user incident root cause.
