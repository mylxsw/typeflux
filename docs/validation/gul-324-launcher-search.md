# GUL-324 — file search candidate reuse and publication latency

## Behavior

Ordinary file search and live file mode debounce for 16 ms. The ordinary search coordinator publishes as soon as both local providers finish, cancelling its pending publication timer. A fast application provider still gives an unfinished file provider up to 80 ms to join its batch. Slow applications retain the mixed/apps-first ordering rule; explicit files-first mode can publish files earlier. Browser results continue arriving separately.

`AskFileSearchCandidates` retains one pool of record indices selected by the existing character-mask prefilter, before filename matching, filters, scoring or Top-K selection. A query can reuse that pool when its mask contains the previous mask, its name/path matching domain is the same, and the index revision and record count agree. Each search applies the current matcher, filters, usage, time, ordering and result limit again. This also preserves new matches when adding characters enables pinyin or fuzzy matching.

Indexes below 16,384 records skip collection. Pools larger than one eighth of the record table, or 100,000 indices, fall back to the full scan. Retained index payload is at most 400,000 bytes; reserved array capacity and metadata are additional, as are temporary chunk buffers. Chunk publication preserves record order and folder locality. Empty pools are reusable, but every index publication invalidates them too. Older concurrent searches cannot restore a pool from an invalidated revision.

The implementation uses the existing index, masks, matcher, cancellation tokens and worker queues. It adds no dependency or index format change.

## Measurement method

Run `bash scripts/launcher_search_benchmark.sh` on macOS. The repaired driver compiles the production scanner and coordinator with `swiftc -O`. It extracts provider contracts and model/matching definitions, excluding index lifecycle, settings persistence and plugin presentation methods. Localization is stubbed; browser providers and feature entries are disabled. Image generation uses an injected loader returning nil. The measurements exclude crawling, disk snapshot loading and rendered frames.

The nested-name workload uses seed 242, 500 synthetic applications and 100,000 / 500,000 / 1,000,000 file records, with Chinese names, mixed extensions and fixed modification dates. Each measurement has one warm-up and 30 measured runs. The driver compares warm candidate searches with full scans over the same records and asserts identical ordered hits. A separate selective-name workload has one million records with 1,000 `rare-report` names; the candidate pool is primed by `rar` before measuring `rare`.

The coordinator comparison uses the original sources at `e871f4dc5da4aea40e236f844e82d8c5a1914842` and the changed sources with the same repaired harness. The baseline driver omits the new candidate argument so it calls the original full scanner. Measurements are from the same Apple M4 host with Apple Swift 6.4, and remain sensitive to other activity on that host. They measure observable result publication, not FPS or a displayed frame.

## Results

Complete measured output is in [gul-324/benchmark.txt](gul-324/benchmark.txt).

| Million-record coordinator | Before p50 / p95 | After p50 / p95 |
|---|---:|---:|
| Input handling | 0.113 / 0.157 ms | 0.039 / 0.059 ms |
| Application result publication | 81.895 / 82.626 ms | 29.451 / 33.028 ms |
| File result publication, including debounce | 109.152 / 112.619 ms | 29.451 / 33.028 ms |

The separate selective-name workload measures 1.148 / 1.180 ms for a current full scan and 0.247 / 0.250 ms with a warm candidate pool. Dense pools fall back to scanning and do not guarantee a matching-speed improvement.

Because the two complete runs showed substantial host-load variation, an additional control compiled the original scanner with renamed private symbols beside the current scanner in one executable. It alternated original / current full / candidate scans for 30 measured rounds over the same million records and checked ordered-hit equality after every operation. For broad `r`, original and current full-scan p50 were 15.685 and 14.973 ms; for `report`, 12.707 and 12.370 ms. The sparse miss `xyzzy` measured 0.805 ms originally, 0.845 ms for the current full scan and 0.222 ms with candidates. This exposes the small fallback cost rather than presenting every query as faster. The control is diagnostic evidence; it does not turn host-dependent measurements into a cross-machine performance guarantee.

## Verification and self-review

- `swift test -j 2 --no-parallel --enable-code-coverage --filter 'AskQuickResults|AskQuickSearchSession|AskSearchScheduling|AskResultImageCache|AskLauncherToggle|AskFileIndex|AskFileSearchCandidates|AskFileScope|AskFileStreaming|AskFileReliability|AskFuzzy|AskApp|LauncherSearchSettings|AskPluginSession|AskPluginFiles|AskFileSearchPlugin|ExclusiveUIStateLanguage'`: **299 tests in 35 suites passed**, in 158.754 seconds.
- Changed executable source coverage is **107/108 lines, 99.07%**, from LLVM LCOV records and the zero-context Git diff. The new candidate class has **53/53 executable lines covered**; the complete scanner and coordinator each have 100% line coverage in that run. Details are in [gul-324/coverage.txt](gul-324/coverage.txt). This is focused changed-code coverage, not repository-wide coverage.
- New tests compare cached and full results for pinyin/fuzzy activation, query edits, name/path domain changes, extension/folder/type filters, limit changes, usage/time/recent ranking, no-hit pools, overflow, stale revisions, cancellation and parallel chunks. A real index rebuild test replaces a no-hit snapshot with an equally sized snapshot containing a new match. Coordinator tests inject a five-second publication grace and require complete local batches to finish without that timer, avoiding tight timing assertions.
- `bash -n scripts/launcher_search_benchmark.sh`, both repaired benchmark executions, the interleaved scanner control and `git diff --check` passed. SwiftLint completed for touched source files with warnings; the new candidate file also passed `swiftlint lint --quiet Sources/Typeflux/Ask/QuickResults/Files/AskFileSearchCandidates.swift --strict`.
- Self-review checked mask-superset recall, filters/ranking outside the cache, snapshot invalidation including equal record counts, cancelled and older searches, lock order, bounded buffers, deterministic ordering, stale-action protection and documentation consistency. The test fixtures were corrected to keep their snapshot outside the indexed root and to scope a usage-ranking assertion to PDFs. No new network access, permission, secret or persistent index-format path was introduced.

## Complete test inventory

`make coverage` reached a 600-second diagnostic deadline while tests were still progressing, with no recorded assertion failures. Its XCTest phase completed **3,722 tests, 17 skipped, zero failures**, in 227.381 seconds. The Swift Testing phase fully completed 175 suites before the deadline; the interrupted suite was not counted as complete.

`swift test list --skip-build --disable-xctest` discovered **2,473 Swift Testing tests**. Unique suite-title/type mappings for the 175 completed suites were checked against that inventory, accounting for 1,157 tests. A second run disabled XCTest and excluded only those completed suites:

```sh
swift test -j 2 --no-parallel --disable-xctest --enable-code-coverage \
  --skip "$(cat docs/validation/gul-324/completed-suites-regex.txt)"
```

The remaining **1,316 tests passed** in 411.986 seconds, with no recorded issues. Together these passes cover every discovered test; some tests in the interrupted suite were repeated. The inventory and selected-suite evidence are in [gul-324/test-inventory.txt](gul-324/test-inventory.txt). For a fresh run, use `make coverage` with enough time to finish all suites; the recorded skip expression is only valid as the continuation of the first pass. A single uninterrupted `make coverage` completion remains unverified. Focused LLVM coverage and HTML generation were completed separately.
