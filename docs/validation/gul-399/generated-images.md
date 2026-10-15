# Paid generated-image isolation and retention

This increment is stacked on #526 (`agent/arch-gpt-astra/gul-399-typed-images`). It does not complete GUL-399.

## Behavior and ownership

`AskImageGenerationService` no longer imports ImageIO. Its mandatory retention owner is reserved before the single paid POST. The complete bounded HTTP response is written before JSON parsing, cancellation checks, downloads or decoding. Downloaded original bytes are retained before validation. The private identity includes owner, conversation, run and tool call; the same identity cannot dispatch again, including after successful publication or a process restart. Provider credentials are not included in request metadata. No diagnostics include provider output, prompts, paths or image bytes.

The existing media executable handles `validateGeneratedImage`: PNG/JPEG only, one complete frame, positive dimensions, at most 8192 per axis and 16,777,216 pixels, plus a small decode probe. Original bytes are not re-encoded. The host checks the response identity, operation and metadata before constructing a result. Older helpers cannot silently supply an accepted response. The existing preview domain supplies two children, a three-second deadline, recovery budget and confirmed-retirement input leases; validator admission occurs before detached work. There is no new worker target, global DI instance or packaging path.

Original limits remain 16 MiB per image, 32 MiB per result bundle (less the existing 64 KiB metadata allowance), and 46 MiB per HTTP response. Validation input is independently capped at 16 MiB; metadata responses at 16 KiB. Retention allows eight pending records, each with one 46 MiB response and at most eight downloads totalling 32 MiB. A maximum of 1024 records includes completed identity markers. Each request/identity/publication metadata file is bounded. Pending, corrupt or partially cleaned records consume admission rather than being evicted. Directory/file permissions are 0700/0600; descriptor-relative operations reject links, and locks fail without blocking. Failed writes consume their reserved download budget.

After validation the caller rechecks cancellation, authorization and conversation scope. Valid images retain the existing persistent artifact behavior and generation metadata. Decoder failures return explicit incomplete results, keep the original response and expose received image bytes as generic `.bin` artifacts through the existing Save action. These binary artifacts are never passed to an image preview parser; their ordinary 30-day artifact expiry does not delete the private generation journal. An uncertain paid request or incomplete output returns an `unknown` receipt without `effectVerified`, not a fabricated success or non-execution result. Artifact discovery understands the legacy unknown-status text prefix, so both typed and legacy receipts retain export access. Disk failure is reported conservatively: retention may be incomplete. No path retries the paid POST, a tool execution or a failed write. The existing one-time retry of an idempotent signed-object download remains unchanged.

Only successful publication of every validated image allows redundant response/download copies to be removed. The published references and invocation identity remain. Conversation deletion explicitly deletes its matching journals; late writers open existing directories and cannot recreate a deleted journal. Original bytes already received remain private after cancellation or revocation, without publishing artifacts to a revoked session.

## Self-review and focused validation

Self-review preceded functional tests. It added publication-size/scope checks, counted partially cleaned journals against the pending quota, retained in-memory download output when its private write fails, and added complete-frame checks. No full suite was run.

Build commands used `scripts/test_runtime.child_environment()` and:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
```

Both the XCTest binary and media helper had `__llvm_covmap` and `__llvm_prf_cnts` before testing. There was no discovery rebuild. The initial prebuilt command was:

```sh
swift test --build-system native --skip-build --enable-code-coverage --no-parallel \
  --filter '^Typeflux(?:Focused)?Tests[./](?:AskGeneratedImageIsolationTests|AskImageGenerationTests|AskImageToolTests|MediaProtocolTests|MediaWorkerTests|AskSecureDirectoryTests)[./]'
```

The scope maps to retention/cancellation/partial outcomes, provider contracts and download policy, approval/receipt/local-engine/cloud callers, the new metadata operation, and shared process/secure-file ownership. Synthetic media and injected providers were used; no paid request was sent. Existing worker crash/hang, protocol and collection tests were included. Native PNG/JPEG validation, malformed/truncated data, GIF refusal and excessive dimensions were exercised through the actual helper.

Initial pass: **51 methods, 11 failed methods / 18 reported assertions-errors**. The implementation used the prefixed `AskToolPolicy.digest` value as an ID while the recovery reader expected 64 hex characters. This broke recovery reads and an injected validator checking retention. The fix uses the existing pure-hex directory hash. New tool fixtures also returned OpenAI payloads while configured for Google; three fixtures were corrected, including the publication-failure fixture whose intended path had not been reached. No timeout was increased.

After correction and another instrumented build, the smallest affected suite scope was:

```sh
swift test --build-system native --skip-build --enable-code-coverage --no-parallel \
  --filter '^Typeflux(?:Focused)?Tests[./](?:AskGeneratedImageIsolationTests|AskImageToolTests)[./]'
```

**19/19 passed.** A final receipt audit then tightened incomplete outcomes to `unknown` without `effectVerified` and preserved artifact discovery through the legacy status prefix. Two preparation builds completed; the final `AskImageToolTests`-only prebuilt pass passed **9/9**, including both typed/legacy discovery of an unvalidated binary artifact. Overall, 51 distinct methods were validated across this run and its corrections. The other 32 methods passed their initial run; they are not claimed to have been rerun. `python3 -m unittest scripts.tests.test_media_packaging` passed **2/2**. A freshly copied `Fixture.app/Contents/Helpers/TypefluxMediaHelper` accepted a synthetic PNG and returned matching request ID, PNG MIME and 2×2 dimensions for the new operation.

| Command | Wall time |
| --- | ---: |
| Initial instrumented preparation build | 247.32 s |
| Self-review completion build | 41.77 s |
| Initial focused test pass | 17.37 s |
| Initial bundled-helper probe | 0.131 s |
| Correction build | 50.57 s |
| Affected-suite correction pass | 10.29 s |
| Packaging tests | 0.238 s |
| Final bundled-helper probe | 0.141 s |
| Receipt-semantics preparation build | 86.47 s |
| Legacy-receipt completion build | 57.14 s |
| Final tool-receipt pass | 8.80 s |
| Total tracked build/test/probe commands | **520.24 s** |

Coverage extraction, binary inspection and hashes are additional. The final changed executable-line result is **241/241 (100%)**, detailed in `generated-images-coverage.json`. Coverage uses matching binaries/profiles per file: the four retention-correction profiles (three host, one copied-helper probe) for the six production files unchanged after that correction; the three final receipt-build host profiles for `AskLocalTools+ImageGeneration.swift` and `AskActivity.swift`. Every profile was individually validated before merging within its own build; the helper is supplied as `llvm-cov --object`. Initial failed-pass profiles were saved for diagnosis but are **not** included. No cross-layout profile merge or reused prior-increment results.

SHA-256:

- Retention-correction XCTest binary: `580ee560e65386d20b7ab080c55a7eea624faba8333a902b034b0b661e71c335`
- Final receipt XCTest binary: `feccb2c6de12b1315d76fa8d5962e800dae7739755750c762a3d43e32aa6cff8`
- Media helper (unchanged between these builds): `2e3c7c0f8081a150c102e2ee153922c05037d4986047295420021c6de6e79741`

The helper's Mach-O minimum OS is 13.0. The application has zero `TypefluxMediaRuntime` symbols; the helper has 265. This is linkage evidence, not a complete Xcode or signed-release validation.

## Remaining boundaries

- The journal has a scope-checked explicit read API and incomplete binary artifacts have the existing Save action. A user-facing recovery browser/revalidation action for private-only records (including cancelled/revoked results and later publication recovery) is still needed. Opening that UI must never dispatch generation or reset an invocation identity. Reaching the pending quota currently requires explicit conversation cleanup; no automatic eviction is introduced.
- Server-backed generated-image `AsyncImage` in `AskActivityViews.swift` still downloads/decodes in the host. Composer/attachment/provenance/recovery encoded image surfaces, workflow image inspection, favicons and Finder icons are separate remaining paths. Existing file-index and semantic workers are not reimplemented here.
- Filesystem and JSON/base64 processing, raw bitmap display, screenshots/encoding, SQLite/import-export and UI remain in-process. Disk-full, abrupt host death, power loss and external filesystem modification cannot be made lossless by this journal. No arbitrary host crash, system-wide OOM, GPU-memory or power-loss durability guarantee is claimed.
- 100% changed-line coverage is not branch coverage, exhaustive native-format testing, allocation-failure testing or watchdog-signal coverage. No real provider, microphone/TCC, Developer ID/notarization, full Xcode build, Intel/macOS 13 hardware, CoreML performance or real AppKit quit/recording validation was performed.
- Remaining stage-2 module adapters/condition-driven lifecycle/health integration and stage-4 audio/TCC/signing/performance validation still apply. GUL-399 remains `in_progress`.
