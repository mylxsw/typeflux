# GUL-430 validation

Implemented on baseline `6a4b2028`. No production provider requests or billable model calls were used during validation: cloud/local APIs are scripted fixtures. Screenshots render the production SwiftUI/AppKit launcher with synthetic conversation content.

## Results

- 193 distinct test methods across 17 focused suites have passing results after targeted repairs/retries (25 Quick Ask methods and 168 existing regression methods).
- Final run: `TYPEFLUX_ASK_SNAPSHOTS="$PWD/docs/validation/gul-430" make coverage SUITE="AskQuickAskTests"` — 25 passed, 51.77 seconds total, including 32.06 seconds of build preparation; test execution reported 5.051 seconds.
- Changed executable-line coverage: **306 / 328 = 93.29%**, measured from the final binary's own coverage profile. This is changed production Swift line coverage, not whole-project or branch coverage. `changed-line-coverage.json` contains the per-file counts and uncovered lines. Tests and localization resources are excluded from executable-line totals. Profiles from earlier binaries were not used for this figure.
- Light/dark launcher renders inspected: action buttons remain visible at a 420-point host height, Markdown/code is readable, and conversation content stays in the launcher.
- `git diff --check` passes.

## Scope and retries

The initial coverage scope was:

```sh
make coverage SUITE="AskQuickAskTests AskOpenChatTests AskConversationTests AskSubmissionPreflightTests AskTemporaryConversationTests AskKeywordMatcherTests AskKeywordListTests AskKeywordAliasTests AskKeywordListPresentationTests AskKeywordDraftTests AskPluginSessionTests AskLauncherPrimaryActionTests AskLauncherInputHistoryTests AskLauncherInputHistoryInteractionTests AskLauncherWindowModeTests AskLauncherFixedHeightTests AskComposerTests"
```

Conversation/submission/temporary tests cover the shared request and persistence paths; open-chat tests cover displaced drafts; keyword/settings/plugin tests cover registration and configuration; composer/window/history tests cover the affected launcher callers. Quick Ask tests exercise real native keyboard routing and accessibility button activation, stream handoff, no duplicate sends, cancellation, server errors, account isolation, local/temporary routing, model preflight, and unexpected tool rejection.

The initial 187-method run took 357.79 seconds and exposed outdated keyword counts and incorrect new fixtures (terminal runs cannot be resurrected, local storage requires an available local model, and synthetic newline events need characters). Corrections were followed by a 63-method, four-suite retry (125.45 seconds). Remaining accessibility lookup and synchronous mouse-tracking issues were confined to the new test driver; a blocked helper was terminated and activation now uses the native accessibility action. The interrupted driver attempt took 169.54 seconds. A 23-method run then passed in 58.13 seconds. Coverage additions exposed an actual Esc exit issue: a saved question beginning with an existing keyword could enter another plugin. The failing coverage-addition run took 72.59 seconds. That path was fixed and the final 25-method run passed. No full-suite or unrelated tests were executed.

## Artifacts

- `quick-ask-light.png`
- `quick-ask-dark.png`
- `changed-line-coverage.json`
