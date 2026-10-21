C5 adds private local record routing evidence and AskRunRouteAccess for internal
host composition. Archive and snapshot share the existing protected atomic
write. Cached evidence is unioned with stale value copies before old/new current
runs are captured; collisions fail before disk or cache publication. Temporary
records have the same in-memory archive, persisted when kept. Failed keeps
restore temporary membership. No new suspension or public AskAPI method exists.

Malformed archives preserve JSON value semantics (including scalar/null roots)
so ordinary history remains readable. Metadata saves retain opaque evidence;
new routing identities fail closed. Lookup reads the cached raw record without
record() housekeeping. Existing loadAll startup recovery is unchanged. Binding
extensions remain present during unrelated saves, with the existing execution
guard intact. No dispatcher, alternate selection or late-receipt behavior changes.

Archives grow with observed runs, not message count. There is no cap, pruning or
per-run TTL while receipts can refer to history; conversation deletion removes
its archive. GUL-458 owns later dispatch composition.

Focused scope maps AskRunRouteTests to raw JSON/decision tables, immutable union,
stale copies, failed writes, lookup purity, temporary keep/reopen/delete, memory
purge, and send/retry/regenerate replacement. Existing AskAgentBindingTests,
AskLocalEngineTests and AskLocalEngineReentrancyTests cover directly affected
storage callers and binding guards. No UI or external providers are exercised.

Validation on macOS arm64 with Swift 6.4:

```sh
swift build
# PASS. Initial dependency preparation plus build: approximately 488.70s
# (log creation to final write); compiler reported 107.29s for its build phase.
make coverage SUITE='AskRunRouteTests AskAgentBindingTests AskLocalEngineTests AskLocalEngineReentrancyTests'
# PASS: 32 tests, zero failures. Full command wall: 343.73s.
# Runner: 340.23s total, 331.34s discovery/build, 8.88s test process;
# XCTest bodies: 3.063s. First coverage build, not a verified cache hit.
make coverage SUITE='AskRunRouteTests'
# Failed build: 62.81s command wall. A newly added fixture helper named run()
# collided with XCTestCase.run(); renamed it to routeRun(). No tests executed.
make coverage SUITE='AskRunRouteTests'
# PASS on final source: 8 tests, zero failures. Full command wall: 89.81s.
# Runner: 83.89s total, 76.95s discovery/build, 6.93s test process;
# XCTest bodies: 0.045s. Incremental rebuild, not a verified cache hit.
xcrun llvm-cov export .build/arm64-apple-macosx/debug/TypefluxPackageTests.xctest/Contents/MacOS/TypefluxPackageTests -instr-profile=.build/arm64-apple-macosx/debug/codecov/default.profdata -format=lcov > route-coverage.lcov
python3 docs/validation/gul-457/changed_coverage.py route-coverage.lcov --base 43ab96cb9d57f7d0d9cf68882df526dc7de839a4
# AskAgentBinding.swift: 13/13; AskRunRoute.swift: 115/115;
# AskLocalEngine.swift: 34/34. Total changed instrumented lines: 162/162, 100%.
swiftlint lint --strict --quiet Sources/Typeflux/Ask/AskRunRoute.swift Sources/Typeflux/Ask/AskAgentBinding.swift
# PASS.
```

The final targeted pass followed two review fixes: opaque cached archives must
win stale metadata copies without accepting a new current identity, and finite
JSON numbers outside Decimal's exponent range must remain readable. There are
33 distinct selected tests across the two passing scopes (40 executions).
The final pass alone supplies the changed-line coverage above; this is not
project-wide coverage. The full new archive file also has 100% line coverage
(128/128), with 98.11% region coverage. No full/UI suite or provider calls ran.

Linting the entire legacy AskLocalEngine file still reports existing size,
identifier and line-length violations, including with the repository baseline;
those were left outside this change. New routing and binding files pass strict
lint. Both repositories include the same portable coverage intersection script;
the pinned base keeps the metric reproducible after main advances.

Self-review checked entry immutability, stale union and opaque precedence,
lookup purity, snapshot/cache publication ordering, failed keep rollback,
prepared-image cleanup, no new suspension, account boundaries, private/public
projection, and unchanged default binding guards. Review caught extension-field
loss, guard equality drift, and the metadata/keep/numeric edge cases above;
all are fixed and exercised by the focused tests.
