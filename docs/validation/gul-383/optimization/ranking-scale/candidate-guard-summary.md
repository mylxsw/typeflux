# Final candidate-allocation probe

The complete cold/cache/writer/real-index matrix predates this final optimization and remains in performance-summary.md. This probe uses the current source-hashes.json. It repeats only the declared real-model hot-new-semantic scenario at all three chunk scales, with unchanged thresholds and no sample removal. Before is the GUL-403 baseline; intermediate is source-hashes-before-candidate-guard.json. The final guard rejects losing same-file candidates before allocating their hit/name, and single-class calibration returns zero earlier. Full 400-query ranking JSON parity is recorded separately.

Same pinned model and shared M4/16 GiB host. Two source facts are repeated to the desired chunk count; these are not representative million-file data. Input and drawing have the same controlled native-editor/layout/accessibility boundary as the primary matrix. These measurements do not cover physical pointer input, a compositor fence or an installed app. No resource-controller implementation is implied.

Cells are draw p50 / p95 / p99 in milliseconds.

| Chunks / entry | Before | Intermediate | Final allocation guard |
| --- | --- | --- | --- |
| 10,000/mixed | 150.08 / 168.52 / 195.42 (n=100, unavailable=0) | 144.08 / 146.50 / 148.91 (n=100, unavailable=0) | 152.04 / 185.41 / 206.98 (n=100, unavailable=0) |
| 10,000/file-mode | 124.75 / 129.86 / 137.42 (n=100, unavailable=0) | 115.34 / 118.79 / 119.43 (n=100, unavailable=0) | 117.35 / 151.23 / 156.55 (n=100, unavailable=0) |
| 100,000/mixed | 254.67 / 348.49 / 478.88 (n=100, unavailable=0) | 224.26 / 249.03 / 316.48 (n=100, unavailable=0) | 200.37 / 221.29 / 242.37 (n=100, unavailable=0) |
| 100,000/file-mode | 236.52 / 540.09 / 2262.92 (n=100, unavailable=0) | 160.28 / 208.36 / 216.92 (n=100, unavailable=0) | 173.23 / 195.56 / 207.98 (n=100, unavailable=0) |
| 1,000,000/mixed | 7428.37 / 27446.34 / 35473.83 (n=20, unavailable=0) | 780.31 / 871.70 / 1262.91 (n=20, unavailable=0) | 362.88 / 377.91 / 932.58 (n=20, unavailable=0) |
| 1,000,000/file-mode | 1689.06 / 4317.80 / 14417.39 (n=20, unavailable=0) | 626.04 / 814.22 / 823.29 (n=20, unavailable=0) | 481.89 / 823.06 / 1320.78 (n=20, unavailable=0) |

The 300 ms observation applies only to this hot scenario. Cold first-body, real-index contention, per-group MRR and the new background-resource requirements remain separate unresolved gates. RSS/process maps, host swap/free disk and external compiler activity remain in each raw run report. Command wall includes compilation/setup; query timers exclude those stages.
