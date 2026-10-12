# Model settings review (GUL-336)

Production SwiftUI views captured on macOS using isolated settings and no provider requests. “Before” is PR #429 applied to `884dac60`, with only the renamed Tab component and removed Hotkeys section references adapted so it builds. “After” includes the shared settings controls and the follow-up provider detail alignment requested during review.

## Shared controls

| Element | Implementation |
| --- | --- |
| Tabs | `StudioUnderlineTab`, also used by Voice Input and Settings |
| Speech scene and provider protocol | `SettingsMenuPicker`, including its full native hit area |
| Language model scene | `SettingsMenuField`; existing grouped availability popover retained |
| Search | `SettingsSearchBox` and `SettingsControlChrome` |
| Actions | Existing `ModelActionStyle`, also used by Settings; `SettingsActionButton` adds loading state |
| Inputs | `ModelFormRow` shares the label/field grid between language and speech connections; fields retain `ModelFieldStyle` / `SettingsControlChrome` |
| Provider header | `ModelDetailHeader` with icon, name, configuration status, and contextual back action |
| List captions | `SettingsListSectionLabel` with localized counts |
| Cards and row titles | Existing shared `ModelSurface`, Studio palette, and `Typography.settingTitle` |

Menus remain 36 pt high, while actions, text fields and search remain 30 pt, matching Settings. Endpoint and model identifiers retain monospaced text. Inline reveal, capability and navigation actions retain their compact forms; they serve different purposes from save/test actions. Language model choices keep their grouped popover because it displays model capability and availability information. No separate model-page palette is introduced.

## Screenshots

### Model configuration

| Appearance | Before | After |
| --- | --- | --- |
| light | ![Before scenes light](before/scenes-light.png) | ![After scenes light](after/scenes-light.png) |
| dark | ![Before scenes dark](before/scenes-dark.png) | ![After scenes dark](after/scenes-dark.png) |

### Speech providers

| Appearance | Before | After |
| --- | --- | --- |
| light | ![Before speech light](before/speech-light.png) | ![After speech light](after/speech-light.png) |
| dark | ![Before speech dark](before/speech-dark.png) | ![After speech dark](after/speech-dark.png) |

### Language providers

| Appearance | Before | After |
| --- | --- | --- |
| light | ![Before language light](before/language-light.png) | ![After language light](after/language-light.png) |
| dark | ![Before language dark](before/language-dark.png) | ![After language dark](after/language-dark.png) |

### Editable provider

| Appearance | Before | After |
| --- | --- | --- |
| light | ![Before provider light](before/provider-light.png) | ![After provider light](after/provider-light.png) |
| dark | ![Before provider dark](before/provider-dark.png) | ![After provider dark](after/provider-dark.png) |

### Cloud provider

| Appearance | Before | After |
| --- | --- | --- |
| light | ![Before cloud light](before/cloud-light.png) | ![After cloud light](after/cloud-light.png) |
| dark | ![Before cloud dark](before/cloud-dark.png) | ![After cloud dark](after/cloud-dark.png) |

### Speech provider configuration

| Appearance | Before | After |
| --- | --- | --- |
| light | ![Before speech-provider light](before/speech-provider-light.png) | ![After speech-provider light](after/speech-provider-light.png) |
| dark | ![Before speech-provider dark](before/speech-provider-dark.png) | ![After speech-provider dark](after/speech-provider-dark.png) |

### Google speech connection

| Light | Dark |
| --- | --- |
| ![Google light](after/speech-google-light.png) | ![Google dark](after/speech-google-dark.png) |

### Local speech models

| Light | Dark |
| --- | --- |
| ![Local models light](after/speech-local-light.png) | ![Local models dark](after/speech-local-dark.png) |

### Settings appearance reference

| Appearance | Before | After |
| --- | --- | --- |
| light | ![Before settings light](before/settings-light.png) | ![After settings light](after/settings-light.png) |
| dark | ![Before settings dark](before/settings-dark.png) | ![After settings dark](after/settings-dark.png) |

### Settings actions reference

| Appearance | Before | After |
| --- | --- | --- |
| light | ![Before hotkeys light](before/hotkeys-light.png) | ![After hotkeys light](after/hotkeys-light.png) |
| dark | ![Before hotkeys dark](before/hotkeys-dark.png) | ![After hotkeys dark](after/hotkeys-dark.png) |

## Reproduce

```sh
TYPEFLUX_MODEL_SNAPSHOTS=/tmp/typeflux-model-review swift test --filter ModelSettingsSnapshotTests
swift test --filter 'ModelSettingsControlsTests|ModelPageTabTests'
TYPEFLUX_SETTINGS_MENU_TESTS=1 swift test --filter SettingsMenuPickerTests
```

The screenshot suite requires an active macOS graphical session with screen recording access. Other control tests render their own isolated windows and do not require provider credentials.

## Original three-tab validation (#430)

`swift build --enable-code-coverage` passed. All 122 relevant tests passed (72 XCTest, 49 Swift Testing, plus the dedicated native menu test). The original three-tab implementation had 92.26% changed-line coverage. The follow-up provider detail results are recorded below.

Validation ran on macOS 26.6.2 with Xcode 27 / Swift 6.4. The targeted regression command covers model tabs, scene persistence, provider navigation, real Add provider clicks, shared control metrics, loading/disabled actions, localized layouts, settings behavior, model protocols, localization, and Ask model/effort picker compatibility. The native menu tracking test runs in its own process.

Changed production-line coverage is recorded in [coverage.json](coverage.json). It counts LLVM LCOV executable lines intersecting additions in `git diff --unified=0 884dac60 -- Sources`, including uncovered executable lines. Profiles from the full XCTest run and the final focused suite are merged; this is change coverage, not whole-repository coverage.

The full XCTest phase executed 3,774 tests (17 skipped, zero failures). The full Swift Testing phase did not finish: it reported the existing Ask launcher/opacity failures and eventually stalled in AppKit layout; a process sample included the unchanged `AskFluidDropShape`. The run was cancelled. `AskComposerChromeTests` and `AskRedesignTests` also contain unchanged geometry expectations inconsistent with main's 48 pt launcher footer. These issues are outside the model settings changes.

## Provider detail follow-up validation

This follow-up is based on `main` at `b81497b8`, after #430 merged. OpenAI, Google, and local speech details were recaptured in both appearances. The local model fixture supplies availability and prepared metadata without reading personal model paths. Language provider screenshots were also recaptured for comparison.

`swift build --enable-code-coverage` passed. All 80 relevant tests passed: 53 XCTest, 26 Swift Testing, and the dedicated native menu test. Final changed-production-line coverage is **90.50% (219/242)**; see [provider-detail-coverage.json](provider-detail-coverage.json). This report uses the final focused suite's LLVM profile without merging earlier test binaries, and intersects executable lines with `git diff --unified=0 b81497b8 -- Sources`. Remaining uncovered lines include real OAuth, storage actions, and the currently empty free-provider registry's populated branch. The full repository suite was not rerun for this follow-up; the earlier full-suite limitations are recorded above.

The added behavior tests cover every visible speech provider at 920 pt, shared header/status/back navigation, horizontal label/field bounds, saving connection drafts, loading/feedback, Google authorization disconnection, and local download confirmation/cancellation with transfer detail. Google tokens remain in the test process's in-memory store; no provider network calls or downloads are needed.

```sh
TYPEFLUX_MODEL_SNAPSHOTS=/tmp/typeflux-model-review swift test --no-parallel --enable-code-coverage --filter 'ModelSettingsControlsTests|ModelSettingsSnapshotTests|ModelPageTabTests|ModelProtocolRenderTests|SettingsPolishTests|SettingsBehaviorTests|LocalizationResourceTests'
TYPEFLUX_SETTINGS_MENU_TESTS=1 swift test --enable-code-coverage --filter SettingsMenuPickerTests
swift build --enable-code-coverage
```
