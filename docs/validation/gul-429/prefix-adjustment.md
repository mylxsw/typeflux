# GUL-429 compact terminal prefix

The input chip now shows the terminal icon and configured primary keyword (`cmd`
by default), without the redundant capability name, arrow or application target.
The execution row still names Terminal/iTerm2; settings and result headings retain
the localized full capability name. Other plugins keep their existing input titles.
The launcher screenshot in this directory was refreshed from the actual UI test.

## Verification

`make coverage SUITE="TerminalCommandTests AskQuickAskTests AskQuickResultsInteractionTests"`
ran 159 test methods: 156 passed and three failed. The complete terminal-command
and Quick Ask suites passed, including the new default/custom/symbol keyword
presentation checks and the real launcher submission/cancellation tests.
Total wall time: 481.21 s (build/discovery 381.98 s; runner 99.01 s).

The three failures were retried with:

```sh
make test FILTER='returnOnSignInFailureOpensLoginWithoutRerunningOrLosingTheDraft|aWorkflowThatClosesRunsItsActionsFirstAndFailuresRunTheirOwn|return on an image copies the image'
```

All three failed again (354.76 s including rebuilding without coverage). A control
run temporarily restored the input renderer's original `plugin.title` expression,
removing the only new input-label call site. The same three methods failed with
the same seven assertions (90.07 s). The compact renderer was restored afterward.
These tests cover login recovery, workflow completion actions and workflow image
copying; their failures remain unresolved. This control isolates the label call
site, rather than claiming a full unmodified-main baseline run.

Because the coverage wrapper stops on failed tests, its HTML report was not
produced. The initial instrumented run's raw profiles were merged and exported
before the retry rebuilt the binary. Changed executable-line coverage was 100%
(7/7), including the generic default title, terminal title/detail and actual
input renderer. See `prefix-changed-line-coverage.json`. This does not imply that
the entire regression scope passed.

SwiftLint passed for the modified terminal plugin and terminal test file.
`git diff --check` passed. Visual inspection confirmed a compact icon + `cmd`
prefix and an unchanged execution target row.

## Self-review

Reviewed the complete presentation path, default protocol dispatch for other
plugins, custom keyword and alias behavior, both terminal targets, accessibility
labels and title consistency in settings/results. Command validation, raw text,
submission, cancellation and dispatch resources were not changed. No new external
input execution, permissions or persistence were introduced. Removed incidental
formatter changes outside the requested scope. Unresolved broader test failures
are explicitly documented above.
