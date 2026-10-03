# R02 validation

Validation was run in this issue's isolated checkout on macOS/arm64 with Go,
Swift and an isolated PostgreSQL 16 Docker instance. No production service,
model, account, database or capability flag was changed.

## API

- `go test ./...`: passed on the delivery code.
- `go vet ./...` and `git diff --check`: passed.
- `ASK_REQUIRE_DATABASE_TESTS=1 go test ./internal/ask/... ./internal/config
  ./internal/transport/http/handler -race -coverprofile=ask-r02.cover -count=1`:
  passed with a real isolated PG16 database; Ask coverage 95.1%, Ask eval 98.2%.
- Real database tests exercise migration 40, concurrent independent connections,
  owner isolation, restart/reopen, late idempotent settlement after content CAS
  conflict, retained ambiguous usage and deletion cascade. No database skip is
  counted as passing.
- New core statement coverage: budget controller 97.20%, engine integration
  94.56%, HTTP admission 93.10%, store 100%, context planner 97.67%.
- Strict all-internal coverage command (`COVERAGE_STRICT=1
  ./scripts/check_coverage.sh 90`) ran its tests successfully and returned 1:
  84.5% is above the approved 80.0% baseline. The fixed R01 API dependency was
  independently checked out and its all-internal tests/coverage rerun against
  real PG16 during this task: 84.1%. Coverage therefore increases from 84.1%
  to 84.5%, but remains below the strict 90% whole-repository target.
- Whole-repository race run fails in unchanged ASR code:
  `TestAliyunClient_Flow_WithMockServer` and `TestASRWS_AliyunAutoAdaptsWAV`.
  These failures were rerun during R02; prior reports were not counted as tests.

## Client

- Final `make coverage` passed, including the complete `swift test` suite:
  2,781 XCTest cases with 4 skips and no failures, followed by 749 Swift Testing
  cases in 101 suites with no failures. Three skips require interactive browser
  or desktop permissions and `TYPEFLUX_AUTOMATION_ACCEPTANCE`; one optional R01
  memory screenshot requires `TYPEFLUX_MEMORY_NOTES_SNAPSHOTS`.
- Line coverage: budget controller 100%, journal store 96.55%, context planner
  96.40%, budget card 100%, local budget integration 97.64%, and LocalEngine
  94.31%. These are line metrics, not branch/function coverage or a claim that
  every modified UI/provider file reaches 90%.
- Whole-source line coverage is 54.52%. The fixed R01 report records 54.34%;
  the Swift baseline itself was not rerun in this task. Full-source coverage
  remains well below 90%.
- Strict SwiftLint passed on the seven new budget production/test files.
  Final whole-repository SwiftLint still returned 2 with 573 errors and 2,471
  warnings. This is not a clean whole-repository lint result or a claim that
  all diagnostics are pre-existing. `git diff --check` passed.
- An intermediate full coverage run failed the unchanged overlay animation
  assertion in `recordingHintStaysCenteredAndFollowsTheCapsuleDuringMorphing`.
  The final full run passed; it does not establish that this flake is resolved.
- Native `NSHostingView` rendering produced `budget-card.png`, attached to the
  issue delivery. It verifies the card rendering, not a live interactive
  permission flow. Both repositories carry the same recovery fixture and
  design/rollout contract.

## Boundaries

No real paid model, external MCP server, multi-device synchronization, full
browser/computer permission matrix or production feature enablement was tested.
The fake model/provider cases verify planning, output cap mapping and receipts;
they do not prove a third-party tokenizer, image expansion or price guarantee.
No automatic worker recovery or unknown-side-effect replay is enabled.

R01 remains an open dependency. This delivery uses the fixed dependency SHAs in
`r02-budget.md`; tests on the eventual merged main must be repeated after R01 is
merged and the stacked PRs are retargeted. Human acceptance remains required.
