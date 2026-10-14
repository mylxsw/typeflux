# Focused test validation

Complete all implementation and self-review, then run one validation pass for
changed behavior and its affected callers/dependencies. Do not test after each
edit or automatically run the entire suite before a PR. On failures, fix and
retry only failed methods or the smallest containing suite. Coverage replaces
plain validation for the same scope. Performance work may declare a focused
before/after comparison.

```bash
make test SUITE="LLMRouterTests RequestRetryTests"
make test FILTER="LLMRouterTests/testCompleteRoutesToOpenAI"
make test-plan SUITE="LLMRouterTests" # build/discover; no execution
make coverage SUITE="LLMRouterTests"
python3 scripts/test_groups.py --suite LLMRouterTests --suite RequestRetryTests
python3 scripts/test_groups.py --filter 'OverlayTransitionRenderingTests/captionsRender' --skip-build
```

Each repeated suite or filter must match actual discovery. Filters are regexes
against discovered IDs, combined by union; an optional resource group intersects
that selection. Suite names are exact and include nested suites. Empty scopes,
unknown suites, invalid or unmatched filters fail; they never fall back to all
tests. A scope covering the entire discovered inventory also requires explicit
full mode. `make test` without `FILTER` or `SUITE` fails before building.

The agent chooses the functional scope after reading changed code and its
callers. A matching filename alone is not sufficient for shared services. Record
the change-to-suite mapping in the PR, including UI/integration checks when
relevant. Resource classification does not infer affected tests automatically.

Full testing is opt-in. State the reason and scope before executing it:

```bash
make test-full REASON="explicitly requested cross-feature regression"
make coverage-full REASON="explicitly requested full coverage"
python3 scripts/test_groups.py --full --reason 'explicit regression request'
```

Unfiltered `swift test`, `swift test --enable-code-coverage`, and full iOS/UI
commands must follow the same announced opt-in policy. The reason flag makes
intent explicit; it cannot verify whether an agent actually announced the run.

## Broader scopes and discovery

| Command | Selection |
| --- | --- |
| `make test-unit` | Tests without recognized UI, storage, process, network or timer markers |
| `make test-integration` | Filesystem, SQLite, keychain, URLSession, process and timer fixtures |
| `make test-ui` | Main actor, AppKit application/window/pasteboard and localization state |
| `make test-benchmark` | Synthetic benchmarks; enables `TYPEFLUX_SEARCH_BENCH=1` |
| `make test-screen-capture` | Real desktop capture; needs screen recording permission |
| `make test-groups` | Build/audit discovery and list group sizes and suite assignments |
| `make test-scripts` | Python script tests, without building Swift |

These are explicit broad selections, not the default for an ordinary task.
A change to one UI component should select its relevant suites, not all UI tests.
For script changes, select the relevant Python unittest modules rather than
running unrelated Swift tests.

`scripts/test_groups.py` builds/discovers once using `swift test list`, then uses
`--skip-build` for execution. It reports build/discovery and execution times
separately. Only supply `--skip-build` yourself when sources and configuration
have not changed since the last build. `--jobs 4` limits build jobs, not test
workers. `--plan` previews selected methods and their execution phases.

Classification uses source markers at file granularity, with extensions and
nested suites taking the strongest resource group. Mixed files are conservative.
Markers in comments may over-classify; dependencies hidden behind helpers are
not inferred. Actual discovery is audited: empty discovery, unsupported targets
or IDs, and suites without source mappings fail. Counts are test methods;
parameterized cases may execute more than once.

## Parallel execution and UI efficiency

The runner uses sequential phases against one build directory:

1. Audited CPU-heavy XCTest suites use `--parallel --num-workers 4`.
2. Audited pure Swift Testing suites use in-process `--parallel`, with XCTest
   disabled to avoid creating a worker process for each cheap test.
3. All remaining suites use `--no-parallel` and preserve `.exclusiveUIState`.

The initial reviewed registry covers synthetic scroll stitching and calculator
recognition, lexing and numeric formatting. Calculator error messages and format
labels read localization through production helpers, so their suites stay serial.
Unknown suites default to serial. Review shared state in both fixtures and called production code when adding or
changing a suite in `PARALLEL_SUITES`. Resource group names alone are not proof of
isolation. UI markers always override the registry. Discovered method signatures
that disagree with the registered framework fall back to serial execution with
both frameworks enabled, so a framework migration cannot silently drop tests.

`--workers N` limits XCTest processes only; it does not bound Swift Testing
concurrency. `--serial` provides a same-scope baseline or diagnostic mode.
Coverage uses one serial phase to preserve one profile. Execution stops on the
first failing phase, reports failure and never automatically retries; later
phases must be reported as unexecuted when applicable.

Do not run simultaneous local SwiftPM/UI commands against the same `.build` or
desktop. `.exclusiveUIState` protects only one process; different macOS CI runners
have isolated desktops and may run resource groups concurrently.

Overlay rendering checks read common packed alpha buffers directly instead of
creating an `NSColor` for every alpha sample. Other layouts fall back to AppKit.
Equivalent pixel fixtures cover padding, orientation, alpha placement,
premultiplication, different color spaces and 16-bit/RGB fallback. RGB samples
keep the existing AppKit color conversion: a bitmap color-space tag alone does
not guarantee equivalence to `colorAt(...).usingColorSpace(.sRGB)`. Sampling
positions, animation duration and assertions remain intact. A fixed processing
frame brightness is computed once rather than on every poll.

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

## Focused execution measurements

The current focused runner validated 36 synthetic scroll stitching methods with
four XCTest workers in 14.98 seconds (execution phase including runner startup).
The same methods reported 30.58 seconds in a serial baseline, excluding startup.
Seven selected Swift Testing methods passed in a separate 1.86-second phase;
selection included one parameterized method filter to check method-level scope.

After fixing pixel fixtures and retaining AppKit RGB semantics, the three alpha
reader methods and five Overlay rendering methods passed in a 44.21-second
execution phase. Build/discovery was 34.31 seconds. The caption transition method
took 29.40 seconds; its baseline samples were 40.58 seconds with a failed transient
frame assertion and 27.93 seconds passing in the earlier full-run log. These
samples do not establish a stable end-to-end UI speedup. A standalone debug scan
of 921,600 alpha samples took 0.240 seconds through AppKit and 0.091 seconds through
the new reader, with every sample and the accumulated values matching. This
measures the alpha hotspot, not window rendering or animation settling.

No full Swift/iOS/coverage run was performed for this focused-runner update.
Cold compilation still covers the monolithic app/test target. Further compile
reduction needs a separately scoped extraction of pure feature modules with
their own test targets; the existing shared-chat package already has its own
independent scope. Measure cold build, discovery, test execution and retries
separately before choosing that structural change.
