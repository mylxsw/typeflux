Superseded policy snapshot: the current issue revision20 relaxes small-sample quality and contention limits, drops the full million/cold precondition and requests300seconds per resource condition. Use `closeout-results.md` for the current handoff; this historical table retains the original strict failures without rewriting raw data.

GUL-404 business acceptance remains **open**. Source `6a9c18d79561b49d8c5339754193c6a06ee79374`; main base `ceeaaef5`; baseline `262135bc`. PR551 was externally merged before this rework and does not contain the new commits. No agent merge or next-stage dispatch occurred.

The implemented event/migration/budget paths have focused deterministic regressions and deep self-review. Passing those checks does not pass the remaining quality/resource gates. The final source is frozen; live benchmark results below must be updated only from collected reports.

| Area | Current result |
| --- | --- |
| Durable bounded events, private counters/UI | Implemented; no-change/recovery/single-file/storm/exclusion regressions retained |
| One-time pages and shadow lexical migration | Implemented; interruption/reopen/old-writer compatibility regressions retained |
| Work budget, pressure/priority, bounded memory | Implemented; policy/lifecycle/cancellation regressions retained; resource acceptance remains separate |
| Changed executable-line coverage | App2264/2460 (92.03%); helper38/38 (100%), againstmainceeaaef5 |
| Final-source 10k/100k/1m native matrix | Running; original100k hot body100ms / actual uncached hot semantic300ms only |
| Sustained real-file OFF/ON | Final-source repeat pending; historical1265 run retains612.78ms maximum mouse delay and growing backlog |
| Incident root cause | User installed incident build and causal explanation remain unconfirmed |

| Frozen cohort / group | n | Before MRR | After MRR | After Recall@5 | False positives |
| --- | --- | --- | --- | --- | --- |
| final-holdout / audio_semantic | 25 | 0.2353 | 0.9700 | 1.0000 | 0/0 |
| final-holdout / chinese_short | 25 | 1.0000 | 1.0000 | 1.0000 | 0/0 |
| final-holdout / cross_language | 25 | 0.2447 | 0.3580 | 1.0000 | 0/0 |
| final-holdout / identifier_unicode | 25 | 0.8300 | 1.0000 | 1.0000 | 0/0 |
| final-holdout / image_semantic | 25 | 0.5000 | 1.0000 | 1.0000 | 0/0 |
| final-holdout / lexical | 25 | 1.0000 | 1.0000 | 1.0000 | 0/0 |
| final-holdout / no_answer | 25 | — | — | — | 0/25 |
| final-holdout / semantic_paraphrase | 25 | 0.9200 | 0.9600 | 1.0000 | 0/0 |
| unseen-query / audio_semantic | 25 | 0.2587 | 1.0000 | 1.0000 | 0/0 |
| unseen-query / chinese_short | 25 | 1.0000 | 1.0000 | 1.0000 | 0/0 |
| unseen-query / cross_language | 25 | 0.2227 | 0.3247 | 1.0000 | 0/0 |
| unseen-query / identifier_unicode | 25 | 0.7233 | 1.0000 | 1.0000 | 0/0 |
| unseen-query / image_semantic | 25 | 1.0000 | 1.0000 | 1.0000 | 0/0 |
| unseen-query / lexical | 25 | 1.0000 | 1.0000 | 1.0000 | 0/0 |
| unseen-query / no_answer | 25 | — | — | — | 1/25 |
| unseen-query / semantic_paraphrase | 25 | 1.0000 | 0.9400 | 1.0000 | 0/0 |
| rework-frozen / audio_semantic | 25 | 0.2953 | 0.9800 | 1.0000 | 0/0 |
| rework-frozen / chinese_short | 25 | 1.0000 | 1.0000 | 1.0000 | 0/0 |
| rework-frozen / cross_language | 25 | 0.3040 | 0.3667 | 1.0000 | 0/0 |
| rework-frozen / identifier_unicode | 25 | 1.0000 | 1.0000 | 1.0000 | 0/0 |
| rework-frozen / image_semantic | 25 | 0.1600 | 1.0000 | 1.0000 | 0/0 |
| rework-frozen / lexical | 25 | 1.0000 | 1.0000 | 1.0000 | 0/0 |
| rework-frozen / no_answer | 25 | — | — | — | 2/25 |
| rework-frozen / semantic_paraphrase | 25 | 0.9600 | 0.9600 | 1.0000 | 0/0 |
| rework-final2 / audio_semantic | 25 | 0.3600 | 0.9600 | 0.9600 | 0/0 |
| rework-final2 / chinese_short | 25 | 1.0000 | 1.0000 | 1.0000 | 0/0 |
| rework-final2 / cross_language | 25 | 0.3680 | 0.4367 | 1.0000 | 0/0 |
| rework-final2 / identifier_unicode | 25 | 1.0000 | 1.0000 | 1.0000 | 0/0 |
| rework-final2 / image_semantic | 25 | 0.1440 | 0.9400 | 1.0000 | 0/0 |
| rework-final2 / lexical | 25 | 1.0000 | 1.0000 | 1.0000 | 0/0 |
| rework-final2 / no_answer | 25 | — | — | — | 0/25 |
| rework-final2 / semantic_paraphrase | 25 | 0.9467 | 0.9600 | 1.0000 | 0/0 |
| rework-final3 / audio_semantic | 25 | 0.2593 | 1.0000 | 1.0000 | 0/0 |
| rework-final3 / chinese_short | 25 | 1.0000 | 1.0000 | 1.0000 | 0/0 |
| rework-final3 / cross_language | 25 | 0.2887 | 0.4300 | 1.0000 | 0/0 |
| rework-final3 / identifier_unicode | 25 | 1.0000 | 1.0000 | 1.0000 | 0/0 |
| rework-final3 / image_semantic | 25 | 0.1200 | 1.0000 | 1.0000 | 0/0 |
| rework-final3 / lexical | 25 | 1.0000 | 1.0000 | 1.0000 | 0/0 |
| rework-final3 / no_answer | 25 | — | — | — | 0/25 |
| rework-final3 / semantic_paraphrase | 25 | 0.9133 | 0.9600 | 1.0000 | 0/0 |

All1000 current held-out rows and their before comparisons remain. The original four200-query cohorts are not replaced by final3. In particular, unseen-query semanticMRR1.00→0.94 and rework-frozen no-answer2/25(8%) still fail. Pooled precision must not erase the failing25-query stratum. Current per-row failures and source observations are in final-current-heldout-failures.json. No held-out parameter tuning followed these results.

Original175-positive native extraction/timestamp oracle: the first88-file attempt omitted12 supported audio fixtures and is retained as a failure (original-oracle-first-attempt-erratum.json); corrected13MOV+12WAV generation and audio timestamp validation will be rerun after the matrix; unsupported25 scanned-PDF cases remain explicitly failed, not removed. Supported files use actual native extraction and fixed models; original media labels and timestamps remain unchanged.

Native query results are actual committed NSTextView input → forcedlayout/display+AX, without a query-result WindowServer fence. Cold means fresh service/helper with warm OS/model/shader caches possible; readiness is excluded. Scale stress uses two repeated-chunk files. The separate resource probe measures generated own-window input → WindowServer event-ID pixels, not hardware HID/monitor scanout. No physical input or microphone capture claim. Native fixtures clamp legacy low-power/query-thermal callbacks false; the new budget reads actual pressure/thermal state.

See rework-self-review.md for ownership, cancellation, fresh permissions, rollback/re-upgrade consistency, privacy and UI/localization checks. Known strict-lint debt and unverified Swift6.3.1 remain disclosed; the available compiler wasSwift6.4. Model/helper/binary fingerprints and all command failures/whole-command wall times are retained. Raw profiles from different binaries are exported separately; only byte-identical production source line observations are unioned.
