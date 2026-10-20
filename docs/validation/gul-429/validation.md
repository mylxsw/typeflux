# GUL-429 validation

Implemented against `b5831042`, including the concurrent Quick Ask launcher change.
The primary keyword is `cmd`; `>` is its default alias. Both submit a single-line
command to a fresh Terminal/iTerm2 window using the selected terminal's profile.

## Final verification

```sh
make coverage SUITE="TerminalCommandTests AskKeywordMatcherTests AskKeywordListTests AskKeywordAliasTests AskKeywordListPresentationTests AskKeywordDraftTests AskPluginSessionTests AskLauncherInputHistoryTests AskLauncherInputHistoryInteractionTests KeywordHotkeyRunnerTests HelpCatalogTests AskQuickAskTests ExclusiveUIStateLanguageTests AskLauncherToggleTests AskLauncherPrimaryActionTests"
```

All **173 tests in 15 suites passed**. Total command wall time was **62.60 s**,
including preparation, discovery, execution and coverage report generation.
Discovery/build took 31.33 s; test execution including runner startup took 28.02 s.
This was a fresh test execution using the verified incremental build, not cached
passing results.

Changed executable-line coverage is **90.62% (319/352)**. It was calculated from
LCOV `DA` records for added/modified production lines, including new Swift files,
against the final binary and its single-run profile. Resources and tests are not
part of that denominator. See `changed-line-coverage.json` for per-file counts.
This is changed-code coverage, not project-wide coverage.

The scope covers keyword parsing/migration/settings, plugin planning and session
behavior, exact Apple Event text round trips, the production AppleScript compiler
and error boundary, permission/error/stale-input handling, duplicate submission,
IME, keyboard submission, cancellation, history exclusion, AI exclusion, launcher
window behavior, help and Quick Ask compatibility. Terminal system launch and
consent are replaced with test doubles; application lookup is also exercised
read-only against Launch Services.

`swift build` passed before integration; the final coverage command rebuilt and
validated the integrated production and test targets. Both Info.plist files and
all five language resource files pass `plutil -lint`, with no duplicate resource
keys. `git diff --check` passes. The new Swift source/test files pass SwiftLint
without diagnostics. Broader modified files retain existing lint debt: comparison
against the same files at `b5831042` found 24 serious violations before and after,
with no added error categories/counts. No unrelated production refactor was made
to address those baseline size/complexity violations.

## Earlier passes and targeted fixes

| Pass | Total wall time | Result and follow-up |
| --- | ---: | --- |
| Initial 11-suite coverage | 347.58 s | 97 tests; the new terminal suite passed. One settings-list expectation omitted `cmd`; corrected. Cold preparation/build dominated this pass. |
| Integrated 13-suite coverage | 214.30 s | 133 tests; feature and Quick Ask tests passed. The language-isolation audit found existing suite metadata problems. |
| Language audit retry | 112.65 s | All 10 audit tests passed after adding the missing shared-state trait to eight suites and keeping two existing multiline opt-in annotations readable by the audit. Opt-in behavior is unchanged. |
| Additional terminal boundary coverage | 247.64 s | All 25 terminal tests passed, including real local AppleScript compilation/execution/error classification without executing terminal commands, plus settings conflict rendering. |
| Terminal/window lifecycle follow-up | 147.80 s | All 61 tests in three suites passed after protecting pending consent from outside-click dismissal and cancelling stale submissions before requesting permission. |
| Final single-build collection | 62.60 s | All 173 tests in 15 suites passed; this supplies the reported coverage. |

An attempted merge of profiles from earlier builds reported a counter mismatch
after the submission state machine changed. Those merged results were discarded;
the final report uses only the final unified run.

## Self-review

- Followed the full path from keyword matching through preview, explicit submit,
  authorization, current-input/settings revalidation, terminal dispatch and close.
  Workflow chains, keyword shortcuts and reruns cannot execute the command.
- Preserved command whitespace and quoting instead of the session's usual input
  trimming; rejected empty, multiline/control-character and oversized input.
- Prevented double submission and stale execution after editing, disabling a
  keyword, changing presentations or cancelling during/before authorization.
  Pending consent is protected from global/local outside-click dismissal while
  Escape and explicit launcher dismissal remain available.
- Excluded active and not-yet-tokenized command input from submitted/abandoned
  launcher history and AI submission. Esc/closing clears the command. The
  terminal's own shell history remains under its existing settings.
- Used fixed script source and Apple Event string parameters, with fixed terminal
  bundle IDs. Commands do not enter script source, helper arguments, temporary
  files or diagnostic messages. Uncertain dispatch is not replayed.
- Kept AppleScript work serialized away from the main actor and released local
  scripting objects in an autorelease pool. Terminal sessions belong to the
  terminal, not to the launcher's cancellable process runtime.
- Kept registration, keyword settings, help, both permission descriptions and all
  five localizations consistent. Reviewed the rendered launcher and light/dark
  keyword editor images for clipping and readable controls.

## Manual acceptance still needed

No user command was dispatched to a real terminal during validation. A signed app
still needs hands-on checks for first-use macOS consent, denial/recovery through
Automation settings, Terminal/iTerm2 cold starts, user profile startup files and
aliases/version managers, interactive programs and Ctrl-C. Custom profiles that
immediately attach SSH/tmux or run another interactive program are outside the
normal local-shell profile guarantee.

`terminal-launcher.png`, `terminal-settings-light.png` and
`terminal-settings-dark.png` are native rendering-harness captures, not proof of
real terminal execution or a signed-app permission grant.
