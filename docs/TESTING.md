# Test groups

Use a focused suite while implementing a change. Use a resource group when the
change affects several features. Run `make test` or `make coverage` once for final
validation; a passing group does not replace the full suite.

| Command | Selection |
| --- | --- |
| `make test-unit` | Tests without recognized UI, storage, process, network, or timer dependencies |
| `make test-integration` | Filesystem, SQLite, keychain, URLSession, subprocess, and timer fixtures |
| `make test-ui` | Main actor, AppKit application/window/pasteboard, and shared localization state |
| `make test-benchmark` | Synthetic benchmark suites; enables `TYPEFLUX_SEARCH_BENCH=1` |
| `make test-screen-capture` | Real desktop capture; requires screen recording permission |
| `make test-groups` | Build, audit actual test discovery, and list group sizes and suite assignments |
| `make test-scripts` | Python development-script tests, without building Swift |
| `make test` | Existing unfiltered Swift suite; benchmarks retain their opt-in behavior |
| `make coverage` | Existing unfiltered coverage run and HTML report |

`scripts/test_groups.py` calls `swift test list` to build and discover both XCTest
and Swift Testing tests. It maps every discovered suite to a group, then runs the
selected suites with `--skip-build`. Each invocation reports discovery/build and
test execution times separately. After a build, reuse it explicitly:

```bash
python3 scripts/test_groups.py unit --skip-build
python3 scripts/test_groups.py integration --skip-build
python3 scripts/test_groups.py ui --skip-build
```

Omit `--skip-build` after changing Swift sources. `--jobs 4` limits build jobs on
machines with limited memory; it does not create parallel test processes.

## Classification and isolation

Classification is conservative and based on the test source files in
`Tests/TypefluxTests`, rather than an allowlist that must be updated for each new
test. Files ending in `BenchmarkTests.swift` go to `benchmark`. Other files with
`@MainActor`, `.exclusiveUIState`, shared localization, or AppKit state references
go to `ui`. Storage, process, URLSession, and sleep references go to `integration`.
The remaining files go to `unit`. See the marker expressions in
`scripts/test_groups.py` for the exact rules.

Every suite in a mixed file takes that file's group. Extension files can upgrade
the original suite's group; nested suites follow their outer suite. This can put
pure tests in a heavier group, including when markers occur in comments or test
fixtures. Dependencies hidden behind helpers are not inferred. Group names are
a feedback selection strategy, not a proof that tests have no side effects.

The discovery audit rejects empty discovery, unsupported targets or identifiers,
and suites that cannot be mapped to a source. Selection uses anchored suite names, so
`ExampleTests` cannot accidentally select `ExampleTestsExtra`. The four groups
form a disjoint partition of the discovered tests. Discovery counts describe
test methods, including disabled methods; parameterized test cases may execute
more than once.

Group runs use `--no-parallel` and preserve `.exclusiveUIState`. Do not run local
groups concurrently: AppKit focus and the system pasteboard are shared across
processes, and the trait's lock only protects one process.

## CI and performance work

The existing `@autotest` trigger runs `unit`, `integration`, and `ui` as separate
matrix jobs on separate macOS runners. `fail-fast: false` collects all group
results. The iOS/shared-chat job runs alongside them. Synthetic benchmarks stay
opt-in. Real screen capture is also opt-in. Each macOS job audits the complete
discovered test inventory before selecting its group.

Real desktop capture uses `TYPEFLUX_REAL_SCREEN_CAPTURE_TESTS=1`, through
`make test-screen-capture`. The test remains in the UI inventory, with its pixel
assertions intact, but is disabled in ordinary runs. It requires screen recording
access when explicitly selected. `CGPreflightScreenCaptureAccess()` can report
access while ScreenCaptureKit rejects capture, so it does not decide whether
ordinary unit tests should attempt real desktop capture.
Run this entry on a machine with working screen recording access when changing
capture behavior. Synthetic window-policy tests run in the normal UI group.

Grouping shortens local feedback by selecting fewer tests and lets CI execute
independent resource groups on separate machines. It does not reduce a cold
Swift build: all tests still depend on the large application target. CI matrix
jobs also compile independently, increasing total runner work. Compare measured
execution times separately from cold compilation before splitting package
targets or adding more workers.

For further runtime optimization, start with the slow tests reported by the test
runner. Replace unconditional waits with completion signals or bounded condition
polling where behavior permits. Keep timeout/cancellation tests that exercise
real deadlines, and run UI rendering and benchmarks in stable environments.

`ConnectionTestSupport.runWithTimeout` accepts a sleep function, following the
existing `RequestRetry` test seam. Its timeout test triggers the timer immediately
and asserts the requested 30-second duration and cancellation of the operation.
This removes a measured 30-second wait from each full run while retaining the
production deadline. The default sleep still uses `Task.sleep`.

## Local measurements

On 2026-10-14, Swift 6.4 on an arm64 Mac with 16 GiB RAM discovered:

| Group | Suites | Test methods |
| --- | ---: | ---: |
| unit | 164 | 1,866 |
| integration | 76 | 667 |
| ui | 499 | 4,021 |
| benchmark | 1 | 1 |

The warm unit group's execution stage took 50.58 seconds, including test-process
startup. One serial full run took 1,016.75 seconds: XCTest reported 3,790 methods,
17 skips, and zero failures; Swift Testing reported 2,765 methods with one real
screen capture failure.
Its focused retry received ScreenCaptureKit's permission rejection. After adding
the explicit native-capture entry, the normal window-policy suite passed with
that case disabled; native capture still needs working system permission on
this machine. The connection timeout case dropped from 30.006 seconds to less
than 0.01 seconds. These are local samples, not CI timing guarantees.
