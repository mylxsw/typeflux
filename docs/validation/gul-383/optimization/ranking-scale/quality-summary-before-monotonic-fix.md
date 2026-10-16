# Frozen ranking comparison

The same Release Swift harness replays the same 100 real captured source vectors. Each group has 25 queries. MRR includes misses as zero; no-answer groups report false-positive counts instead. These are retrieval replays, not extraction or UI measurements.

## final-holdout

| Group | Recall@5 before → after | MRR before → after |
| --- | --- | --- |
| lexical | 25/25 → 25/25 | 1.0000 → 1.0000 |
| identifier_unicode | 23/25 → 25/25 | 0.8300 → 1.0000 |
| chinese_short | 25/25 → 25/25 | 1.0000 → 1.0000 |
| cross_language | 18/25 → 24/25 | 0.2447 → 0.4000 |
| semantic_paraphrase | 25/25 → 24/25 | 0.9200 → 0.5167 |
| audio_semantic | 19/25 → 25/25 | 0.2353 → 0.9700 |
| image_semantic | 25/25 → 25/25 | 0.5000 → 1.0000 |
| no_answer | FP 25/25 → 0/25 | — |

## unseen-query

| Group | Recall@5 before → after | MRR before → after |
| --- | --- | --- |
| lexical | 25/25 → 25/25 | 1.0000 → 1.0000 |
| identifier_unicode | 20/25 → 25/25 | 0.7233 → 1.0000 |
| chinese_short | 25/25 → 23/25 | 1.0000 → 0.8400 |
| cross_language | 18/25 → 25/25 | 0.2227 → 0.4033 |
| semantic_paraphrase | 25/25 → 24/25 | 1.0000 → 0.5200 |
| audio_semantic | 19/25 → 25/25 | 0.2587 → 1.0000 |
| image_semantic | 25/25 → 25/25 | 1.0000 → 1.0000 |
| no_answer | FP 25/25 → 1/25 | — |

The new-query holdout aggregate answerable MRR improves from 0.7435 to 0.8233, but semantic-paraphrase MRR regresses from 1.0000 to 0.5200 and Chinese-short MRR from 1.0000 to 0.8400. The original independent-source set is now a retained regression after its failed first evaluation. These group regressions remain acceptance findings; an aggregate gain does not establish per-group non-regression.

For media location at rank ≤5, audio improves from 19/25 to 25/25 and images remain 25/25 in both sets. Every retrieved correct media source has its expected zero timestamp before and after. Each fixture has only one segment, so this is not a general multi-window localization benchmark. Video/audio-window and PDF/byte-offset behavior has separate targeted tests.

## Original fixed 200-query oracle

The full retained oracle has 125/175 answerable hits at rank ≤5 (71.43%), answerable MRR 0.6364, and 0/25 no-answer false positives. Its five text groups each retrieve 25/25; scanned and media-timestamp groups each retrieve 0/25 because their 50 source fixtures are absent from this captured replay. All 200 rows remain in `production-oracle-replay.json`. This is an explicit coverage gap, not evidence that every existing media format is unsupported or that the full oracle passed. The separate real audio/image set does not repair this original denominator.
