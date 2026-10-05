# GUL-217 screenshot review and corrections

Scope: the five native screenshots delivered with PR #312, explicitly referenced by the user. This follow-up preserves the approved guest/privacy flows and the existing native design language.

| Step | Finding in the supplied screenshot | Correction |
| --- | --- | --- |
| 1. Welcome | The close glyph touches the sheet's top edge; legal links blend into faint footer text. English verification also exposed a truncated privacy link and stale Apple-button styling in dark mode. | A 44-point navigation-bar close action, a full-height browse target, wrapping footnote text, accent-colored links and an Apple button that refreshes with appearance. |
| 2. Guest home | The disabled “Auto” model dropdown suggests an available setting but cannot open. | Replace it with a clear “Sign in to send” notice; keep model selection for authenticated users. Give the header login action a 44-point target. |
| 3. AI consent | An ungrouped block of prose ends in short left-aligned actions with a large empty lower area. | Group first-party sharing and external providers into cards. Use full-width bottom actions and explain that continuing never sends the draft automatically. |
| 4. Report answer | No excerpt confirms which answer is reported; a harmful-content reason is preselected; the explanation field loses its label when filled. | Show an answer excerpt, require deliberate reason selection, and separate the persistent explanation label from the sharing disclosure. |
| 5. Delete account | Consequences, subscription details and confirmation run together; a faint password placeholder and disabled action give little direction. | Separate the information into named sections, group confirmation with verification, add instructions and a persistent current-password label, and link the retention policy. |

Verification uses the native simulator and offline fixtures, never real accounts or provider calls. The UI tests exercise the selected reason before report submission, the full deletion flow, draft preservation, consent withdrawal, minimum close-target height, and reachable consent actions at the largest accessibility text size. English/dark-mode captures complement the Chinese/light-mode screens.

These screenshots and targeted checks do not constitute a full VoiceOver or accessibility compliance audit. Backend behavior and deployment requirements are unchanged from PR #312.

## Test results

- 155 iOS unit tests pass. Seven targeted interaction flows pass across the verification runs, including the new reason-selection guard, password-label persistence, large-text scrolling and English dark appearance. The initial close-target assertion found a 36-point automatic toolbar bridge; wrapping the custom control preserves its tested 44-point target.
- Localization files pass `plutil -lint`; Swift formatting and `git diff --check` pass.
- Required root `swift test`: the XCTest portion ran 2,877 tests with seven skips and no failures. The Swift Testing portion has six failing tests in the unchanged macOS window/desktop suites: `AskLocalApprovalTests`, `AskCappedWidthTests`, `AskComputerExecutorTests`, `AskComputerTargetProbeTests`, `AskConversationWindowSizingTests`, and `ReadOnlySelectionRequestTests`. This is not an all-green root test run.
