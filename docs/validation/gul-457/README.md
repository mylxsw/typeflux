C5 stores immutable host-local run routing evidence in the existing atomic
conversation snapshot. Lookup is read-only internal composition; default-only
execution policy and the public AskAPI remain unchanged. GUL-458 retains later
dispatch composition. Archives grow with witnessed runs until conversation
removal, without a cap, speculative TTL or silent eviction.

Acceptance correction: private snapshot load/save now uses a scoped raw JSON
codec for agent_routes and run.agent_binding. Numeric tokens are captured from
original snapshot bytes before Foundation decoding. The rest of the record
still uses AskCoding's existing typed Codable and date handling. Encoding
removes private evidence from the typed copy and reinserts exact raw values in
the same protected atomic write; no sidecar or new suspension exists.

Number equality normalizes decimal coefficient/exponent exactly, including
exponents outside machine-integer range. Equivalent 1/1.0 compare equal; near-one
values and arbitrary large coefficients remain distinct. Invalid binding
fields stay opaque/nonexecuting. Archive capture uses preserved binding evidence
directly, without re-encoding it through Foundation. The ordinary wire Codable
adapter retains its existing integer admission; private snapshot callers always
use decodeSnapshot/encodeSnapshot to recover original numeric evidence.

Focused scope: AskRunRouteTests covers original-byte snapshot load -> metadata
save -> reload, large/near-one current bindings, extensions, archive roots,
opaque values, immutable exact-number conflicts and legacy archive creation.
It also covers archive decisions, stale-copy union, failed writes/keeps,
read-only lookup, temporary persistence, deletion/purge and run replacement.
AskAgentBindingTests, AskLocalEngineTests and AskLocalEngineReentrancyTests cover
existing binding guards, storage callers, recovery and concurrency boundaries.

Final validation (macOS arm64, focused XCTest only):

```sh
swift build
# PASS; first dependency preparation + build approximately 836.48s wall
# (process start and log timestamps; compiler build phase 118.76s).
make coverage SUITE='AskRunRouteTests AskAgentBindingTests AskLocalEngineTests AskLocalEngineReentrancyTests'
# 357.51s total wall including preparation/discovery/execution.
# 37 tests: 35 passed, two fixture assertions failed. One expected an absent
# numeric token, one accidentally depended on JSON key order. Both corrected.
make coverage FILTER='AskRunRouteTests/(testOriginalSnapshotNumericEvidenceSurvivesMetadataSaveAndReload|testExactOpaqueArchivesAndArchiveCreationFromPreservedBinding)'
# PASS; 2 tests, 80.36s total wall including rebuild/discovery/report.
python3 -m unittest discover -s docs/validation/gul-457 -p 'test_*.py' -v
# PASS; 4 tests, 0.06s total wall.
swiftlint lint --strict --quiet Sources/Typeflux/Ask/AskRouteJSONCodec.swift Sources/Typeflux/Ask/AskAgentBinding.swift Sources/Typeflux/Ask/AskRunRoute.swift
# PASS; no violations.
python3 docs/validation/gul-457/changed_coverage.py docs/validation/gul-457/initial-scope.lcov.gz docs/validation/gul-457/retry-scope.lcov.gz --base 43ab96cb9d57f7d0d9cf68882df526dc7de839a4
# PASS; 413/419 changed executable production lines, 98.57%.
```

All 37 selected distinct tests passed across the initial scope and corrected
method retries (39 executions, 437.87s combined focused-command wall time).
No production source changed between those runs. The first build/discovery
reported existing warnings in unrelated test files; no UI/full suite executed.
The old engine file retains existing lint violations outside this correction.

Raw commands/results are in swift-final-validation.txt.gz and
swift-retry-validation.txt.gz; initial preparation is in swift-build.log.gz.
The first command stopped before the normal report because of fixture failures,
so actual profraw files were merged with llvm-profdata, then exported before
retry. Both unedited LCOV exports are included; profiles are combined using the
maximum execution count per source line. Failed fixture assertions were not
reported as passing tests. Coverage is for changed instrumented production
lines relative to the pinned base, not project-wide coverage.

Exact export commands (the same four production source arguments on each):

```sh
xcrun llvm-profdata merge -sparse .build/arm64-apple-macosx/debug/codecov/*.profraw -o docs/validation/gul-457/initial.profdata
xcrun llvm-cov export .build/arm64-apple-macosx/debug/TypefluxPackageTests.xctest/Contents/MacOS/TypefluxPackageTests -instr-profile=docs/validation/gul-457/initial.profdata -format=lcov Sources/Typeflux/Ask/AskAgentBinding.swift Sources/Typeflux/Ask/AskRunRoute.swift Sources/Typeflux/Ask/AskRouteJSONCodec.swift Sources/Typeflux/Ask/Local/AskLocalEngine.swift > docs/validation/gul-457/initial-scope.lcov
xcrun llvm-cov export .build/arm64-apple-macosx/debug/TypefluxPackageTests.xctest/Contents/MacOS/TypefluxPackageTests -instr-profile=.build/arm64-apple-macosx/debug/codecov/default.profdata -format=lcov Sources/Typeflux/Ask/AskAgentBinding.swift Sources/Typeflux/Ask/AskRunRoute.swift Sources/Typeflux/Ask/AskRouteJSONCodec.swift Sources/Typeflux/Ask/Local/AskLocalEngine.swift > docs/validation/gul-457/retry-scope.lcov
```

The shared portable coverage script uses validated GUL-455 suffix normalization
and rejects ambiguous/unrelated/traversal source paths. Python regressions cover
foreign and relative SF paths, maximum hits across records/profiles, gzip
artifacts and Go module path rejection. To reproduce in another checkout at this
PR head, use the pinned-base command above with the committed raw LCOV files;
no original build-directory layout or test binary is required.

Self-review checked original-byte numeric recovery, exact equality/range
boundaries, malformed scalar/object readability, immutable same-run conflicts,
stale-copy union, old/new run capture, snapshot/cache publication ordering,
failed-write/keep rollback, prepared-image cleanup, no new suspension, account
boundaries, public projection and unchanged binding guards. It retained the
ordinary typed wire integer guard and fixed the two test-only assertions above.
Go companion: https://github.com/mylxsw/typeflux-api/pull/156.
