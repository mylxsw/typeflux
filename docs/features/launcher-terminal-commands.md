# Terminal commands in the launcher

Type `cmd <command>` or `> <command>` and press Return to run a single-line shell
command in a new terminal window. For example:

```text
cmd pwd
> cd ~/Projects/demo && git status
cmd printf '%s\n' "hello world" | wc -l
```

`cmd` is the primary keyword and `>` is its default alias. Both require a
separator before the command. Change their names, disable them, or choose
Terminal/iTerm2 in Settings → Launcher → Keywords → Terminal Command. Existing
keywords and workflow names take precedence during migration; settings reports
conflicting default names and offers adding another Terminal Command keyword.

The command runs in the selected terminal's default local shell configuration.
Its startup files, aliases, functions and version managers behave as they do
when opening that terminal manually. The initial directory follows the terminal
configuration. Specify `cd … && …` to choose another directory. Temporary state
from an already open terminal, such as exports or an activated virtual
environment, is not inherited. Profiles that immediately start SSH, attach tmux
or launch a different interactive program require a normal local shell profile.

Output, password prompts, interactive programs and cancellation belong to the
terminal. Use Ctrl-C there to interrupt a command. Closing Typeflux does not stop
an already dispatched command. A successful handoff says nothing about its exit
status.

Commands are limited to 16 KiB of UTF-8 and must contain no line breaks or control
characters. Quotes, spaces, variables, pipes and redirection are passed as text
to the terminal's shell, without a second shell evaluation in Typeflux.

Only an explicit launcher submission dispatches the command. Typing, selected
text, keyword hotkeys, workflow chains, refreshes and key repeats do not execute
it. The AI action is unavailable in this mode. Esc leaves the mode and clears
the command.

Typeflux does not save these commands in launcher input history or active
drafts. The terminal's own shell history and operating-system process visibility
continue to follow their normal rules.

On first use, macOS asks permission for Typeflux to control the selected terminal.
Pending consent keeps the launcher open through outside clicks; Esc can still
cancel the submission. If access is denied, use Option-Return in command mode to open Automation
settings. The command stays in the editor. A missing terminal is reported rather
than silently replaced. A timeout or uncertain response is never retried
automatically: inspect the terminal before submitting again.

The implementation uses a fixed AppleScript handler and an Apple Event string
argument. Command text is never interpolated into AppleScript source, written to
a temporary script, or placed in a helper process's command-line arguments.
Authorization finishes before the current input, keyword settings and launcher
presentation are checked again for dispatch. User authorization time is separate
from the 15-second Apple Event timeout. App launch on first use can also open the
terminal's own default window; the command always targets a new session.

The input prefix shows the terminal icon and the configured keyword (normally `cmd`).
The selected Terminal/iTerm2 target appears in the execution row rather than the prefix.
