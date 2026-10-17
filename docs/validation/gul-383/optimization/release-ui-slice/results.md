
Final observed native results: pass.

| Entry | Group | n | publication p50 / p95 ms | layout/AX p50 / p95 ms | complete-query p95 ms |
| --- | --- | ---: | --- | --- | --- |
| mixed | lexical | 3 | 13.93 / 26.19 | 34.45 / 54.89 | 146.78 |
| mixed | cross_language | 3 | 83.11 / 85.04 | 114.77 / 118.71 | 143.57 |
| file-mode | lexical | 3 | 37.15 / 51.97 | 51.10 / 63.92 | 173.66 |
| file-mode | cross_language | 3 | 107.83 / 108.42 | 141.20 / 144.73 | 151.69 |

These small-sample quantiles describe the observations only; they are not scale latency acceptance. The new complete-query column includes semantic completion after the FTS first screen. See raw source version/chunk/offset records and FSEvents mutation timing in `native-ui.json`.
