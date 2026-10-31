# GUL-636 foundation evidence

46 native SwiftUI/AppKit PNG captures taken on this Mac. Open `index.html` from the
archive for the gallery. `native-window-*` includes the real NSWindow title bar;
other captures render the native hosting view at 960 × 664 pt. No HTML prototype
is presented as native evidence.

These are stage-one page slots, not completed page implementations. Cloud,
speech, LLM, permissions, shortcuts and try intentionally contain their editorial
header and shared footer only. Route demonstrates selection without the stage-two
artwork. Welcome retains the existing content. `components-*` is a test fixture
showing selected/unselected provider cards, config slots, pinned actions, guide
and footer; it is not a functional model configuration page.

| Page / state | English light | English dark | Chinese light | Chinese dark |
| --- | --- | --- | --- | --- |
| welcome | [en light](welcome-en-light.png) | [en dark](welcome-en-dark.png) | [zh-Hans light](welcome-zh-Hans-light.png) | [zh-Hans dark](welcome-zh-Hans-dark.png) |
| route | [en light](route-en-light.png) | [en dark](route-en-dark.png) | [zh-Hans light](route-zh-Hans-light.png) | [zh-Hans dark](route-zh-Hans-dark.png) |
| route-cloud | [en light](route-cloud-en-light.png) | [en dark](route-cloud-en-dark.png) | [zh-Hans light](route-cloud-zh-Hans-light.png) | [zh-Hans dark](route-cloud-zh-Hans-dark.png) |
| cloud | [en light](cloud-en-light.png) | [en dark](cloud-en-dark.png) | [zh-Hans light](cloud-zh-Hans-light.png) | [zh-Hans dark](cloud-zh-Hans-dark.png) |
| speech | [en light](speech-en-light.png) | [en dark](speech-en-dark.png) | [zh-Hans light](speech-zh-Hans-light.png) | [zh-Hans dark](speech-zh-Hans-dark.png) |
| llm | [en light](llm-en-light.png) | [en dark](llm-en-dark.png) | [zh-Hans light](llm-zh-Hans-light.png) | [zh-Hans dark](llm-zh-Hans-dark.png) |
| permissions | [en light](permissions-en-light.png) | [en dark](permissions-en-dark.png) | [zh-Hans light](permissions-zh-Hans-light.png) | [zh-Hans dark](permissions-zh-Hans-dark.png) |
| shortcuts | [en light](shortcuts-en-light.png) | [en dark](shortcuts-en-dark.png) | [zh-Hans light](shortcuts-zh-Hans-light.png) | [zh-Hans dark](shortcuts-zh-Hans-dark.png) |
| try | [en light](try-en-light.png) | [en dark](try-en-dark.png) | [zh-Hans light](try-zh-Hans-light.png) | [zh-Hans dark](try-zh-Hans-dark.png) |
| components | [en light](components-en-light.png) | [en dark](components-en-dark.png) | [zh-Hans light](components-zh-Hans-light.png) | [zh-Hans dark](components-zh-Hans-dark.png) |
| native-window | [en light](native-window-en-light.png) | [en dark](native-window-en-dark.png) | [zh-Hans light](native-window-zh-Hans-light.png) | [zh-Hans dark](native-window-zh-Hans-dark.png) |

Empty content slots / disabled buttons: [light](components-empty-disabled-light.png),
[dark](components-empty-disabled-dark.png).

## Validation

The final effective scope is 53 passing methods across OnboardingNavigationTests,
OnboardingViewModelTests, OnboardingBehaviorTests, OnboardingComponentTests and
OnboardingFeatureTests. Navigation tests cover branch membership, fixed stage
numbers, recovery and late-result guards; model tests retain provider/deferral and
completion behavior; native UI/component tests cover actions, language, appearance
and title-bar geometry. Feature metadata remains covered for the retained guides.

Changed executable line coverage: **759 / 788 (96.32%)**, including relocated code.
See [coverage.json](coverage.json) for per-file counts, uncovered lines and timings.
Coverage exports are made against each phase's own binary and unioned by source
line; production source is unchanged across these phases. Test-only edits fix AX
selectors and add retained-guide/native-window evidence. No cross-binary profile
merge is used for this report. The final component-only project-wide coverage is
not the changed-code coverage reported here.

| Command | Total wall time | Result |
| --- | --- | --- |
| `swift build` | approximately 227 s including dependency resolution (117.36 s build phase) | Passed; total estimated from log timestamps |
| `make coverage SUITE="OnboardingNavigationTests OnboardingViewModelTests OnboardingBehaviorTests OnboardingComponentTests OnboardingFeatureTests"` | 316.60 s | Build interrupted by test-source timestamp change; no tests executed |
| Same focused coverage command | 216.63 s | 50/51 methods passed; one AX enabled-property assertion corrected |
| `make coverage SUITE="OnboardingComponentTests"` | 82.24 s | 3/4 passed; newly added retained-guide test needed AX link role |
| Same component coverage command | 65.32 s | 4/4 passed |
| `make coverage FILTER="OnboardingComponentTests.*optional"` | 81.53 s | 1/1 passed; disabled-state fixture recaptured with backdrop |

Capture runs set `TYPEFLUX_GUL303_SNAPSHOTS="$PWD/docs/evidence/onboarding-v3/foundation"`.
No full test suite was executed. `git diff --check` passes.
