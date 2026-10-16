# Implementation review

This review covers the code in `source-hashes.json`. Release harness revisions change sampling and failure accounting, not production behavior. Acceptance findings below remain open.

## Retrieval and publication

Followed both launcher entries from accepted editor text through FTS, query encoding, vector scoring, current file validation and result publication. Scope/type/extension/folder predicates precede TopK. Existing filename ordering and default Return safety remain covered by the focused hybrid/caller suites. Body results bypass filename coalescing only after apps are ready.

Corrected calibration-before-selection: pruning on raw cosine could discard a later calibrated winner. The reader now retains one scalar per row and selects after observing all eligible file/class maxima. Repeated chunks of a book do not define the distinct-file rejection margin. Single-vector and single-class fallbacks have explicit tests. Normalization folds Latin accents without erasing Japanese voicing; exact identifiers adjacent to CJK prose retain number boundaries.

The semantic and lexical channels both revalidate current file identity and authorization. Metadata helper reuse is transport reuse, not an authorization cache. Candidate-batch deadlines withhold unvalidated hits and publish a degraded state. Corrected the expired-FTS-budget path so it cannot start a second cold validation in the same query. A fresh query can recover afterward.

## Cancellation, generations and resources

Reviewed the reader locks, SQLite statement/transaction cleanup, snapshot publication, helper ownership and service cancellation. FTS VM progress callbacks interrupt work before the first result, then uninstall before rollback. A fault test also runs a substantial second statement to catch a leaked callback. Insert/update/delete, same-ID reuse, rollback, version changes and failed refresh are tested against independent WAL readers.

Detached permission/snapshot preparation now receives explicit cancellation on closing search and foreground voice. Interactive validation cancels stalled root preparation before acquiring the metadata helper. The benchmark fixture closes its independent writer before removing its files. No additional extractor prefetch or production worker concurrency was added; measured prefetch was slower and rejected.

Float16 pages are a disposable query representation. Float32 persists on disk; no precision-changing schema migration occurs. Scratch is page bounded, but the full resident matrix and one scalar per row scale with corpus size. Matrix representation savings are not a claim of lower process RSS. A memory-pressure/release policy remains missing under the new resource requirements.

## Errors, security and compatibility

Checked empty queries, invalid vectors, malformed payloads/database failures, nonfinite/negative/overflowing media timestamps, permission revocation, stale file generations and exact/quoted near misses. The lexical timestamp boundary now matches the vector reader, retaining zero/fractional times while discarding unsafe display values.

SQL values are bound; FTS inputs are built from normalized alphanumeric terms. No file/query content is uploaded or logged by the new code. Fixtures and speech are generated. Model/profile, scope and privacy defaults remain unchanged. The additive lexical recipe migration preserves compatible vectors. Mixed old/new-normalizer writes after rollback require the existing Rebuild action on re-upgrade; the recipe does not detect old writers.

Documentation describes the actual query/permission budgets and the rollback limitation. No new localization keys or user settings were added. Swift 6.4 was used on the measured host; the repository's pinned Swift 6.3.1 was not separately run.

## Evidence and remaining acceptance findings

Changed application coverage is 747/781 executable lines (95.65%); helper coverage is separately 40/43 (93.02%). These are changed-line results, not project-wide or per-file 90% claims. Per-file uncovered lines and pass provenance remain in the coverage JSON. The targeted final suites passed; earlier failed preparation/evaluation and interrupted measurement attempts remain retained.

The sampler's stale file-plugin terminal predicate was corrected and its invalid v4 rows are marked as invalid measurements. Current terminal predicates require a current plan and a completed empty-query clear witness. Real permission-denial selfchecks retain missing bodies as null/unbounded latency and verify the expected nonzero benchmark exit. An earlier no-body/degraded episode without the clear witness has an unconfirmed cause and is not claimed fixed by a successful retry.

Aggregate MRR improves, but semantic-paraphrase and Chinese-short group MRR regress. The complete original oracle includes missing scan/media fixtures and does not pass its full answerable denominator. The separate holdout is new wording on shared source facts, not an independent topic/corpus. No parameter was chosen from its retrieval results.

A later review questioned the negative partial-coverage term. Removing it would make scores increase with matching terms at a fixed cosine, but the development-only trial reduced the selected variance configuration's cross-language Recall@5 from 23/25 to 12/25. None of the nine tested configurations then met every gate. The hypothesis was rejected and production restored byte for byte before any new holdout evaluation. The original development metrics were reproduced exactly. `monotonic-alternative-study.json` and the full failed trial rows retain this result; it does not repair the group MRR regressions. The trial writer now records an empty eligible set before returning failure instead of losing its results in `max()`.

The added run diagnostics, affected-subtree scheduling, adaptive background resource budget and sustained system-interaction evidence are not delivered by this patch. Their absence is an acceptance blocker. See `resource-investigation.md`. Focused test coverage and native query measurements do not establish that the user's repeated scanning, heat or pointer stalls are solved.

The final allocation guard repeats the existing per-file offer predicate before constructing a hit. It preserves the greater-score and lowest-ID tie rules, and performs no state mutation when it skips a candidate. Single-class calibration returns the same zero adjustment earlier. The 600-chunk test now keeps duplicate scores above the rejection floor and asserts the first equal-score page. Final focused coverage passed 19 tests in 74.31 s including preparation; Reader is 316/327, calibration 52/52 and scoped SQLite cancellation 21/21. Other source records retain their latest earlier pass; profiles from different binaries are not merged. Primary scale evidence predates these two optimizations and remains labelled separately.
