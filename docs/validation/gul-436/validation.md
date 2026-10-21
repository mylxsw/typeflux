# GUL-436 local validation

Based on main at `75fb7d55` (binding increment A).

## Scope and evidence

The shared 20-case registry fixture covers exact/default/legacy identities,
unknown/malformed identities, duplicates, missing defaults, operation compatibility,
alternate configured defaults and historical nil binding. Additional tests cover
value semantics, rejected incomplete composition before invocation and fake alternate
selection through the application API. Existing binding tests cover readable malformed
history, nil/null persistence, validation and side-effect-free rejection.

Production composition evidence is separate from registry fixtures:

- The real AskLocalEngine completes Send -> InferenceResult using the routed API,
  sharing revisions, history and catalog access with that same engine instance.
- The conversation window's makeAPI factory and workflow editor's fallbackDependencies
  factory each use a real isolated local engine: Send -> Cancel updates that same
  engine state; history/catalog remain delegated; a nonempty token routes to a cloud
  fake. The conversation factory's default local construction is also inspected
  through the composed runtime, including configured context limits.
- Existing application-boundary tests cover every runtime overload, observation
  callbacks/cancellation, errors, both token routes and host-service access.
- A real reopened default engine rejects the alternate binding. No external model,
  network provider, live window or full UI suite is exercised. Summarization/search
  callback bodies retain their existing behavior and are outside this wiring test.

## Commands and results

`commands.json` contains exact commands, exit codes and total wall times.
Raw logs and LCOV export are included as gzip files in this directory.

1. `make coverage SUITE="AskApplicationAPITests AskAgentBindingTests AskAgentBindingInteractionTests"`:
   passed, 417.351 s including first dependency resolution/build. This selected
   24 existing methods. The registry tests were split into a new source file after
   the initial source graph was read, so they required refreshed discovery.
2. `make coverage FILTER="AskApplicationAPITests/(registrySharedFixtures|registryValuesRemainImmutableAndCompositionRejectsMissingOperations|routedDefaultSharesLocalEngineStateAndHostAccess|productionCallerFactoriesRetainLocalStateAndCloudRoute)"`:
   all four newly discovered methods passed, 78.730 s including incremental build.
3. Coverage review exposed the moved default-construction branch. Added only that
   check and ran `make coverage FILTER="AskApplicationAPITests/productionConversationFactoryBuildsConfiguredDefaultEngine"`:
   passed, 79.912 s including incremental build. Total: 29 passing selected methods.
4. Strict SwiftLint over changed Swift files still exits 2 on existing violations.
   Compared with the same files from main: no added rule counts. Initial new
   formatting findings were fixed; registry and new registry-test files are clean.
   `git diff --check` passes. Compilation reports existing SDK/compiler warnings.

No full test, UI or unrelated durable suite was run. These are real focused runs,
not cached passing results. Initial build time and the two incremental passes are
reported separately; focused coverage replaced plain test runs.

## Coverage denominator

Merge the three profdata files using llvm-profdata. Export LCOV from the final
TypefluxPackageTests binary for the five changed production Swift files. Intersect
LCOV DA lines with added diff lines (including relocated existing code). Each
instrumented line counts once; any positive combined count is covered.

Changed production line coverage: **68/74 = 91.89%**. This is not whole-app coverage.
`changed-coverage.json` lists the denominator and uncovered line numbers.

| File | Covered changed / denominator |
| --- | ---: |
| AskAgentRegistry.swift | 35/35 |
| AskAgentBinding.swift | 8/8 |
| AskApplicationAPI.swift | 12/14 |
| AskConversationWindowController.swift | 11/15 |
| AskWorkflowEditorWindowController.swift | 2/2 |

Uncovered changed lines are the unreachable fixed-default setup failure, portions
of existing default callback construction/bodies, and the live window initializer's
factory invocation. Both production composition factories are executed directly;
no live window lifecycle is claimed. Binding file coverage is 56/56 instrumented
lines and registry file coverage is 35/35.

## Self-review

Reviewed end-to-end composition, canonical identity, nil versus malformed bindings,
operation checks before invocation, actor/value ownership, existing validation
order, runtime/history/catalog sharing, cancellation/resource ownership, error
privacy and documentation consistency. Fixed new formatting issues and refreshed
source discovery so new tests actually executed. No production defect remained.
No mutable global registry, new dependency, authorization grant or extra engine
instance was introduced. Default construction preserves existing settings/closures.

Production activates only typeflux.default v1. Registration is neither persisted
state ownership nor tool authorization. Host ports, per-run dispatch, protocol
negotiation and rolling-upgrade ownership remain separate work; missing peer
capability cannot authorize alternate activation.
