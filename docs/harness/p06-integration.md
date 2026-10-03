# P06 result integration and validation

## Fixed integration base

Adapter [#265](https://github.com/mylxsw/typeflux/pull/265) targets `main` at
`2e5130f8ca4867ad2438e785acd22d19366f20d5`. Its refreshed history contains only
adapter work above that base; obsolete standalone P02 commits are no longer
prerequisites or duplicated ancestors.

The base already contains these squash merges:

- P02 [#261](https://github.com/mylxsw/typeflux/pull/261):
  `fe1d68e446d715ad9f20e3517d2c170191ec4af9` (final reviewed head
  `a9ebc93d5f2788e49f4155a78223ad35f3ae5d8a`).
- P06 core [#262](https://github.com/mylxsw/typeflux/pull/262):
  `2506ffcdd9dc17e1108bc6a65ddfc8df39cd9684` (final reviewed head
  `297e812391d38adddc5c744659282ec51ee0f643`).
- P09 independent executors [#266](https://github.com/mylxsw/typeflux/pull/266):
  `2e5130f8ca4867ad2438e785acd22d19366f20d5`. These arrived on main externally;
  this adapter neither changes the executors nor wires them into production.

The API dependency [typeflux-api#97](https://github.com/mylxsw/typeflux-api/pull/97)
is merged; the tested API implementation is
`af80255b172d650b170db7382e97ae45779efcb8`. Schema/outcome fixtures in both
repositories match byte-for-byte.

P02's final `AskLocalTools`, approval target/dispatch implementation, MCP registry
and folder-grant regression tests match the fixed base byte-for-byte. P06 adds
only a read-only grant snapshot and receipt recording to the approval path. Full
pending-call comparison, journal claim, single-use grant consumption, final
binding resolution and late `authorize` callbacks remain in place. Stored
receipts cannot be imported as grants. Unknown executions are never replayed.
Production `run_code`, approval reuse and typed-content rollout remain disabled;
browser/computer bindings do not offer reuse.

Five engine reentrancy fixtures use a suspended configured mock `web_search`
after P08 disabled general `web_fetch`. Every existing cancellation, deletion,
memory-purge and duplicate-receipt assertion is retained. The refreshed tests
also assert denied/unknown statuses and grant consumption in persisted receipts.
P09 can integrate serially on the adapter's fixed implementation commit below;
no automatic merge, production rollout or later-phase work is included here.

## Runtime behavior

The core preserves raw MCP schemas and bounded ordered content; see
[p06-core.md](p06-core.md) for its supported offline validator subset and limits.
This adapter carries outcomes through execution, the SQLite tool journal,
conversation cache, Local engine storage, HTTP receipts and displayed results.
Go carries the same optional envelope through authenticated storage, snapshots,
SSE, Cloud inference and Cloud custom-model inference.

Typed blocks include text, every supported image, structured content, embedded
resources, resource links and unknown metadata. Unsupported blocks produce visible
notices. Large blocks/results receive explicit truncation markers. Audio is not
played, resources are not downloaded and binary content is not executed.
Multiple images are model observations only when the run's trusted rollout flag
is enabled. UI state uses the executor outcome; a complete modern multi-image
result is not marked failed merely because its single-image legacy projection is
incomplete. `ok` records executor completion, not verified business effect.

`AskAPIClient` sends the optional harness only with a trusted injected peer plus
the local capability flag. Both default to disabled. Local engine provider
projection and server `Engine.TypedContentEnabled` likewise default to false and
are pinned per run. Model/user payload capabilities cannot enable them. When an
old server drops additive fields, the client restores its local receipt metadata
and reconciles it only with the same message/call. Deleting messages still deletes
their metadata. Old caches and old clients retain text/image/error compatibility;
incomplete legacy delivery is explicitly an error, never empty success.

Local and server messages add operation/run/step/call diagnostics with normalized
status, content count and truncation. These fields exclude raw content, paths,
URLs, argument hashes and approval constraints. Full execution/approval/target
context is authenticated history, not telemetry or authorization. The server
checks any supplied context against its authenticated owner and pending call.

Gemini receives the preserved schema through its
[`FunctionDeclaration.parametersJsonSchema`](https://ai.google.dev/api/generate-content#FunctionDeclaration)
field, with no lossy conversion to the narrower `parameters` form. Anthropic's
`input_schema` and OpenAI-compatible JSON payloads preserve the object. The offline
executor rejects unsupported validation constructs before MCP dispatch; provider
schema rejection remains an explicit inference error. P07 token/thinking/fallback
behavior is unchanged.

## Validation scope

This refresh runs the combined Swift mainline (P02, core and independent P09)
with the adapter, using deterministic provider/MCP doubles, Local engine storage,
SQLite reopen and native UI test suites. The compatibility checks cover complete
schema/provider payloads, typed outputs and downgrade, old-cache reconciliation,
owner isolation, approval revocation, changed pending calls, unknown journal
claims and preserved engine reentrancy assertions. It also re-runs the unchanged
API dependency; API results are reported separately from Swift results.

No live paid model, external MCP server or end-to-end Swift-to-Go-to-paid-model
deployment is claimed. Actual browser/desktop acceptance remains opt-in; passing
deterministic executor tests does not establish human desktop acceptance.

## Fresh refresh results (2026-10-03)

Environment: macOS 26.6.2 arm64, Apple Swift 6.4, Go 1.27.0. Fixed adapter
implementation for P09 integration:
`0fd06854f0bfa7755124bcc999680512a5172e5f`. The documentation commit that follows
changes no production or test code. Earlier reports for `e42eae08`/`390c466f` are
historical and are not evidence for this refreshed tree.

- Focused MCP/contract/typed-content/approval/conversation/provider/engine tests:
  164 XCTest and 63 Swift Testing tests passed, zero failures or skips.
- Final adapter `make coverage`: 2,668 XCTest reported, 2,664 passed and four
  skipped, zero failures. Swift Testing reported 686 tests in 94 suites; one test
  failed with four assertions, so the full run is **not green**.
- Failure: `AskAccountFooterClickTests.accountNameClickTogglesTheAccountCard`
  at lines 37, 39, 43 and 44 (popup visibility and pointer containment). No window
  event code or test assertion was weakened. Command keyboard tests passed in
  this full run; earlier command failures are not copied forward as new results.
- The four explicit XCTest skips are the memory-settings snapshot test
  (`TYPEFLUX_MEMORY_NOTES_SNAPSHOTS`) and P09's real Chrome, Safari and desktop
  acceptance tests (`TYPEFLUX_AUTOMATION_ACCEPTANCE` and macOS permissions).
  Other opt-in visual/live tests may return without exercising their optional
  environment; runner pass counts do not establish live acceptance.
- Strict SwiftLint with the repository baseline fails with 1,008 violations;
  the unchanged fixed main has 1,013. This is a remaining repository check
  failure, not a lint pass. All five localization files pass `plutil -lint`;
  `git diff --check` passes.
- Fresh API `go test -count=1 -json -coverprofile=... ./...`: 44 packages pass,
  1,394 passing test/subtest events and 11 optional integration skips.
- Fresh API `./internal/...` coverage run with `ASK_REQUIRE_DATABASE_TESTS=1`
  and a task-owned PostgreSQL 17.11 container: 37 packages pass, 1,385 passing
  test/subtest events, zero failures and six unrelated optional skips. This run
  exercises all five Ask PostgreSQL tests, including typed-content reopen,
  concurrent persistence and pending usage. The container was removed after
  the foreground test command completed. `go vet ./...` passes.
- The six remaining Go skips are migration timeout integration, the city
  database, client analytics PostgreSQL, IP intelligence PostgreSQL, release
  analytics PostgreSQL and sync PostgreSQL. These are not counted as passes.
- API internal-package coverage is 83.9%; the content helper is 98/102
  statements (96.08%). The repository's 80% floor is met; the strict 90% target
  remains unmet. This refresh makes no API source changes.

A fresh detached worktree at fixed main `2e5130f8` ran the full instrumented
suite using the same toolchain. It reported 2,664 XCTest tests, four skips and
73 assertion/error failures (including two unexpected errors) across the five
old `AskLocalEngineReentrancyTests`. All five pass on the adapter's preserved
search fixtures. Its Swift Testing run reported 684 tests with one failure:
`OverlayTransitionRenderingTests.recordingHintStaysCenteredAndFollowsTheCapsuleDuringMorphing`
(`bands.first`, one assertion). The baseline account-popup test passed, so this
comparison does not clear the candidate's different native UI failure.

On the fixed adapter implementation, the final focused replay again passed
164 XCTest and 63 Swift Testing tests, with zero skips. A separate
`swift test --skip-build --enable-code-coverage --filter AskAccountFooterClickTests`
then passed its one test. This isolated pass is consistent with focus-sensitive
native UI interaction; it does not replace the failing full-suite result or
establish a root cause. No production/test source changed between these runs.

Swift coverage below uses only the final adapter's full-run profiles, exported
before rebuilding the baseline or running any further filter. Counts are llvm-cov
executable lines, summed over `Sources/` while excluding dependency and test
files. Changed-line coverage intersects `git diff --unified=0` against the fixed
main with executable source lines reported by `llvm-cov show`.

| Scope | Covered / executable | Coverage |
|---|---:|---:|
| Adapter changed executable lines | 90 / 98 | 91.84% |
| Typed-content core | 172 / 182 | 94.51% |
| Offline validator | 218 / 221 | 98.64% |
| MCP message codecs | 200 / 207 | 96.62% |
| MCP adapter | 50 / 54 | 92.59% |
| Provider conversion | 221 / 236 | 93.64% |
| Local prompt | 181 / 193 | 93.78% |
| Local engine | 478 / 499 | 95.79% |
| Conversation model | 1,286 / 1,365 | 94.21% |
| Activity collection | 149 / 151 | 98.68% |
| Approval policy/store | 111 / 111 | 100% |
| Approval target/dispatch boundary | 199 / 215 | 92.56% |
| Existing HTTP client, whole file | 91 / 122 | 74.59% |
| Existing local tools, whole file | 291 / 441 | 65.99% |
| Fixed main production total (separate full run) | 66,943 / 127,471 | 52.52% |
| Combined production total | 67,026 / 127,572 | 52.54% |

The eight uncovered added executable lines are the tool-detail result pane's
text/image rendering (`AskActivityViews`). Changed-line coverage exceeds 90%;
whole-file and whole-app figures have the limitations shown above. Coverage is
line coverage, not proof of complete branch, permission or real-world behavior.

Reproduce the Swift check with `make coverage`. The coverage script recognizes
both SwiftPM and Swift Build test bundles and exits nonzero on test failure.
For a failed test run, export its existing profiles without suppressing that exit:

```sh
BIN=$(swift build --show-bin-path)
xcrun llvm-profdata merge -sparse "$BIN"/codecov/*.profraw -o full.profdata
xcrun llvm-cov export "$BIN/TypefluxTests.xctest/Contents/MacOS/TypefluxTests" \
  -instr-profile=full.profdata -summary-only > full-coverage.json
```

No historical profile, missing GitHub check or merged PR is treated as a passing
test. The integration base remains suitable for P09's serial source integration;
native UI and live-environment acceptance limitations remain explicit.

## Rollback

Keep additive API fields and stored history. Disable client typed sending and
Local/server model projection. Scoped approval reuse remains disabled. This task
introduces no database migration, production deployment or later-phase work.
