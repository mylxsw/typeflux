# Release scale comparison

Primary matrix: the after variant is source-hashes-before-candidate-guard.json. Current-source ranking parity and real-model hot probes are separate in candidate-guard-summary.md; this table is not a full final-binary matrix. Apple M4 / 16 GiB, pinned Q8 weights, Release. Native input means a committed NSTextView edit; drawing means forced layout/display plus rendered accessibility observation, not a compositor fence. Filename search returns no hits and surrounding conversation/app providers use the existing test fixture. This isolates body retrieval and does not measure installed-app startup or physical event delivery. The host is shared.

Each cell is p50 / p95 / p99 in milliseconds. Cold has 10 samples per entry; warm has 100 at 10k/100k and 20 at 1m; semantic-cache reuse excludes its separately reported first fill (99 or 19 reuse samples). The 1m p95/p99 estimates have limited precision. Terminal queries without the expected body remain in the denominator as unbounded latency. `unbounded` does not mean zero. Complete capture does not imply passing tests.

## Initial 10,000 chunks

The controlled base has two files: one real winning document vector and repeated orthogonal noise. The real-model supplement instead repeats an actual geology embedding with matching stored text and FTS terms. This still has only two independent source documents. Real background indexing grows the corpus during contention; end counts are listed below. These are chunk-scale stress results, not million-file or representative-corpus quality evidence.

| Entry / scenario | Before | After |
| --- | --- | --- |
| mixed/cold | 523.51 / 539.19 / 539.19 (n=10, unavailable=0) | 543.54 / 2218.68 / 2218.68 (n=10, unavailable=0) |
| mixed/cold-fts | 112.92 / 384.09 / 384.09 (n=10, unavailable=0) | 116.98 / 158.78 / 158.78 (n=10, unavailable=0) |
| mixed/fts-cache | 87.11 / 89.69 / 91.75 (n=100, unavailable=0) | 74.69 / 77.16 / 81.95 (n=100, unavailable=0) |
| mixed/semantic-cache-fill | 145.81 / 145.81 / 145.81 (n=1, unavailable=0) | 141.03 / 141.03 / 141.03 (n=1, unavailable=0) |
| mixed/semantic-cache | 128.76 / 130.86 / 132.00 (n=99, unavailable=0) | 122.53 / 125.10 / 137.76 (n=99, unavailable=0) |
| mixed/hot-new-semantic | 139.88 / 145.05 / 145.76 (n=100, unavailable=0) | 134.86 / 140.04 / 143.29 (n=100, unavailable=0) |
| mixed/real-model-hot-new-semantic | 150.08 / 168.52 / 195.42 (n=100, unavailable=0) | 144.08 / 146.50 / 148.91 (n=100, unavailable=0) |
| mixed/index-writer | 87.31 / 89.23 / 91.07 (n=100, unavailable=0) | 75.07 / 77.19 / 77.59 (n=100, unavailable=0) |
| mixed/fts-real-index | 94.19 / 145.08 / 302.00 (n=100, unavailable=0) | 83.84 / 120.69 / 147.53 (n=100, unavailable=0) |
| mixed/semantic-real-index | 200.07 / 206.16 / 208.83 (n=100, unavailable=0) | 224.87 / 355.40 / 1146.81 (n=100, unavailable=0) |
| file-mode/cold | 492.66 / 505.94 / 505.94 (n=10, unavailable=0) | 512.17 / 519.22 / 519.22 (n=10, unavailable=0) |
| file-mode/cold-fts | 55.86 / 60.82 / 60.82 (n=10, unavailable=0) | 80.10 / 90.74 / 90.74 (n=10, unavailable=0) |
| file-mode/fts-cache | 37.53 / 40.11 / 40.71 (n=100, unavailable=0) | 37.86 / 39.39 / 39.91 (n=100, unavailable=0) |
| file-mode/semantic-cache-fill | 114.49 / 114.49 / 114.49 (n=1, unavailable=0) | 105.41 / 105.41 / 105.41 (n=1, unavailable=0) |
| file-mode/semantic-cache | 103.91 / 106.50 / 109.33 (n=99, unavailable=0) | 95.44 / 97.66 / 104.22 (n=99, unavailable=0) |
| file-mode/hot-new-semantic | 118.42 / 121.78 / 122.58 (n=100, unavailable=0) | 110.74 / 113.53 / 114.14 (n=100, unavailable=0) |
| file-mode/real-model-hot-new-semantic | 124.75 / 129.86 / 137.42 (n=100, unavailable=0) | 115.34 / 118.79 / 119.43 (n=100, unavailable=0) |
| file-mode/index-writer | 38.06 / 42.57 / 126.75 (n=100, unavailable=0) | 38.48 / 39.98 / 40.41 (n=100, unavailable=0) |
| file-mode/fts-real-index | 38.26 / 41.28 / 46.06 (n=100, unavailable=0) | 53.06 / 80.14 / 143.87 (n=100, unavailable=0) |
| file-mode/semantic-real-index | 156.97 / 171.37 / 173.78 (n=100, unavailable=0) | 239.68 / 335.60 / 444.42 (n=100, unavailable=0) |

### Resources and command wall time

RSS is the sampled resident size by descendant executable name; sums double-count shared pages. `swiftpm-testing-helper` hosts the app under test, while `Typeflux` includes filesystem-worker children. The complete process maps remain in summary.json. External CPU peaks cover the entire command, including preparation; older reports lack an anchor for per-query alignment. They are not proof of query-specific contention or an isolated causal comparison.

| Case | Test exit before → after | Command wall seconds before → after | Peak RSS MiB before → after | External compiler/test CPU peak before → after |
| --- | --- | --- | --- | --- |
| native | 0 → 0 | 538.18 → 568.68 | swiftpm-testing-helper=477.6; TypefluxSemanticHelper=486.4; Typeflux=20.6 → swiftpm-testing-helper=478.2; TypefluxSemanticHelper=492.2; Typeflux=20.6 | 0.0% → 23.5% |
| contention | 0 → 0 | 383.17 → 473.04 | swiftpm-testing-helper=527.5; TypefluxSemanticHelper=973.9; Typeflux=43.7; sherpa-onnx-offline=790.5 → swiftpm-testing-helper=481.2; TypefluxSemanticHelper=1017.2; Typeflux=42.3; sherpa-onnx-offline=884.1 | 156.8% → 918.4% |
| cold-fts | 0 → 0 | 125.24 → 63.18 | swiftpm-testing-helper=491.4; TypefluxSemanticHelper=486.1; Typeflux=19.9 → swiftpm-testing-helper=476.5; TypefluxSemanticHelper=485.6; Typeflux=19.8 | 392.3% → 391.3% |
| real-noise | 0 → 0 | 164.74 → 160.62 | swiftpm-testing-helper=476.1; TypefluxSemanticHelper=485.2; Typeflux=20.4 → swiftpm-testing-helper=478.9; TypefluxSemanticHelper=486.5; Typeflux=20.3 | 473.9% → 0.0% |

| Entry | Native index disk MiB before → after | Contention index disk MiB before → after | Contention chunks at end before → after | Encoded texts / active inference second before → after | Encoded texts / observed wall second before → after |
| --- | --- | --- | --- | --- | --- |
| mixed | 43.23 → 44.39 | 123.55 → 127.25 | 24848 → 24848 | 29.03 → 26.33 | 20.48 → 21.93 |
| file-mode | 44.77 → 46.02 | 74.98 → 76.00 | 16206 → 16322 | 29.19 → 20.21 | 23.75 → 13.35 |

Background throughput counts successfully encoded texts during the observation window, not completed files. There are 512 synthetic geological documents, each 54,400 UTF-8 bytes. Native writer contention is a separate synthetic writer; real-index contention uses the production document queue and helper.

### Actual ASR contention

Each condition has 10 real SenseVoice transcriptions per entry from the same generated 5.5693125-second WAV. Foreground busy is driven at the production service boundary; this is not microphone/hotkey latency. FTS during voice is service completion, not a native draw boundary.

| Entry / condition | ASR before | ASR after | FTS during voice before | FTS during voice after |
| --- | --- | --- | --- | --- |
| mixed/voice-idle | 556.68 / 762.22 / 762.22 (n=10, unavailable=0) | 1115.94 / 1249.85 / 1249.85 (n=10, unavailable=0) | 0.71 / 3.36 / 3.36 (n=10, unavailable=0) | 4.47 / 18.67 / 18.67 (n=10, unavailable=0) |
| mixed/voice-preempt-index | 576.04 / 588.70 / 588.70 (n=10, unavailable=0) | 1218.18 / 1280.53 / 1280.53 (n=10, unavailable=0) | 1.34 / 1.65 / 1.65 (n=10, unavailable=0) | 3.07 / 10.57 / 10.57 (n=10, unavailable=0) |
| file-mode/voice-idle | 563.51 / 642.86 / 642.86 (n=10, unavailable=0) | 1033.59 / 1150.01 / 1150.01 (n=10, unavailable=0) | 0.69 / 1.06 / 1.06 (n=10, unavailable=0) | 2.83 / 8.69 / 8.69 (n=10, unavailable=0) |
| file-mode/voice-preempt-index | 558.24 / 565.36 / 565.36 (n=10, unavailable=0) | 1022.80 / 1148.67 / 1148.67 (n=10, unavailable=0) | 0.67 / 1.20 / 1.20 (n=10, unavailable=0) | 1.59 / 7.48 / 7.48 (n=10, unavailable=0) |

## Initial 100,000 chunks

The controlled base has two files: one real winning document vector and repeated orthogonal noise. The real-model supplement instead repeats an actual geology embedding with matching stored text and FTS terms. This still has only two independent source documents. Real background indexing grows the corpus during contention; end counts are listed below. These are chunk-scale stress results, not million-file or representative-corpus quality evidence.

| Entry / scenario | Before | After |
| --- | --- | --- |
| mixed/cold | 607.52 / 616.05 / 616.05 (n=10, unavailable=0) | 765.89 / 1086.44 / 1086.44 (n=10, unavailable=0) |
| mixed/cold-fts | 102.86 / 195.08 / 195.08 (n=10, unavailable=0) | 96.15 / 125.28 / 125.28 (n=10, unavailable=0) |
| mixed/fts-cache | 86.71 / 88.46 / 97.09 (n=100, unavailable=0) | 71.81 / 75.55 / 78.41 (n=100, unavailable=0) |
| mixed/semantic-cache-fill | 233.88 / 233.88 / 233.88 (n=1, unavailable=0) | 149.66 / 149.66 / 149.66 (n=1, unavailable=0) |
| mixed/semantic-cache | 217.91 / 229.08 / 386.27 (n=99, unavailable=0) | 131.50 / 133.77 / 134.85 (n=99, unavailable=0) |
| mixed/hot-new-semantic | 237.71 / 243.17 / 244.86 (n=100, unavailable=0) | 147.87 / 185.05 / 190.44 (n=100, unavailable=0) |
| mixed/real-model-hot-new-semantic | 254.67 / 348.49 / 478.88 (n=100, unavailable=0) | 224.26 / 249.03 / 316.48 (n=100, unavailable=0) |
| mixed/index-writer | 86.92 / 97.58 / 126.22 (n=100, unavailable=0) | 99.64 / 108.58 / 126.22 (n=100, unavailable=0) |
| mixed/fts-real-index | 118.80 / 166.68 / 343.01 (n=100, unavailable=0) | 80.74 / 91.43 / 94.88 (n=100, unavailable=0) |
| mixed/semantic-real-index | 303.73 / 617.65 / 1193.38 (n=100, unavailable=0) | 220.16 / 313.82 / 323.11 (n=100, unavailable=0) |
| file-mode/cold | 586.94 / 597.77 / 597.77 (n=10, unavailable=0) | 825.22 / 1244.94 / 1244.94 (n=10, unavailable=0) |
| file-mode/cold-fts | 54.42 / 60.63 / 60.63 (n=10, unavailable=0) | 56.39 / 200.24 / 200.24 (n=10, unavailable=0) |
| file-mode/fts-cache | 38.73 / 43.02 / 53.98 (n=100, unavailable=0) | 39.23 / 42.88 / 45.54 (n=100, unavailable=0) |
| file-mode/semantic-cache-fill | 216.20 / 216.20 / 216.20 (n=1, unavailable=0) | 119.83 / 119.83 / 119.83 (n=1, unavailable=0) |
| file-mode/semantic-cache | 235.50 / 286.74 / 539.81 (n=99, unavailable=0) | 109.79 / 115.30 / 121.80 (n=99, unavailable=0) |
| file-mode/hot-new-semantic | 223.37 / 312.82 / 708.59 (n=100, unavailable=0) | 128.22 / 160.72 / 165.60 (n=100, unavailable=0) |
| file-mode/real-model-hot-new-semantic | 236.52 / 540.09 / 2262.92 (n=100, unavailable=0) | 160.28 / 208.36 / 216.92 (n=100, unavailable=0) |
| file-mode/index-writer | 56.89 / 71.01 / 77.08 (n=100, unavailable=0) | 41.60 / 50.84 / 70.34 (n=100, unavailable=0) |
| file-mode/fts-real-index | 38.78 / 45.67 / 94.02 (n=100, unavailable=0) | 60.35 / 74.13 / 85.11 (n=100, unavailable=0) |
| file-mode/semantic-real-index | 279.06 / 407.23 / 639.72 (n=100, unavailable=0) | 231.27 / 292.79 / 333.09 (n=100, unavailable=0) |

### Resources and command wall time

RSS is the sampled resident size by descendant executable name; sums double-count shared pages. `swiftpm-testing-helper` hosts the app under test, while `Typeflux` includes filesystem-worker children. The complete process maps remain in summary.json. External CPU peaks cover the entire command, including preparation; older reports lack an anchor for per-query alignment. They are not proof of query-specific contention or an isolated causal comparison.

| Case | Test exit before → after | Command wall seconds before → after | Peak RSS MiB before → after | External compiler/test CPU peak before → after |
| --- | --- | --- | --- | --- |
| native | 0 → 0 | 627.87 → 616.98 | swiftpm-testing-helper=612.1; TypefluxSemanticHelper=486.7; Typeflux=20.5 → swiftpm-testing-helper=763.5; TypefluxSemanticHelper=493.1; Typeflux=20.5 | 399.4% → 391.7% |
| contention | 0 → 0 | 542.10 → 443.19 | swiftpm-testing-helper=660.7; TypefluxSemanticHelper=981.3; Typeflux=43.6; sherpa-onnx-offline=788.9 → swiftpm-testing-helper=870.0; TypefluxSemanticHelper=1018.3; Typeflux=42.8; sherpa-onnx-offline=880.9 | 392.7% → 393.7% |
| cold-fts | 0 → 0 | 62.67 → 101.19 | swiftpm-testing-helper=611.1; TypefluxSemanticHelper=486.4; Typeflux=19.9 → swiftpm-testing-helper=778.4; TypefluxSemanticHelper=492.7; Typeflux=19.8 | 394.2% → 86.2% |
| real-noise | 0 → 0 | 205.65 → 231.63 | swiftpm-testing-helper=611.2; TypefluxSemanticHelper=488.4; Typeflux=20.4 → swiftpm-testing-helper=765.8; TypefluxSemanticHelper=489.9; Typeflux=20.4 | 391.1% → 806.3% |

| Entry | Native index disk MiB before → after | Contention index disk MiB before → after | Contention chunks at end before → after | Encoded texts / active inference second before → after | Encoded texts / observed wall second before → after |
| --- | --- | --- | --- | --- | --- |
| mixed | 428.26 → 429.50 | 507.53 → 509.64 | 114848 → 114848 | 28.23 → 29.49 | 17.14 → 24.52 |
| file-mode | 428.27 → 431.16 | 458.26 → 459.71 | 106438 → 106293 | 28.44 → 28.10 | 16.08 → 18.73 |

Background throughput counts successfully encoded texts during the observation window, not completed files. There are 512 synthetic geological documents, each 54,400 UTF-8 bytes. Native writer contention is a separate synthetic writer; real-index contention uses the production document queue and helper.

### Actual ASR contention

Each condition has 10 real SenseVoice transcriptions per entry from the same generated 5.5693125-second WAV. Foreground busy is driven at the production service boundary; this is not microphone/hotkey latency. FTS during voice is service completion, not a native draw boundary.

| Entry / condition | ASR before | ASR after | FTS during voice before | FTS during voice after |
| --- | --- | --- | --- | --- |
| mixed/voice-idle | 568.97 / 856.70 / 856.70 (n=10, unavailable=0) | 874.85 / 1061.41 / 1061.41 (n=10, unavailable=0) | 0.73 / 23.75 / 23.75 (n=10, unavailable=0) | 1.25 / 7.17 / 7.17 (n=10, unavailable=0) |
| mixed/voice-preempt-index | 612.70 / 715.93 / 715.93 (n=10, unavailable=0) | 884.42 / 921.60 / 921.60 (n=10, unavailable=0) | 0.67 / 2.54 / 2.54 (n=10, unavailable=0) | 1.35 / 3.53 / 3.53 (n=10, unavailable=0) |
| file-mode/voice-idle | 600.47 / 895.16 / 895.16 (n=10, unavailable=0) | 895.73 / 1058.95 / 1058.95 (n=10, unavailable=0) | 0.79 / 2.87 / 2.87 (n=10, unavailable=0) | 1.61 / 2.66 / 2.66 (n=10, unavailable=0) |
| file-mode/voice-preempt-index | 563.87 / 658.77 / 658.77 (n=10, unavailable=0) | 910.05 / 966.06 / 966.06 (n=10, unavailable=0) | 0.56 / 2.73 / 2.73 (n=10, unavailable=0) | 1.46 / 2.95 / 2.95 (n=10, unavailable=0) |

## Initial 1,000,000 chunks

The controlled base has two files: one real winning document vector and repeated orthogonal noise. The real-model supplement instead repeats an actual geology embedding with matching stored text and FTS terms. This still has only two independent source documents. Real background indexing grows the corpus during contention; end counts are listed below. These are chunk-scale stress results, not million-file or representative-corpus quality evidence.

| Entry / scenario | Before | After |
| --- | --- | --- |
| mixed/cold | 3394.12 / 18270.79 / 18270.79 (n=10, unavailable=0) | 12132.61 / 15159.20 / 15159.20 (n=10, unavailable=0) |
| mixed/cold-fts | 103.56 / 217.37 / 217.37 (n=10, unavailable=0) | 107.44 / 243.91 / 243.91 (n=10, unavailable=0) |
| mixed/fts-cache | 91.26 / 111.74 / 121.02 (n=20, unavailable=0) | 71.54 / 76.33 / 79.42 (n=20, unavailable=0) |
| mixed/semantic-cache-fill | 3561.73 / 3561.73 / 3561.73 (n=1, unavailable=0) | 238.06 / 238.06 / 238.06 (n=1, unavailable=0) |
| mixed/semantic-cache | 8338.29 / 23357.19 / 23357.19 (n=19, unavailable=0) | 216.67 / 218.79 / 218.79 (n=19, unavailable=0) |
| mixed/hot-new-semantic | 6973.10 / 20042.02 / 24785.42 (n=20, unavailable=0) | 231.73 / 234.16 / 234.93 (n=20, unavailable=0) |
| mixed/real-model-hot-new-semantic | 7428.37 / 27446.34 / 35473.83 (n=20, unavailable=0) | 780.31 / 871.70 / 1262.91 (n=20, unavailable=0) |
| mixed/index-writer | 110.09 / 325.72 / 710.97 (n=20, unavailable=0) | 70.81 / 102.98 / 134.66 (n=20, unavailable=0) |
| mixed/fts-real-index | 96.48 / 158.79 / 269.95 (n=20, unavailable=0) | 86.37 / 102.22 / 203.63 (n=20, unavailable=0) |
| mixed/semantic-real-index | 11359.17 / 15129.97 / 20014.21 (n=20, unavailable=0) | 314.37 / 412.35 / 470.22 (n=20, unavailable=0) |
| file-mode/cold | 16566.09 / 26024.88 / 26024.88 (n=10, unavailable=0) | 14183.97 / 18934.03 / 18934.03 (n=10, unavailable=0) |
| file-mode/cold-fts | 125.43 / 227.46 / 227.46 (n=10, unavailable=0) | 81.57 / 213.08 / 213.08 (n=10, unavailable=0) |
| file-mode/fts-cache | 43.15 / 62.72 / 63.23 (n=20, unavailable=0) | 54.16 / 66.56 / 66.62 (n=20, unavailable=0) |
| file-mode/semantic-cache-fill | 1534.58 / 1534.58 / 1534.58 (n=1, unavailable=0) | 283.89 / 283.89 / 283.89 (n=1, unavailable=0) |
| file-mode/semantic-cache | 1237.43 / 3761.68 / 3761.68 (n=19, unavailable=0) | 262.52 / 278.68 / 278.68 (n=19, unavailable=0) |
| file-mode/hot-new-semantic | 1212.57 / 7443.55 / 9304.58 (n=20, unavailable=0) | 269.26 / 290.16 / 317.38 (n=20, unavailable=0) |
| file-mode/real-model-hot-new-semantic | 1689.06 / 4317.80 / 14417.39 (n=20, unavailable=0) | 626.04 / 814.22 / 823.29 (n=20, unavailable=0) |
| file-mode/index-writer | 40.44 / 148.59 / 170.01 (n=20, unavailable=0) | 43.04 / 61.95 / 62.14 (n=20, unavailable=0) |
| file-mode/fts-real-index | 43.79 / 103.52 / 192.27 (n=20, unavailable=0) | 39.06 / 44.17 / 79.82 (n=20, unavailable=0) |
| file-mode/semantic-real-index | 13691.19 / 15103.26 / 15222.80 (n=20, unavailable=0) | 272.31 / 286.31 / 290.56 (n=20, unavailable=0) |

### Resources and command wall time

RSS is the sampled resident size by descendant executable name; sums double-count shared pages. `swiftpm-testing-helper` hosts the app under test, while `Typeflux` includes filesystem-worker children. The complete process maps remain in summary.json. External CPU peaks cover the entire command, including preparation; older reports lack an anchor for per-query alignment. They are not proof of query-specific contention or an isolated causal comparison.

| Case | Test exit before → after | Command wall seconds before → after | Peak RSS MiB before → after | External compiler/test CPU peak before → after |
| --- | --- | --- | --- | --- |
| native | 0 → 0 | 2225.28 → 779.87 | swiftpm-testing-helper=557.4; TypefluxSemanticHelper=486.2; Typeflux=20.0 → swiftpm-testing-helper=2168.3; TypefluxSemanticHelper=483.7; Typeflux=20.2 | 912.8% → 380.3% |
| contention | 0 → 0 | 1861.29 → 1021.94 | swiftpm-testing-helper=652.4; TypefluxSemanticHelper=977.5; Typeflux=40.8; sherpa-onnx-offline=780.3 → swiftpm-testing-helper=2213.8; TypefluxSemanticHelper=1018.9; Typeflux=39.8; sherpa-onnx-offline=788.7 | 834.7% → 396.3% |
| cold-fts | 0 → 0 | 627.50 → 649.24 | swiftpm-testing-helper=611.0; TypefluxSemanticHelper=485.8; Typeflux=19.8 → swiftpm-testing-helper=2064.0; TypefluxSemanticHelper=484.2; Typeflux=19.7 | 384.9% → 387.3% |
| real-noise | 0 → 0 | 719.91 → 509.67 | swiftpm-testing-helper=571.5; TypefluxSemanticHelper=483.7; Typeflux=19.8 → swiftpm-testing-helper=2198.9; TypefluxSemanticHelper=485.5; Typeflux=19.7 | 907.3% → 394.0% |

| Entry | Native index disk MiB before → after | Contention index disk MiB before → after | Contention chunks at end before → after | Encoded texts / active inference second before → after | Encoded texts / observed wall second before → after |
| --- | --- | --- | --- | --- | --- |
| mixed | 4307.88 → 4270.20 | 4283.59 → 4287.77 | 1002407 → 1004147 | 28.74 → 27.46 | 1.17 → 6.21 |
| file-mode | 4267.04 → 4268.28 | 4279.87 → 4275.39 | 1001682 → 1001943 | 30.70 → 30.06 | 0.72 → 10.85 |

Background throughput counts successfully encoded texts during the observation window, not completed files. There are 512 synthetic geological documents, each 54,400 UTF-8 bytes. Native writer contention is a separate synthetic writer; real-index contention uses the production document queue and helper.

### Actual ASR contention

Each condition has 10 real SenseVoice transcriptions per entry from the same generated 5.5693125-second WAV. Foreground busy is driven at the production service boundary; this is not microphone/hotkey latency. FTS during voice is service completion, not a native draw boundary.

| Entry / condition | ASR before | ASR after | FTS during voice before | FTS during voice after |
| --- | --- | --- | --- | --- |
| mixed/voice-idle | 579.98 / 1019.62 / 1019.62 (n=10, unavailable=0) | 569.40 / 766.44 / 766.44 (n=10, unavailable=0) | 0.72 / 7.36 / 7.36 (n=10, unavailable=0) | 0.80 / 3.88 / 3.88 (n=10, unavailable=0) |
| mixed/voice-preempt-index | 600.33 / 615.71 / 615.71 (n=10, unavailable=0) | 592.01 / 634.36 / 634.36 (n=10, unavailable=0) | 0.61 / 2.72 / 2.72 (n=10, unavailable=0) | 0.64 / 1.90 / 1.90 (n=10, unavailable=0) |
| file-mode/voice-idle | 559.57 / 1028.68 / 1028.68 (n=10, unavailable=0) | 577.28 / 758.42 / 758.42 (n=10, unavailable=0) | 0.71 / 3.93 / 3.93 (n=10, unavailable=0) | 0.82 / 3.46 / 3.46 (n=10, unavailable=0) |
| file-mode/voice-preempt-index | 578.75 / 605.03 / 605.03 (n=10, unavailable=0) | 598.16 / 614.45 / 614.45 (n=10, unavailable=0) | 0.65 / 6.00 / 6.00 (n=10, unavailable=0) | 0.70 / 2.34 / 2.34 (n=10, unavailable=0) |

## p95 target observations

The 100 ms first-body target is shown at 100k for actual cold FTS as well as warm conditions; a warm pass is not a blanket cold pass. The warm 300 ms noncached semantic target is shown at all three scales, including real-index contention. The original cold scenario is semantic-only and is reported separately. A condition is marked met only if its p95 meets the threshold, no body is missing and its whole benchmark returns zero. Other assertions and retained failed attempts still require review even when an observed p95 meets its threshold.

| Scale / entry / condition | p95 ms | Target ms | Result |
| --- | --- | --- | --- |
| 10,000/mixed/hot-new-semantic | 140.04 | 300 | met |
| 10,000/mixed/real-model-hot-new-semantic | 146.50 | 300 | met |
| 10,000/mixed/semantic-real-index | 355.40 | 300 | not met |
| 10,000/file-mode/hot-new-semantic | 113.53 | 300 | met |
| 10,000/file-mode/real-model-hot-new-semantic | 118.79 | 300 | met |
| 10,000/file-mode/semantic-real-index | 335.60 | 300 | not met |
| 100,000/mixed/cold-fts | 125.28 | 100 | not met |
| 100,000/mixed/fts-cache | 75.55 | 100 | met |
| 100,000/mixed/index-writer | 108.58 | 100 | not met |
| 100,000/mixed/fts-real-index | 91.43 | 100 | met |
| 100,000/mixed/hot-new-semantic | 185.05 | 300 | met |
| 100,000/mixed/real-model-hot-new-semantic | 249.03 | 300 | met |
| 100,000/mixed/semantic-real-index | 313.82 | 300 | not met |
| 100,000/file-mode/cold-fts | 200.24 | 100 | not met |
| 100,000/file-mode/fts-cache | 42.88 | 100 | met |
| 100,000/file-mode/index-writer | 50.84 | 100 | met |
| 100,000/file-mode/fts-real-index | 74.13 | 100 | met |
| 100,000/file-mode/hot-new-semantic | 160.72 | 300 | met |
| 100,000/file-mode/real-model-hot-new-semantic | 208.36 | 300 | met |
| 100,000/file-mode/semantic-real-index | 292.79 | 300 | met |
| 1,000,000/mixed/hot-new-semantic | 234.16 | 300 | met |
| 1,000,000/mixed/real-model-hot-new-semantic | 871.70 | 300 | not met |
| 1,000,000/mixed/semantic-real-index | 412.35 | 300 | not met |
| 1,000,000/file-mode/hot-new-semantic | 290.16 | 300 | met |
| 1,000,000/file-mode/real-model-hot-new-semantic | 814.22 | 300 | not met |
| 1,000,000/file-mode/semantic-real-index | 286.31 | 300 | met |

Quality tradeoffs, the original oracle gaps, Float16 ordering differences and retained failed/retried runs are documented in quality-summary.md, quantization.json and README.md. These tables do not establish general corpus or per-group MRR non-regression.
