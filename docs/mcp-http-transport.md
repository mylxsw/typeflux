# MCP HTTP transport contract

GUL-171 repairs the existing HTTP transport. It does not enable a new agent
capability or change the shared MCP schema/content DTOs owned by P06.

## Supported subset

- Streamable HTTP POST with a single JSON-RPC message per request, accepting
  `application/json` and `text/event-stream` responses.
- Initialization requests MCP **2025-06-18** and accepts **2025-03-26** for the
  same POST/tools subset. Unsupported revisions fail explicitly. No client
  sampling, roots or elicitation capabilities are advertised.
- `notifications/initialized` must receive HTTP 202 before the client is ready.
  Negotiated version and session headers apply to this notification and every
  subsequent POST; static configuration cannot override them.
- Paged `tools/list`, `tools/call`, and ping. Shared schema/content decoding is
  unchanged. Tool `isError` content remains a tool result; JSON-RPC errors are
  thrown with the server's code and diagnostic message, including for ping.
- Incremental POST SSE: CR, LF, CRLF, initial BOM, comments, empty events,
  multiline data, and UTF-8 split across chunks. Only a complete event whose
  JSON-RPC ID **and ID type** match can complete a request. Unrelated responses
  are ignored. Notifications (including progress/logging) have a separate
  callback; tools/list_changed refreshes the Registry. Server ping is answered;
  other server requests receive -32601. Frames after the matched response are
  not consumed. EOF cannot turn an incomplete frame into success.

GET notification streams, Last-Event-ID recovery, legacy 2024-11-05 HTTP+SSE,
resource subscriptions, progress-token generation, and session DELETE are not
implemented. Notifications are available only while a POST stream is active;
this does not promise continuous server notifications. Existing stdio behavior
and OAuth discovery/PKCE/refresh are unchanged.

The protocol references are the MCP
[2025-06-18 transport specification](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports)
and [lifecycle specification](https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle).

## Lifetime and recovery

Each HTTP attempt owns its URLSession task, response parser and absolute timer.
The default is 60 seconds, configurable with `MCPHTTPConfig.requestTimeout`;
progress never resets it. Each JSON response or SSE event is limited to 8 MiB
by default. Cancellation, timeout, EOF and disconnect release the pending entry
and cancel the transport task exactly once. Cancelling a request sends a best
effort MCP cancellation notification with a separate bound of at most one
second; this is not proof that the server stopped or rolled back the effect.
Initialization is not cancelled via an MCP notification. A caller cancelling a
shared connection attempt cancels that attempt for all waiters.

OAuth permits at most one retry per POST, and only after an explicit HTTP 401.
The HTTP attempt timer does not include the existing OAuth discovery/browser
flow; that flow retains its own network and callback timeouts. A second 401 is
reported. Disconnect during authorization cannot resurrect an old connection.

A session-bearing HTTP 404 clears the session; transport network failures also
invalidate connection state. The failed request is returned to its caller with
its diagnostic cause. A subsequent invocation establishes a fresh handshake
without the old session header. **No failed request is automatically replayed**
after session loss, disconnect or timeout, including tools marked read-only by
the server. A new explicit tools/call invocation is a new operation; callers
must resolve unknown effects before choosing to repeat one.

Registry bulk-connect paths check live connectivity, share concurrent connection
attempts, replace stale tool caches after reconnect, and retain failure reasons
through `lastConnectionError(for:)`. Removing a server invalidates in-flight
connects, refreshes and notification callbacks. Failure cleanup does not
invalidate an injected URLSession shared with other clients or OAuth.

Request diagnostics contain method, request ID and a URL with user information,
fragment and query values removed/redacted. Tool arguments, response bodies and
session/authentication headers are not logged by this transport.

## Verification

HTTP tests use an isolated URLProtocol server that controls headers, individual
data chunks, connection errors and EOF independently. It can leave streams open
and reject an incomplete handshake. Parser tests split a Unicode/multiline
fixture at every byte boundary. Registry tests exercise disconnect/reconnect,
shared registration, removal during connect/refresh, and retained diagnostics.
OAuth fixtures accept the newly required initialized notification. Stdio
pagination, notifications and OAuth tests remain part of the regression run.

Real third-party MCP services and an interactive desktop OAuth sign-in are
separate integration checks, not results implied by the deterministic fixtures.
No model or database integration is part of this transport-only change.

### Local verification, 2026-10-03

Environment: macOS 26 / arm64, Apple Swift 6.4. The starting main revision was
`41d207accecf2f33583be670ead46cf60d32769b`. The later GUL-164 main change concerns
Ask orb UI files; this branch does not incorporate or depend on that change.

The final focused command passed **98 tests, zero failures, zero skips**:

```sh
swift test --jobs 4 --enable-code-coverage --filter \
  'HTTPMCPClientTests|MCPSSEParserTests|MCPRegistry|MCPOAuthTests|StdioMCPClientTests|AskMCPToolsTests|MCPToolAdapterTests|MCPMessageTests'
```

Coverage from that instrumented run includes the entire four production files,
not only changed lines. The MCPClient protocol change is documentation only.

| Production file | Covered lines / instrumented lines | Line coverage | Region coverage |
| --- | ---: | ---: | ---: |
| HTTPMCPClient.swift | 289 / 291 | 99.31% | 93.29% |
| MCPHTTPExchange.swift | 176 / 179 | 98.32% | 96.30% |
| MCPRegistry.swift | 208 / 214 | 97.20% | 91.43% |
| MCPSSEParser.swift | 58 / 60 | 96.67% | 97.87% |
| Combined | 731 / 744 | 98.25% | 93.98% |

Strict SwiftLint on the four production files and `git diff --check` passed.
The baseline was measured locally in this run, before the production changes:

- Unmodified `swift test`: 2,547 XCTest cases passed; the 557-test Swift Testing
  run reported four assertions in `accountNameClickTogglesTheAccountCard` and
  one in `recordingHintsKeepTheirRoundedEndsInsideTheWindow(style: .classic)`.
- Unmodified `make coverage`: Swift Testing passed; stdio's existing
  `testStalledRequestTimesOut` timed out during initialization. The same stdio
  case passed in the initial baseline and the final focused regression.
- Baseline production-source coverage was **61,844 / 122,680 lines (50.41%)**.
  Failed full test runs still produce raw profiles; they were merged with
  `llvm-profdata` for measurement, without relabeling the run as passing.

Final full validation (`swift test --enable-code-coverage`, invoked by
`make coverage`) passed **2,569 XCTest + 557 Swift Testing tests = 3,126 tests**,
with zero failures and no reported skips. The prior UI/stdio failures above are
recorded as baseline variability, not silently omitted. Production-source total
coverage increased to **62,250 / 123,030 lines (50.60%)**. Both totals exclude
`.build` and `Tests` using the same LLVM coverage-report filter; they include
instrumented production code linked into the test binary, not unexecuted app
features or external services.

The `make coverage` command then exited 1 in its **report export step**: its
existing script expects `TypefluxPackageTests.xctest`, whereas Swift 6.4's build
system produces `TypefluxTests.xctest`. Tests had already passed. The same final
profile was exported successfully using the actual binary, without changing
the shared coverage script:

```sh
xcrun llvm-cov report \
  .build/out/Products/Debug/TypefluxTests.xctest/Contents/MacOS/TypefluxTests \
  --instr-profile=.build/out/Products/Debug/codecov/default.profdata \
  --ignore-filename-regex='.build|Tests'
xcrun llvm-cov show \
  .build/out/Products/Debug/TypefluxTests.xctest/Contents/MacOS/TypefluxTests \
  --instr-profile=.build/out/Products/Debug/codecov/default.profdata \
  --format=html --output-dir=coverage-report \
  --ignore-filename-regex='.build|Tests'
```
