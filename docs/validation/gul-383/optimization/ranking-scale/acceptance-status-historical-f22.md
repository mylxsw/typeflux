Historical f22 report, retained without rewriting its observations. Its cold/all-scale thresholds were overstated: the original hard limits are 100k **hot** body ≤100 ms and real uncached **hot** pure semantic ≤300 ms. See `acceptance-status.md` for the current gates and final-source results. This file is not the current acceptance decision.

# Acceptance remains open

This is a draft implementation and evidence handoff for Arch's technical adjustment. GUL-404 is not complete, the PR is not ready to merge, and the next serial stage must remain parked.

| Requirement | Retained observation | State |
| --- | --- | --- |
| 100k cold first-body draw p95 ≤100 ms | Primary after matrix: mixed 125.28 ms, file-mode 200.24 ms | Not met |
| 100k body under a writer ≤100 ms | Primary after matrix: mixed 108.58 ms | Not met |
| Warm new semantic draw p95 ≤300 ms at all scales | Final-source real-model 1m probe: mixed 377.91 ms, file-mode 823.06 ms | Not met |
| Semantic during actual indexing ≤300 ms | Primary after matrix: 10k mixed/file 355.40/335.60 ms, 100k mixed 313.82 ms, 1m mixed 412.35 ms | Not met |
| Per-group MRR non-regression | New-wording holdout: semantic paraphrase 1.00→0.52, Chinese short 1.00→0.84 | Not met |
| Supported holdout Recall@5 ≥85%; no-answer false positives ≤5% | Answerable groups 92–100%; no-answer 1/25 (4%) | Met on this query holdout only |
| Complete original oracle | 50 labelled scan/media-timestamp cases lack captured source fixtures and remain failures; full denominator 125/175 | Evidence gap retained |
| Changed-code coverage ≥90% | App 747/781 (95.65%); helper 40/43 (93.02%) | Met in aggregate, with per-file uncovered paths retained |
| Actual foreground ASR priority | Direct service busy boundary, 40 transcriptions per scale and implementation (10 × two entries × two conditions); latest after artifacts assert actual started-batch counters | Controlled-boundary evidence only |
| Run reasons/counters, affected-subtree scheduling, resource-wait UI | No implementation in this patch | Not delivered |
| Adaptive duty cycle, memory/thermal hysteresis, pressure release and bounded work | Existing pause policy remains; resident query pages add memory. The lexical recipe migration is still a single unbudgeted transaction | Not delivered |
| Sustained document/image/audio/video system-interaction and resource proof | No 15-minute native mouse/keyboard/window comparison, per-process I/O or GPU/power curves | Not delivered |

The primary cold/cache/writer/real-index matrix predates the final equivalent-output candidate-allocation optimization. Source manifests and per-run binary hashes keep the stages separate. The final-source 400-query replay is identical, and final-source hot real-model probes cover all three scales; they do not replace a full current-source matrix. See `candidate-guard-summary.md` for every sample's quantiles and the remaining hot conditions.

The shared host changed during the final 1m probe: host swap use increased from `4089.50M` to `4285.00M` in sysctl output, and free disk increased from 18.69 to 35.74 billion bytes. These observations do not attribute swap growth or other activity to Typeflux. They also prevent an isolated causal performance claim. The original two-file stress fixture, metadata budgets and thermal overrides do not establish safety under the user's many-file workload.

The user's installed revision and incident root cause remain unknown. This patch has not demonstrated that repeated scanning, fan/heat or pointer stalls are fixed. `resource-investigation.md` identifies the concrete event, migration and pressure-control paths requiring implementation; `self-review.md` records the completed code review and open findings. Arch's existing durable callback handles this unsuccessful acceptance handoff; no additional dispatch or next-stage promotion is performed here.
