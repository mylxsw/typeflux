# GUL-453 Swift validation

Baseline: main at `ba115260da3118d10e6ecb9b4ac57c4df930c565`.
Four immutable JSON fixtures were captured from the old builders before
extraction. They cover memory on/off, untrusted prior summary, selected context,
references/skills, tools, typed/media evidence, reasoning, environment,
pinned latest user, summary defaults and the actual bounded cut.

JSONEncoder randomizes object key order inside reference envelopes. The fixture
test canonicalizes only those embedded JSON object keys as well as the outer
payload structure. It preserves string contents, array order and every other
prompt byte. Production serialization and prompt wording are unchanged.
A small-window test additionally verifies excerpting and original-message indexes.

## Commands and results

All Swift commands ran from the repository. Wall times include preparation,
build/discovery, runner startup and execution. First use rebuilt dependencies;
retries rebuilt changed sources with the coverage configuration. No full test or
UI suite, external model, new permission or CI wait was used.

1. `CAPTURE_PROMPT_BASELINE=1 make test FILTER='AskPromptBuilderTests/testBaselineFixtures'`:
   fixture assertion passed; runner exited 2 because creating fixtures changed its
   inputs during testing. Runner wall 502.13 s. This is baseline capture evidence,
   not a successful final validation pass.
2. `CAPTURE_PROMPT_BASELINE=1 /usr/bin/time -p make test FILTER='AskPromptBuilderTests/testBaselineFixtures'`:
   refreshed baseline samples with typed evidence and nil environment cases;
   assertion passed, same intentional input-change rejection. Total wall 107.50 s
   (runner 107.20 s). Removed the updater before validation.
3. `/usr/bin/time -p make coverage SUITE='AskPromptBuilderTests AskLocalEngineTests AskLocalEngineReentrancyTests AskSemanticCompactionTests AskContextCompactionTests AskLocalBudgetTests AskLocalModeIntegrationTests AskThinkingModeTests AskAgentBindingTests'`:
   67 selected methods, 64 passed and three new fixture methods failed; exit 2,
   total wall 386.48 s (runner 383.83 s). Failures were embedded JSON key order,
   persisted date precision and the background fixture's image-weight estimate.
   Canonicalized embedded reference keys, pinned the test clock to whole seconds,
   and removed synthetic images from the threshold-only history fixture. Also
   renamed/formatted the new files to satisfy strict lint. Existing engine,
   wrapper and compaction source stayed unchanged after this pass.
4. `/usr/bin/time -p make coverage FILTER='AskPromptBuilderTests|AskApplicationAPITests/(productionConversationFactoryBuildsConfiguredDefaultEngine|productionCallerFactoriesRetainLocalStateAndCloudRoute|routedDefaultSharesLocalEngineStateAndHostAccess)'`:
   all eight selected methods passed, total wall 125.33 s (runner 115.72 s,
   including report generation afterward). This is the smallest containing new
   test class plus three default-factory/routing acceptance checks. The five port
   tests revalidate the formatted default implementation, queued payloads, usage,
   foreground summary boundary/request, asynchronous summary/hard admission and
   untouched persisted history. Factory checks retain the shared default engine,
   local/cloud routing and configured host limits.

5. Final acceptance review added one direct provenance/expired-source method:
   `/usr/bin/time -p make coverage FILTER='AskPromptBuilderTests/testMemoryProvenanceAndSourceExpiryRemainReadOnly'`:
   passed, total wall 117.23 s (runner 112.67 s). Valid provenance remains in the
   read-only snapshot, expired source memory is not injected, and private source/
   owner identifiers are not serialized into the prompt. Only this added method
   ran; production source was unchanged, with no additional broad coverage run.

The focused pass, retry and supplemental method provide passing evidence for
71 unique methods.
Raw logs are included as gzip files, including failed attempts.

## Coverage denominator

Changed production coverage: **120/121 unique executable source lines (99.17%)**.
The new default builder covers **96/96 unique executable lines**. This is focused
changed-code coverage, not whole-project coverage or a claim of full branch coverage.

`changed_swift_coverage.py` intersects added production lines against main with
LCOV `DA` entries, deduplicated by filename/physical line with the maximum hit
count. It counts all source lines of the new builder, excludes tests/docs, and
uses only the final formatted builder's own line map. Engine, wrappers and
compaction sources were unchanged between passes, so their original and retry
hits are unioned. The one uncovered line is the pre-existing default image
preparation closure in the edited initializer signature. Both raw LCOV exports
and exact per-file counts are included. Synthesized/overlapping LCOV entries are
merged by physical line, so this denominator differs from llvm-cov's filewide
summary, which also counts overlapping compiler-generated entries.

## Lint and self-review

Strict SwiftLint on the three new Swift files passes with no findings. Strict
lint on the three modified existing files still fails on existing issues;
compared with those exact files from main, there are no added rule counts
(line-length findings decrease from 100 to 97; other counts are unchanged).
`git diff --check` passes. Lint commands were:

- `/usr/bin/time -p swiftlint lint --strict --quiet --reporter json Sources/Typeflux/Ask/Local/AskPromptBuilder.swift Tests/TypefluxTests/AskPromptBuilderTests.swift Tests/TypefluxTests/AskPromptBuilderTests+Memory.swift`
  (passed, 0.66 s).
- `/usr/bin/time -p swiftlint lint --strict --quiet --reporter json Sources/Typeflux/Ask/Local/AskLocalEngine.swift Sources/Typeflux/Ask/Local/AskLocalPrompt.swift Sources/Typeflux/Ask/Local/AskSemanticCompaction.swift`
  (exit 2 for existing findings, 0.58 s). The baseline comparison uses those
  files extracted with `git show` from the baseline SHA and the same config;
  raw baseline/final findings are included.

Reviewed the complete queue, summary preparation/activation, boundary and context
usage paths. The port is synchronous and Sendable; no untyped payload crosses an
actor boundary and no unchecked Sendable conformance was introduced. The engine
retains memory sanitization and image preparation/revision checks at their old
positions. Builders receive value snapshots and explicit environment/policy,
never the local record or engine. No await, reservation, usage settlement,
lease/revision check, storage write or cancellation ownership moved across
admission. Existing reentrancy and cancellation tests pass. No new tasks are
introduced in production. Test tasks are released and awaited before completion;
temporary directories are removed. Default wrappers cannot recurse. Prompt
strings, original-message references and typed/media helpers are unchanged.
Title/research prompts, other host ports and alternate activation remain separate.
