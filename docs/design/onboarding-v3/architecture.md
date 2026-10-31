# Onboarding v3 architecture

Status: approved by the parent owner (GUL-636). Based on main `ddd36e6a` and the
adjacent prototype. The foundation supplies the shell and page slots; real page
content and service wiring remain stage-two work.

## Flow and state

Keep SwiftUI, AppKit window hosting, existing dependency injection and stores.
Keep `OnboardingViewModel` as the session owner; do not introduce another settings
store or persist a step index. Extract its step type into `OnboardingStep.swift`
and retain a `Step` typealias for callers. Cases are `welcome`, `route`, `cloud`,
`speech`, `llm`, `permissions`, `shortcuts`, and escaped Swift case `try`.

`visibleSteps` is route-dependent, never entitlement-dependent:

| Route | Ordered steps |
| --- | --- |
| cloud | welcome → route → cloud → permissions → shortcuts → try |
| custom | welcome → route → speech → llm → permissions → shortcuts → try |
| launcherOnly | welcome → route → permissions → shortcuts → try |

Welcome has no step pill. Route/cloud/speech/llm use `01 / 04`, permissions
`02 / 04`, shortcuts `03 / 04`, try `04 / 04`. These are stage numbers, not
positions in `visibleSteps`. Cloud without ASR entitlement downloads a local
model inline; it does not insert speech. Cloud continuation requires login,
refreshed entitlement and available speech (cloud or downloaded local fallback).

Navigation stays in `OnboardingViewModel+Navigation.swift`: `advance`, `goBack`,
`chooseRoute`, `confirmSkip`, and `returnToRoute`. Route switches explicitly
choose a valid destination. Back follows the selected route. All navigation
invalidates pending automatic advancement; late login/test/download results may
refresh availability but cannot move a page after Back, Skip or route changes.
Page models publish readiness and busy state; the shell consumes them through
existing session APIs (`canAdvance`, `isSetupActionRunning`, setup actions).

## Migration, skips and recovery

- Rename services → route and stt → speech; replace voice/launcher/tools/ring/chat
  guide destinations and finish with try. Keep existing feature metadata for
  practice. Move the voice-practice history check from `.voice` to `.try`.
- Preserve existing skip confirmation and existing-configuration messaging.
  Skip-all sets both deferred flags and goes to permissions; speech skip goes
  to llm, llm skip to permissions. Skipping never clears credentials, provider
  selection or downloaded models. A successful explicit setup clears only its
  corresponding deferred flag.
- Permissions Later sets `onboardingPermissionsDeferred`; successful continuation
  clears it. Permission readiness no longer includes the globe-key check:
  that moves to shortcuts. Launcher-only requires accessibility; voice routes
  require microphone and accessibility, plus Speech Recognition for Apple Speech.
  Optional permissions never gate continuation. Counts derive from the actual
  permission sets, not hard-coded denominators.
- Preserve menu-bar resume: choose custom route, restore deferred state, enter
  speech if speech is deferred, otherwise llm if AI is deferred, otherwise
  permissions. Do not reset configured models or shortcuts. Try's Connect action
  returns to route within the current session.
- Preserve completion/abandonment analytics, default-persona application,
  clipboard defaults and the single completion callback. Use new step names for
  step analytics; test that terminal events still emit once. Closing retains
  today's completion/deferred-state semantics.

## Ownership and interfaces

All files below are under `Sources/Typeflux/Onboarding/`. The actual parent has
five stage-2 tasks (the issue's reference to four is stale).

| Owner | Page views | Page models |
| --- | --- | --- |
| GUL-636 foundation | OnboardingWelcomePage.swift; OnboardingView.swift; OnboardingWindowController.swift | OnboardingViewModel.swift; OnboardingViewModel+Navigation.swift; OnboardingStep.swift |
| GUL-637 route/cloud | OnboardingRoutePage.swift; OnboardingCloudPage.swift | OnboardingRouteModel.swift; OnboardingCloudModel.swift |
| GUL-638 speech/LLM | OnboardingSpeechPage.swift; OnboardingLLMPage.swift | OnboardingSpeechModel.swift; OnboardingLLMModel.swift |
| GUL-639 permissions | OnboardingPermissionsPage.swift | OnboardingPermissionsModel.swift |
| GUL-640 shortcuts | OnboardingShortcutsPage.swift | OnboardingShortcutsModel.swift |
| GUL-641 try | OnboardingTryPage.swift | OnboardingTryModel.swift |

Foundation creates and wires all page/model slots, including inert placeholders,
before stage 2 starts. Models are session-owned `@MainActor ObservableObject`s,
constructed once with a weak `session` reference and observed by their page.
Use that session to access the already-injected settings, auth, model library,
configuration model and local model manager. Do not create another SettingsStore. Pages call
session navigation actions; page models own feature actions, never navigation.
Set `canContinue` to override the legacy readiness check, `isBusy` while working,
and `primaryAction` for an inline action when not ready. Once ready, the footer
calls `session.advance()`. All three properties are published; the session forwards
child changes so the shell updates. Capture the session weakly in action closures.
No page task edits the root switch, shared navigation or another task's page.
Provider configuration migration belongs to GUL-638; route/cloud actions belong
to GUL-637. Foundation moves shared navigation out of the existing setup extensions.
Keep legacy setup extensions stable during stage two: implement new actions in
owned page models, then GUL-642 removes unused compatibility methods.

## Existing services

- Cloud model owns an injected `WebLoginCoordinator`, observing every phase and
  calling start/reopen/cancel inline. Reuse the existing authenticated acceptance
  and `CloudLoginSyncCoordinator` handoff. The success NSAlert currently belongs
  to `LoginWindowController`; onboarding must not present that controller.
  Cancel pending login on session close and reject stale auth generations.
- Speech/LLM models adapt the injected `StudioViewModel` and `AskModelLibrary`;
  use inline configuration, validation and downloads, with no StudioView sheet.
  Preserve connection signature checks and cancellation when configuration changes.
  GUL-638 owns migration from `+SetupActions` and model-specific parts of `+Setup`.
- Permissions model wraps `PermissionsSettingsModel` with
  `SettingsPermissionService` and `SettingsPermission` as the authoritative
  status/action set; refresh on appearance and app reactivation, with scoped
  auto-detection while a System Settings guide is visible.
- Shortcuts model reuses `HotkeySettingsModel`, `HotkeyRecorder`,
  `HotkeyConflictChecker` and `SystemSymbolicHotkeys`. Persist through existing
  settings APIs; try reads live bindings. Do not duplicate conflict logic.

## Shared presentation

Foundation owns one file per component: `OnboardingBackdrop`,
`OnboardingEditorialHeader`, `OnboardingFooterBar`, `OnboardingSelectableCard`,
`OnboardingProviderCard`, `OnboardingConfigPanel`, `OnboardingSystemSettingsGuide`.
Each name is also its Swift filename. Components accept state/actions/content
slots; they never invoke login, permissions, downloads or settings directly.

- Window: 960 × 664 pt, transparent title bar with traffic lights only; diagonal
  gradient and 460 pt top-right accent glow (dark 0.16/light 0.10).
- Header: 34 pt inset, 9.5 pt eyebrow, 30 pt title, 13 pt subtitle; optional pill.
  Route/cloud centered, remaining pages left-aligned.
- Footer: 20 pt side/18 pt bottom inset, height 58, radius 20; optional back,
  tertiary action and hint; 38 pt primary/secondary capsules.
- Selection card: radius 18, fill/stroke, 1.2 pt outer ring at 3 pt offset,
  radio dot. Provider card adds a 38 pt white logo plate from Resources/Providers.
- Config panel: generic fields and result slots with pinned action row; guide:
  bottom-right overlay with injected steps and dismissal, no service side effects.

Remove setup rail and superseded header/footer as the shell replaces them.
Keep old feature-guide files/strings until GUL-642, as GUL-641 explicitly requires.
Use only prototype copy in all five localizations. Page tasks own their prefixed
keys in separate per-page string tables to avoid shared Localizable.strings edits;
foundation supplies the table-aware lookup before handoff. Broad dead-key cleanup
belongs to GUL-642.

## Localization lookup

Each locale directory (`Resources/en.lproj`, `zh-Hans.lproj`, `zh-Hant.lproj`,
`ja.lproj`, `ko.lproj`) contains `OnboardingShared.strings` plus the page tables
`OnboardingRoute`, `OnboardingCloud`, `OnboardingSpeech`, `OnboardingLlm`,
`OnboardingPermissions`, `OnboardingShortcuts`, and `OnboardingTry`. The exact LLM
table spelling is **OnboardingLlm**.

Use `OnboardingStrings.text("title", table: "OnboardingSpeech")` (or `step.table`)
in page views and `OnboardingStrings.text("continue")` for shared chrome. Format
arguments use `arguments: [value]`; tests may pass `language: .english`. Lookup
follows the selected app language, then English, then the key. The root observes
`AppLocalization.shared` so changing language updates the shell. Add page-owned
keys to the corresponding table in all five locales; do not pass these keys to
`L()`, which reads Localizable.strings. Existing welcome copy still uses `L()`.

## Validation and delivery

Focused tests cover route tables, fixed pill numbering, forward/back navigation,
route changes, skip persistence, resume priority, completion once and late-result
guards. Component tests cover optional slots, enabled actions, selection and
appearance; native captures verify actual geometry and clipping. UI/localization
suites use `.exclusiveUIState`. Run one focused coverage pass after implementation
and self-review, including affected existing onboarding suites, targeting ≥90%
changed-code coverage. Report exact commands and total wall times.

Capture every foundation page/state touched on this Mac in dark/light and
Chinese/English, comparing with the browser prototype. Place evidence in the PR
and attach it to the issue. Open `GUL-636: …` against main; do not merge. Only
mark in_review when the implementation, focused validation and evidence are ready.
