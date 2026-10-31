# GUL-641 validation handoff

The parent owner moved tests, coverage and native screenshots to GUL-642 before
this change was delivered. No passing test result or coverage percentage is
claimed here. No native screenshots were captured.

## Implemented scope

The Try page follows `docs/design/onboarding-v3/prototype.html`: four feature
rows, live shortcuts, practice cards, tried indicators, and Connect navigation.
The voice demo has separate state from real dictation detection. Completion
continues through the existing session and analytics path. All new copy has
English, Simplified Chinese, Traditional Chinese, Japanese and Korean strings.
Old guide files and strings remain intact.

## Checks and interrupted validation

Self-review covered the prototype in both themes, session integration, real
dictation versus demo state, cleared shortcut bindings, and localized copy.
`git diff --check` and the five strings-file syntax/key checks passed.

| Command | Wall time | Result |
| --- | ---: | --- |
| Focused runner, two suites, coverage, 1 job | 568.18 s | Stopped when global lock coordination was introduced |
| Focused runner, two suites, coverage, 2 jobs, global lock | 2898.91 s | App compiled; stopped while preparing the complete test target, then switched to a compact source closure |
| Compact `swift test`, coverage, 2 jobs, global lock | 287.35 s | Build completed in 259.02 s; stopped on the parent's validation-deferral instruction before test results |

The runner command was `python3 scripts/test_groups.py --coverage --jobs 2
--suite OnboardingTryTests --suite OnboardingViewModelTests` (first attempt used
`--jobs 1`). The compact command was `swift test --build-system native --jobs 2
--enable-code-coverage --disable-automatic-resolution --filter
'OnboardingTryTests|OnboardingViewModelTests'`.

The compact build used the existing `TYPEFLUX_TEST_FILES` mechanism with
`OnboardingTryTests.swift`, `OnboardingViewModelTests.swift`,
`SettingsBehaviorTestSupport.swift`, `ExclusiveUIStateTrait.swift`, and
`ProductAnalyticsTests.swift`. Both application and selected test sources
compiled and linked. Test execution did not produce a result before cancellation.
Reported times exclude waiting for the global lock; the 3600-second subprocess
timeout started only after acquiring it.

## GUL-642 follow-up

- Execute `OnboardingTryTests` for availability, live bindings, demo isolation,
  applied-history detection, feature actions, Connect and Finish.
- Execute `OnboardingViewModelTests` for affected navigation, completion and
  analytics behavior; collect changed-code coverage in that same run.
- The snapshot test prepares nine states in English and Simplified Chinese,
  in dark and light (36 captures). Set `TYPEFLUX_GUL303_SNAPSHOTS` to an output
  directory to save native PNGs, then compare them with the prototype.
- Inspect empty/held/released voice demo, successful dictation, Launcher, Ring,
  Agent, and disconnected voice/Agent. Snapshot success is a fixture state,
  not evidence of an end-to-end microphone recording.

## Authorized orphan cleanup

Only the canceled `gul-641-41ab523356c9` checkout was targeted. Daemon PID 790
was excluded. Process group 72857 received SIGTERM; after 10 seconds all three
processes had exited, so SIGKILL was unnecessary:

- 72857: `make test SUITE=OnboardingNavigationTests`
- 72859: `python ./scripts/test_groups.py --from-env`
- 72862: `swift-build --build-tests`

Other tasks' processes were left untouched. This run's own validation and lock
were also stopped and collected before delivery.
