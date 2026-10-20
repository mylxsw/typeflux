# Terminal commands in the launcher

Type `cmd <command>` or `> <command>` and press Return to run a single-line shell
command. For example:

```text
cmd pwd
> cd ~/Projects/demo && git status
cmd printf '%s\n' "hello world" | wc -l
```

`cmd` is the primary keyword and `>` is its default alias. Both require a
separator before the command. Change their names, disable them, or change how
commands run in Settings → Launcher → Keywords → Terminal Command. Existing
keywords and workflow names take precedence during migration; settings reports
conflicting default names and offers adding another Terminal Command keyword.

Return uses the keyword's run mode; Command-Return uses the other one:

- **Built-in** (default): the command runs in a small Typeflux terminal window.
- **External app**: the command is sent to a new Terminal or iTerm2 window.

## Built-in terminal

The window floats above other apps and takes keyboard focus without activating
Typeflux, so the app the launcher came from stays frontmost. It is a full
terminal (SwiftTerm): colors, progress bars, password prompts, Ctrl-C, mouse and
full-screen programs such as `top`, `vim` or `less` work. A full-screen program
enlarges the window to 860×520 while it runs.

The command runs in a pseudo-terminal under the account's login shell (System
Settings → Users & Groups), started as `<shell> -l -i` so `.zprofile` and `.zshrc`
(or the bash/fish equivalents) are read and aliases, functions and version
managers work. "Login only" drops `-i` for faster starts without the interactive
configuration. zsh, bash, sh, dash, ksh and fish are supported; other shells fall
back to `/bin/zsh`.

The environment is rebuilt rather than inherited from Typeflux. It keeps `HOME`,
`USER`, `LOGNAME`, `TMPDIR`, `SSH_AUTH_SOCK`, `__CF_USER_TEXT_ENCODING` and the
locale variables, sets `LANG` from the region when missing, a minimal `PATH` that
the login files extend, `TERM=xterm-256color`, `COLORTERM=truecolor`,
`TERM_PROGRAM=Typeflux` and `TYPEFLUX_TERMINAL=1`. Startup files can check
`TYPEFLUX_TERMINAL` to skip what only makes sense in a full terminal, such as
starting tmux or printing a greeting.

The command text reaches the shell in the `TYPEFLUX_COMMAND` variable, which the
shell removes before evaluating it. It is not a command-line argument, so other
users cannot read it with `ps`, and the command's own processes do not inherit it.
Typeflux's open files are closed and signal handling is reset before the shell
starts.

The working directory defaults to `~` and can be set per keyword. A missing
directory is reported in the window instead of falling back silently.

### Header and footer

The header shows the command, its directory, the running time and a pin that
keeps the window above other windows. The status shows a spinner while running,
orange while the command reads input with echo off (a password), blue for a
full-screen program, green for exit code 0 and red otherwise.

While running, Stop sends Ctrl-C; pressed again it becomes Force Stop and hangs
up the command. After it exits:

| Action | Key |
| --- | --- |
| Insert the output into the app the launcher came from | ⌘↩ |
| Copy the output | ⇧⌘C |
| Run again in the same window | ⌘R |
| Run again in the external terminal | header button |
| Close | Esc |

Output means the normal screen and its scrollback (10,000 lines), without
trailing blank lines. If the output cannot be inserted it is copied instead.

### When the command ends

- **Smart** (default): a success without output closes the window and shows a
  short note; output or a failure keeps the window open.
- **Keep open**: the window always stays until it is closed.
- **Close**: any success closes the window with a note; a failure stays open so
  its error can be read.

When a command that ran for at least 10 seconds finishes while its window is not
focused (or closes itself), a system notification reports the result. This can be
turned off per keyword.

### Closing and quitting

Closing the window while the command runs asks first. Ending it sends SIGHUP to
the command's process group and the terminal's foreground job, then SIGTERM and
SIGKILL two seconds apart while it is still running. Quitting Typeflux hangs up
every running command.

Commands run with Typeflux's privacy permissions: macOS asks whether *Typeflux*
may access protected folders such as Documents. Use the external terminal for
commands that need the terminal app's own permissions (for example Full Disk
Access).

## External terminal

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

## Both modes

Commands are limited to 16 KiB of UTF-8 and must contain no line breaks or control
characters. Quotes, spaces, variables, pipes and redirection are passed as text
to the shell, without a second shell evaluation in Typeflux.

Only an explicit launcher submission runs the command. Typing, selected text,
keyword hotkeys, workflow chains, refreshes and key repeats do not execute it.
The AI action is unavailable in this mode. Esc leaves the mode and clears the
command.

Typeflux does not save these commands in launcher input history or active
drafts. The shell's own history and operating-system process visibility continue
to follow their normal rules.

The input prefix shows the terminal icon and the configured keyword (normally `cmd`).
The run mode and target appear in the execution row rather than the prefix.
