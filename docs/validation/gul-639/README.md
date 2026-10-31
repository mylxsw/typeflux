# GUL-639 validation handoff

The permissions implementation is ready for code review. **Runtime validation is pending.**
Per the GUL-634 parent owner's delivery instruction on 2026-11-01 (Singapore time),
tests, coverage, and native screenshots move to GUL-642. No passing test result,
changed-code coverage percentage, or native screenshot is claimed for this revision.

## Checks performed

- `xcrun swiftc -frontend -parse` on the four changed production Swift files and
  two changed test files: passed, **0.16 seconds**. Parsing does not type-check,
  build, or execute the implementation.
- `swiftlint lint --quiet --strict` on the permissions model, page, system adapter,
  root view, and new permissions test suite: passed, **0.99 seconds**. After the
  capture host gained the real window's interface-style modifier, the changed
  test file passed again in **0.42 seconds**.
- Including the existing `OnboardingViewModelTests.swift` in strict lint reports
  its pre-existing file-length and type-length violations (baseline 593/529 lines;
  this change adds one fixture line). That expanded lint command exited 2 in
  **2.67 seconds**; the unrelated suite was not refactored.
- Five permission string tables passed `plutil -lint`. Their 35 keys match and
  contain no duplicate entries. English missing-count text supports singular and
  plural counts without separate forms.
- `git diff --check`: passed.

Earlier coverage attempts stopped before test execution: an actor-isolated default
argument and a Swift Testing key-path macro diagnostic were fixed; other attempts
were interrupted for source changes or memory contention. Their recorded total
times were 2938.29, 2696.36, 1069.78, and 2468.35 seconds. None is a passing test run.
The final locked attempt waited **6491.69 seconds**, never acquired the lock, and
was canceled on the parent owner's instruction. Its process was collected with
exit 143; no owned compiler or test process remains.

## GUL-642 focused validation

Run through the shared Swift lock and start the execution timeout only after
acquiring it, as required by the parent task. The prepared focused scope is:

```sh
SUITE="OnboardingPermissionsTests OnboardingNavigationTests OnboardingViewModelTests OnboardingBehaviorTests OnboardingComponentTests PermissionsSettingsTests ExclusiveUIStateLanguageTests" \
TYPEFLUX_GUL303_SNAPSHOTS="$PWD/permissions-captures" \
./scripts/coverage.sh --from-env --jobs 2
```

The new suite covers route/provider requirements, initial readiness, optional
queries, legacy readiness snapshots, deferral, prompt/pane routing, denied requests,
duplicate clicks, polling, cancellation, late grants after returning, and all five
localizations. Existing suites cover navigation, shell behavior, shared components,
permission services, and exclusive localization state.

The native rendering fixture mirrors `OnboardingWindowController`, including the
interface-style environment, fixed 960 × 664 root, full-size title bar, safe area,
and native appearance. It uses injected permission states and writes **44 PNGs**:
initial, denied, accessibility guide, complete, optional expanded, optional bottom,
optional guide, completed guide, automation guide, Apple Speech, and launcher-only;
each in English/Chinese and light/dark. Compare these with
`docs/design/onboarding-v3/prototype.html`, including long English guide titles and
the bottom optional rows. Actual system authorization and relaunch behavior still
need integration verification; the adapter tests inject those effects.

## Self-review

Reviewed the complete status/request/navigation path, empty and denied states,
error handling, async lifetime, duplicate requests, fixed settings URLs, resource
ownership, and all localization tables. Fixed readiness before first load, optional
queries gating Continue, request/poll scheduling races, and late callbacks reviving
guidance. The model owns no navigation and keeps a weak session reference. The
root change only supplies the permission footer hint. Runtime correctness and native
layout remain subject to the deferred checks above.
