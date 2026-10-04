# R06 client integration and rollback validation

GUL-185 retains **human acceptance and a production rollout hold**. The companion
API release record contains the combined fault matrix, measured task format and
operator commands: `typeflux-api/docs/harness/r06-release.md`. This PR changes
only tests and evidence documentation; it enables no client capability or setting.

## Revisions

Initial baseline: `da1d8b7b8bef7f6b4bb3852017bcc218bef59001`.
Final base: `cdf4438c4638aca7c4694ea2a9ad2f5599dc392a` (#285 effort picker update).
Client test implementation: `b492866f70a3fd6d541ae073455c8d6341c0eb9c`.
API implementation: `8eeb12a4782343a94f686a762a5b43c5b79e7ef1`; final gate driver:
`f095eb2d8fd858523a8a8c09f3e0a80d60f67e7c`. Later changes are reports only.

## Added checks

`AskReleaseAcceptanceTests` combines real scoped approval consumption, SQLite
claims and immutable receipt storage, diagnostics, legacy projection and deletion
retention. Approval reset cannot recreate dispatch authority. Retained SQLite
receipt **bytes** are compared before and after rollback/deletion; raw JSON object
key ordering is not treated as semantic inequality.

Its project rollback test starts a real isolated Python process, performs orderly
runtime shutdown, verifies the owned PID has disappeared, closes the previous
runtime lock, reconstructs a disabled runtime and rejects further execution. A
disabled preview cannot open, while the original source and independently stored
artifact can still be read and exported with matching bytes. This does not claim
cleanup of descendants following host SIGKILL.

`AskReleaseHTTPTests` is invoked by the API's foreground
`TestReleaseSwiftHTTPBridge` driver. It uses real loopback HTTP, production JWT
middleware/handlers, a durable worker and a new PostgreSQL schema, with scripted
custom inference. It covers original device binding, foreign device/account
denial, duplicate receipt delivery, typed duration/content, purge and old client
metadata reads. Uppercase UUIDs exposed and reproduced an API SQL/JSON identity
comparison defect; the companion PR fixes comparison by validated UUID value.
The test does not stand in for a real provider or external device action.

```sh
# In the API checkout, with a disposable DB configured:
ASK_REQUIRE_SWIFT_BRIDGE=1 ASK_SWIFT_CHECKOUT=/path/to/typeflux \
  go test -count=1 -race -v ./internal/transport/http/handler \
  -run '^TestReleaseSwiftHTTPBridge$'

# In the client checkout, collect current native/process evidence:
TYPEFLUX_D04_EVIDENCE=/path/to/private/evidence make coverage
```

## Current measurements

| Check | Current result |
| --- | --- |
| Initial base `da1d8b7b` full `make coverage` | Pass: 2,813 XCTest (5 skips), 823 Swift Testing. Superseded by latest-base validation. |
| Latest base `cdf4438c` full `make coverage` | Exit 2: 2,813 XCTest (5 skips), no XCTest failures; 825 Swift Testing, account-card click test fails four assertions. |
| Final branch `make coverage` | Exit 0: 2,816 XCTest (6 skips), zero failures; 825 Swift Testing pass. The account-card test remains unstable despite this passing run. |
| All-source executable lines | 75,021/135,681 = 55.2922%, versus same-base 75,020/135,681 = 55.2915%; no decline. |
| Review / artifact / terminal UI | 71.43% / 70.98% / 62.71%; all remain below 90%. |
| SwiftLint | Base and branch: 3,067 findings (595 errors, 2,472 warnings). New test files pass strict lint; whole-repository lint fails. |
| Isolated approval/journal/rollback | Two new native tests pass. Original receipt bytes, audit binding, source and exported artifact survive. |
| Live HTTP/PG bridge | One Swift XCTest, zero skips, driven by API test with race enabled. |

macOS 26.6.2 (25G83), arm64, Swift 6.4. LLVM source denominator excludes `.build`
and `Tests`, exactly as the repository coverage script. The baseline failed in
Swift Testing, so its XCTest and Swift Testing raw profiles were explicitly merged
for comparison. That measurement does not turn its failed gate into a pass. R06
changes no client production module; the 90% modified-core target applies to the
companion API (95.5% selected core, 100% new report/UUID helper).

Orderly project shutdown in the final full run took 0.194666 ms (one measured
sample; p50 = p95 for n=1). This is a local fixture timing, not a cancellation SLO
or evidence about host SIGKILL. See the combined report for server cancellation
and fixed engine-task timings.

The six full-suite XCTest skips are explicitly accounted for: three interactive
browser/desktop automation cases require their opt-in and native permissions;
two settings snapshot fixtures require dedicated output paths; the new live HTTP
case requires the Go bridge. That HTTP case is separately executed with zero
skips. None of the other five is counted as accepted real automation. The API
helper remains inactive in ordinary Go runs; only the explicit bridge run counts.

Current D04 frontend/static evidence is captured during this run using actual
sandbox processes and WebKit, including nonce readiness, rendered text, screenshots,
console/error collection, opened/exported artifact hashes and process/port cleanup.
The API consumes these JSON files and checks the corresponding image hashes;
missing files/skips fail the combined gate. Terminal screenshots are synthetic
native view states, distinct from real process/page evidence.

## Remaining release gates

The API full-race run still reproduces `TestAliyunClient_Flow_WithMockServer` and
`TestASRWS_AliyunAutoAdaptsWAV`. Its internal coverage remains below strict 90%.
Client UI coverage and repository-wide lint remain below the requested standard.
The account-card event-delivery failure remains an unresolved release gate even
when one run passes; integrated-main reproduction does not waive it.

No dedicated real-provider/model-version/billing setup, external MCP fixture,
two-physical-device setup or complete browser/computer native permission matrix
was exercised. There is no measured production success rate, spend or p95 SLO.
Full GUI App SIGKILL remains unverified; existing SQLite subprocess SIGKILL tests
cover only their two storage boundaries. WebKit SPI across OS versions and full
runtime resource-limit acceptance remain open. D02 Python orphan cleanup after
host SIGKILL remains not guaranteed.

The isolated rollback tests retain execution journals, Memory tombstones, unknown
operations, history and artifacts. They never replay unknown effects or convert
durable work to the old runner. Existing external effects require reconciliation.
Worker/automatic recovery, Memory/budget rollout, project/runtime/artifact/preview,
analysis execution, local web fetch, browser/computer writes, approval reuse and
new protocol capabilities stay default-off. Merge, done and production enablement
remain user decisions.
