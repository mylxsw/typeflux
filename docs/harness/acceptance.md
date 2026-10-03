# Harness acceptance register (GUL-166)

This register converts GUL-165 findings F1–F10 into reviewable acceptance cases. Evidence labels describe the **2026-10-03 assessment**, not new reproductions by P00. `Reproduced` means the earlier synthetic probe reproduced the behavior; `Source fact` means source/control-flow evidence; `Unverified risk` means no dynamic acceptance evidence. P00 does not mark sibling fixes accepted. Use their final PR SHA and the combined-mainline test run to close a case.

| Finding / owner | Original evidence | Required acceptance case and oracle | Existing entry point / remaining work |
|---|---|---|---|
| F1 / GUL-167 | Reproduced: host script write follows workspace symlink | `SANDBOX-01`: symlink file, swapped directory and synchronized concurrent replacement; a sentinel outside the authorized root is unchanged. Exercise host preparation as well as sandbox execution. | `AskAgentToolsTests.testLocalToolsExecuteFilesCodeSkillsAndMemory`; hardened path-specific regression is owed by P01. |
| F2 / GUL-168 | Source fact + existing grant tests | `POLICY-01`: alter action, target, arguments, owner/session, expiry and revocation after approval; deny before dispatch. A consumed single-use approval cannot execute twice; old tool-name grants cannot authorize new scope. Sensitive send/pay/delete actions require the applicable explicit approval. | Existing Ask approval tests plus P00 `negotiation.json`; fixtures cover feature gating only. Scoped policy execution tests remain P02. |
| F3 / GUL-167 | Reproduced with fake environment secret and sibling sentinel | `SANDBOX-02`: a synthetic inherited secret and another session's file cannot be read; supported interpreters/libraries still work and analysis code stays offline. | P01 must use a minimum environment/read-root allowlist and real-process probes. No real secret may be used. |
| F4 / GUL-169 | Source fact: stale copy after awaited local web tool; dynamic race was unverified | `MEMORY-01`: suspend web tool with a barrier, purge memory, then release; read store, stream and prompt after tool completion and after restart. No purged snapshot reappears. Also test cancellation and another account. | `AskLocalEngineTests`, existing memory tests; P03 owns deterministic race regression. PG purge/CAS test below is a separate persistence invariant, not proof of this local fix. |
| F5 / GUL-167 | Reproduced: parent exit leaves child holding output pipe; full cancellation coverage unverified | `PROCESS-01`: parent exits first, descendant holds pipe, ignores TERM, floods output; timeout and cancellation both return bounded results, drain is bounded and owned resources disappear. Include controlled timeout/cancel race and declared setsid/daemonize limits. | P01 real-process tests. Target cleanup latency <=2 s after deadline is **provisional**, not calibrated by P00 and not an established SLO. Record monotonic elapsed time and supported process model when measured. |
| F6 / GUL-171 | Source fact + isolated protocol probe | `MCP-01`: strict server requires initialized; SSE sends notification before matching response, wrong ID, multiple/partial frames, keepalive and connection close; select the matching response and recover/expire deterministically. | `HTTPMCPClientTests`; P05 adds strict transport fixtures. P00 does not claim a live MCP server test. |
| F7 / GUL-173 | Source fact + schema probe | `MCP-02`: nested required/enum/oneOf/$ref/additionalProperties and vendor keys survive tool adapters; multiple images/audio/resources/unknown blocks survive Local, Cloud+Cloud and Cloud+custom paths or yield explicit unsupported results. Verify budget/truncation and no silent successful reduction. | P00 opaque-content and interop fixtures pass only at the DTO layer. P06 owes provider, server storage/stream and UI integration. |
| F8 / GUL-172 | Reproduced in isolated native-request conversion | `PROVIDER-01`: max_tokens maps to Gemini native output limit on regular/tool/thinking rounds; verify OpenAI/Anthropic envelopes retain constraints and custom-model path sends the expected request. | Existing provider/inference tests; P07 owns mapping regression. No real model call or spend is required for this deterministic case. |
| F9 / GUL-175 | Source fact; real desktop E2E unverified | `TARGET-01`: capture, then change app/PID instance/window/tab/document generation; write action must require fresh observation. Timestamp-only matching must fail. Drag cancellation releases input. Separate event dispatch from verified effect. | `AskAgentToolsTests.testComputerAndBrowserDispatchWithoutTouchingTheDesktop` is a stub baseline; P00 reference round-trip preserves evidence fields. P09 owes real Safari/Chrome/AX acceptance. |
| F10 / GUL-170 | Reproduced with synthetic disk failure | `MEMORY-02`: disk failure on add/delete cannot report durable success; retry identical add while disk still fails must fail; recover storage and restart to verify committed state. | `AskAgentToolsTests.testMemoryNotesPersistAndFeedTheMemory`; P04 adds fault-injected persistence regression. |

Additional network case `NET-01` / GUL-174 remains an **unverified risk** from the original assessment: bind validated DNS addresses to the actual connection and re-check redirects, mixed IPv4/IPv6 answers, mapped IPv6 and private/link-local/loopback transitions. Static URL checks alone cannot close it.

## P00 executable checks

| Case | Command / test | Acceptance |
|---|---|---|
| WIRE-01 | Go `TestHarnessContractRoundTrip`, Swift `testContractRoundTripPreservesReferencesAndOpaqueContent` | Same seven ordered content objects, raw vendor keys, references, zero duration and false evidence flags survive decoding/encoding. |
| WIRE-02 | Both fixture-manifest tests and cross-repository directory diff | Seven versioned JSON files have matching pinned byte hashes. |
| COMPAT-01 | Both legacy snapshot/result tests | Legacy sessions decode without `harness`; omitted fields remain absent; a legacy subset reader can read new snapshots; unsupported rich results expose an error projection. |
| COMPAT-02 | Both negotiation fixture tests | Ten cases cover old/new pairs, absent capabilities, unknown version/name, disabled default and explicit mutual opt-in. Gate success alone cannot authorize side effects. |
| MODE-01 | Both mode-fixture tests | Local, Cloud+Cloud and Cloud+custom route descriptors decode; all new flags stay off. These are prepared fixtures, not live model E2E. |
| PG-01 | `TestPostgresIsolationAndConcurrentSave` | Real migration; ownership isolation; exactly one concurrent CAS wins; usage identity/version and cascading deletion. |
| PG-02 | `TestPostgresPurgeMemoryKeepsRevisionsAligned` | Purge keeps SQL/JSON revision aligned; subsequent CAS succeeds; another owner's memory is unchanged. |
| PG-03 | `TestPostgresSteeringStore` | Durable ordered, deduplicated steering; run isolation; foreign key and cleanup; migration rollback. |
| PG-04 | `scripts/test_ask_postgres.sh` with empty URL; direct tests with `ASK_REQUIRE_DATABASE_TESTS=1` | Dedicated gate exits nonzero on missing/blank URL; required tests fail instead of skipping. Gate verifies the three names actually passed and no test skipped. |

## Running database acceptance

Use disposable PostgreSQL 16 and 17 databases, never a production URL. Each Ask test creates a unique schema and drops it with CASCADE on completion. It applies real migration SQL to that schema and requires schema-creation privileges. The CLI must not print the connection secret. For each version:

```sh
export ASK_TEST_DATABASE_URL='<isolated PostgreSQL test URL>'
./scripts/test_ask_postgres.sh
ASK_REQUIRE_DATABASE_TESTS=1 go test -count=1 -race -coverprofile=ask.cover ./internal/ask/...
go test -race ./internal/transport/http/handler -run '^TestAsk'
```

CI retains the existing authorized `@autotest` PR-comment trigger. The PG16/17 matrix configures Ask, analytics and sync database URLs at job scope, so both tests and coverage receive them. The dedicated gate uses `-count=1`, `-race`, exact test names and JSON event verification; cached results, skipped tests and accidental renaming cannot satisfy it. It requires Python 3 (available on the existing Ubuntu runner and macOS development setup). Ordinary local unit runs may still skip DB tests unless `ASK_REQUIRE_DATABASE_TESTS=1` is set.

## Release and evidence boundaries

The baseline report lists current local results and denominators separately from this forward-looking register. Real model calls, desktop permissions/actions, strict remote MCP servers, and all future-stage workers remain separate acceptance environments. Do not close F1–F10 from green DTO tests. Do not start stages 2/3 or deploy production from this PR.
