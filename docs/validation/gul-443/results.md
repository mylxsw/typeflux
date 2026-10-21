# Validation results

Bases: Swift `54878ff626c3b700ef894e68331b72de6d7f3817`; Go
`45f7d42ae666cf162c3986b9cbef78a119e12a11`. Exact submitted heads are
reported in the PRs and final issue comment. Raw output, source hashes and
coverage inputs are delivered in the issue evidence archive.

## Results

- Swift: 39 selected methods passed (31 XCTest plus 8 Swift Testing). First
  build/discovery 374.05 s; full command including coverage report 388.209 s.
  Immutable-snapshot verification: 2 methods passed, 42.734 s including an
  incremental rebuild (33.62 s preparation). Neither run is a verified cache hit.
- Go: 61 unique top-level tests ultimately passed, including the durable cloud
  and custom-model C1 cases against an isolated PostgreSQL 16 container.
  The initial database skips were resolved by that explicit run (16.137 s).
  The container was stopped after verification. Local unit coverage never
  substitutes for the durable cases.
- Changed executable-line coverage: Swift 67/67 (100%); Go 93/93 (100%), target
  90%. The portable script intersects git-added/modified lines with measured
  executable lines. Go ranges come from instrumented blocks, LLVM counts from
  active source segments; this is line coverage, not branch coverage. The
  aggregate package coverage from this deliberately narrow scope is not a
  repository-wide coverage result. Go's new section functions and changed
  Conversation method also have 100% statement coverage.
- `git diff --check` passed in both repositories. Existing legacy fixture files
  have no diff. The shared 14-case scenario JSON files are byte-identical.

The first Go attempt failed to compile because the new test helper reused an
existing package helper name. It was renamed. The next run exposed old
message-count assertions after environment moved into the trusted prefix, and a
replay assertion that compared pre-sanitization JSON bytes with the existing
sanitizer's reordered read projection. Those tests were corrected without
changing execution or sanitization. Only failed methods and newly affected
memory/tool callers were retried. Initial Go commands took 3.935 s and 6.742 s;
failed-method retry 3.803 s; final two-method retry 6.025 s; additional affected
callers 5.620 s. Rich modular snapshot capture took 2.642 s; snapshot-only
verification without update mode took 5.314 s. All logs, including failures,
are retained. No unresolved test failures remain.

## Prompt bytes

Decoded trusted text in UTF-8, including environment but excluding system-message
JSON framing. Context/history byte counts are reported separately and are exact
within each platform's fixture; the platform fixtures intentionally differ.

| Route | Scenario | Legacy bytes | Modular bytes | Change | Unchanged context bytes |
| --- | --- | ---: | ---: | ---: | ---: |
| Swift local | no-tools | 1363 | 1005 | -358 | 675 |
| Swift local | web-only | 1626 | 1147 | -479 | 675 |
| Swift local | device-only | 1363 | 1099 | -264 | 675 |
| Swift local | mixed | 2217 | 2236 | +19 | 675 |
| Go cloud | no-tools | 1092 | 984 | -108 | 61137 |
| Go cloud | web-only | 1370 | 1126 | -244 | 61137 |
| Go cloud | device-only | 1160 | 1078 | -82 | 61137 |
| Go cloud | mixed | 2029 | 2215 | +186 | 61137 |

Mixed-tool growth (Swift +19; Go +186 bytes) retains schema-gated file
continuation/version guidance, command-result interpretation and run-scoped job
semantics, plus the common purpose/trust rules. These guarantees were not
removed to hit a percentage. Token estimates were not produced; no tokenizer or
model-quality result is implied.

## Commands and scope

Swift section selection/defaults/rollback/persisted replay and C1 main/queued,
foreground/background summary paths are covered by AskPromptBuilderTests and
AskPromptSectionsTests. AskSemanticCompactionTests and AskContextCompactionTests
cover latest-user/context preservation; AskTypedContentTests and
AskTypedContentIntegrationTests cover tool projections/media;
AskLocalModeIntegrationTests and AskRoutedAPITests cover the local route/factory.

```sh
# Initial capture only: explicitly create NEW modular snapshots, never legacy fixtures.
UPDATE_MODULAR_SNAPSHOTS=1 make coverage SUITE="AskPromptBuilderTests AskPromptSectionsTests AskSemanticCompactionTests AskContextCompactionTests AskTypedContentTests AskTypedContentIntegrationTests AskLocalModeIntegrationTests AskRoutedAPITests"
# Verify committed snapshots with no update flag.
make coverage FILTER='AskPromptBuilderTests/testBaselineFixtures|AskPromptSectionsTests/testSharedScenariosAndFullPayloadSnapshots'
```

Go's initial affected scope (with `UPDATE_MODULAR_SNAPSHOTS=1` for new snapshots):

```sh
go test ./internal/ask -run 'Test(Modular|Prompt|PostgresPrompt|Semantic|Cloud|Mobile|Send|Memory|Typed|Context|Inference|Summary|ActiveContext|Usage)' -coverprofile=go-cover.out -count=1 -v
# Only failed methods plus the explicitly changed history-count test:
go test ./internal/ask -run '^Test(SendPinsMemoryFromOpeningMessage|MemoryOffWithoutPinnedMemoryIsIgnored|SendWithoutMemoryKeepsPromptUnchanged|SendPinsPlatformAndCurrentDeviceTools|ModularPolicyDoesNotRewritePendingInference|ConversationHistoryAndIdempotency)$' -coverprofile=go-retry-cover.out -count=1 -v
# Final remaining failures:
go test ./internal/ask -run '^Test(SendPinsMemoryFromOpeningMessage|ModularPolicyDoesNotRewritePendingInference)$' -coverprofile=go-final-retry-cover.out -count=1 -v
# Newly affected memory/tool callers:
go test ./internal/ask -run '^Test(FollowUpCanSwitchPinnedMemoryOffAndOn|ToolLoopApprovalsDeviceBindingAndDuplicateResults|SanitizeMemoryMalformedAndExpiredPayloads|PurgeInvalidatesPendingInjectionButKeepsHistory)$' -count=1 -v
# Set ASK_TEST_DATABASE_URL to isolated local PostgreSQL, never production.
ASK_REQUIRE_DATABASE_TESTS=1 go test ./internal/ask -run '^TestPostgresPromptPortDurableRequests$' -count=1 -v -coverprofile=go-durable-cover.out
# Added rich/typed/etc. modular fixtures, then verify without updating:
UPDATE_MODULAR_SNAPSHOTS=1 go test ./internal/ask -run '^TestPromptBaselineFixtures$' -count=1 -v
go test ./internal/ask -run '^Test(PromptBaselineFixtures|ModularPromptScenarios)$' -count=1 -v
```

Run `changed_coverage.py --help` for portable reproduction with the delivered Go
profiles or LLVM export and the base above. Repeat `--go` to combine focused
runs by maximum line count; `--llvm` accepts LLVM export JSON. Supply `--file`
for each production builder/section file. The script was also checked with
synthetic covered/uncovered Go ranges and LLVM segments before measuring these
sources. The archive contains the pre-snapshot-recheck LLVM export, so the
39-method scope remains the reported coverage source.

## Final self-review

Checked the full entry-to-provider chain, default/injected policies and summary
paths; hostile/empty environment values, restricted/unknown/duplicate tools,
memory-on/off and pending replay; resource and concurrency ownership; authority,
injection, private-reasoning and truthful-result boundaries; comments and docs.
Fixed ambiguous duplicate-schema capability union during review and retained
existing memory sanitization rather than bypassing it for literal replay.
Builders introduce no async work, locks, persistent handles or runtime state.
Existing scopes, cancellation, denial and output serialization remain owned by
the host. Evaluation scenarios/rubric are reproducible plans only; no paid/live
model call or quality-gain claim was made.
