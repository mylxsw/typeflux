# GUL-405: persistent model download recovery

Base: `55985dbd039f320f6771aa8a64c4f632bec43cd2` (PR645 merge). This slice only changes model transfer recovery and its text/projector callers. It does not complete GUL-405 or start GUL-406.

The existing fixed model URLs include the pinned repository revision. URL, expected size and SHA-256 jointly select a private checkpoint directory. `AskSecureDirectory` supplies descriptor-relative, no-follow traversal and an exclusive nonblocking directory lock. Payloads must be regular, single-link, current-user, private files; metadata is read without following symlinks and replaced atomically. Actual on-disk payload length determines the next offset. Metadata identity mismatch, missing strong ETag or an oversized checkpoint starts from zero. Text weights and projector weights have distinct identities.

A new downloader sends Range and If-Range for a saved prefix. A 206 must match the offset, total size, response length and strong ETag. A 200 replaces the prefix, including when Range is ignored or the resource changes. Invalid ranges/changed 206 ETags discard the prefix. Truncated responses retain the actual bytes for an explicit later attempt; bounded incomplete 206 responses also remain partial. There is no automatic retry loop. Servers without a strong ETag safely restart rather than append unvalidated prefixes.

Completion hashes the open payload descriptor with the existing model verifier and checks its directory entry identity before and after moving it to a unique verified result. A full checkpoint left by cancellation can be hashed without another HTTP request. The original install layer still rechecks size/SHA-256, copies into private staging, verifies the copy and installs atomically. Pinned hashes retain existing model compatibility. Failed/incomplete downloads never return a verified artifact. Cancellation is checked during hashing and before returning; existing text lifecycle/attempt and media ownership checks still guard installation and ready publication. A transfer joins its session and releases the checkpoint lock before its caller resumes. Progress reports total actual bytes, including the reused prefix, without summing the prefix twice; a full restart reports zero.

## Declared validation scope

`run-coverage.py` records an explicit `make coverage FILTER=...` and total wall time. The test-files list is a build closure, not the execution scope.

- `SemanticDownloadResumeTests`: actual loopback HTTP interruption, new-instance Range/If-Range recovery, prefix/metadata evidence, final hash and existing atomic installation; ignored Range, changed resource, incorrect range/ETag, truncation, bad checksum, cancellation, competing instances, same-size different-hash identities, full checkpoint, payload/metadata symlinks, range parsing, and both production model-file fetch identities using per-session refusal protocols.
- Three selected `SemanticFileServiceTests` methods: accepted 206 through text installation/index/search; cancellation/corruption/disable; transfer failure, repeated fetch and early cancellation.
- Two selected `SemanticMediaWorkerTests` methods: accepted 206 through lazy verified projector installation/reuse; failed/cancelled transfer joining and no installation.

The loopback fixture is 262,144 deterministic bytes, interrupted at 65,536 bytes. It is not GGUF, not a model-quality/compatibility inference test, and not a real-weight/native-input/performance result. No hundreds-of-MB external download, prior accepted format/OCR/media matrix or full regression is repeated. The tests start one local HTTP process per case, keep request logs, and terminate/join each process before leaving the test.

## Self-review

Reviewed the complete fetch/checkpoint/verify/install/caller chain, incomplete and rejected responses, identity changes, recovery, cancellation/late publication, concurrent instances, descriptors/session/process cleanup, private storage/symlink boundaries, and existing API/localization behavior. Fixed descriptor-based completion verification and full-checkpoint recovery during implementation. No index schema, formats, media processing or UI was changed. Existing index vectors and checkpoints remain independent.

Rollback: revert this PR. The new Downloads subdirectory becomes unused; installed pinned models and index state retain their previous format.

## Results

Twelve distinct methods passed across focused runs. The first executable run selected nine methods: seven passed and two failed because the loopback fixture closed before CFNetwork delivered its prefix. The repaired ten-method scope passed, including the previously missed three text methods. The final one-method metadata identity proof also passed. The two passing media methods were reused only after all 1,134 application production objects and production source hashes matched. This is not a single final twelve-method run.

The actual HTTP evidence shows a persisted 65,536-byte prefix, then `Range: bytes=65536-`, `If-Range: "v1"`, a 206 response and final/installed SHA-256 `2312394bd99545d9de131c24efb781e765ac1aec243f2ed9347597a793a415e9`. Ignore/change fixtures also assert that the retry really requested Range before accepting the complete replacement response. The repaired fixture observes production-written prefix length before dropping the connection; it never writes the checkpoint itself.

Application changed executable lines: **198/211 (93.84%)**. File helper and native media runtime: **0/0, no source changes**. This exceeds the current 70% gate, so no tests were added to pursue a higher threshold. Uncovered application lines are filesystem/permission/rename failures, oversized input guards, replaced-entry rejection during completion, non-HTTP/encoded or mismatched full-response lengths, and the two default text model configuration initializer expressions. Exact line numbers and per-file denominators are in `changed-coverage.json`.

All four coverage commands took **529.32 seconds** in total, including one 247.65-second build failure (a throwing property inside a test `&&` macro), one failed test command (145.68 seconds), the repaired ten-method pass (69.02 seconds), and final identity proof (66.97 seconds). Build/runner/export time is included. The original filter missed backtick-prefixed text method names; the repaired filter explicitly selects them. No plain duplicate test run, full suite or CI watch was used.

Initial raw profile merging reported counter-layout changes in two revised test functions. The application sources and objects match across those repairs. `clean_profiles.py` uses LLVM's `--no-function=TypefluxFocusedTests` on each raw profile before merging; the clean merge has no diagnostics and reproduces exactly the same 198/211 application line report. A discarded LLVM text-profile round-trip failed to parse bitmap fields; both processing failure logs are preserved. No tests or application code were changed to resolve profile processing. Old baseline and discovery-only profiles are excluded.

The two new production files pass strict lint. Three existing caller files retain 42 existing findings, with zero findings on changed lines. The local HTTP test processes were terminated and joined; the final process check found none. All tested input, object, actual application/test/helper binary, tool, model declaration, fixture and profile fingerprints are recorded. No actual model weights, inference quality, native-input timing, performance or long stability conclusion is added. Necessary real-model/native-input short validation remains in GUL-405.
