# Launcher input history

Reopening the launcher within 60 seconds of closing retains its input text and
selects all of it, so typing replaces the previous query. After 60 seconds, input
starts empty. This temporary recall stays in memory and resets with the session;
history filters are never retained. Each opening clears keyword mode, manually
attached files and chosen tools, and captures context from the current application.
Refocusing an already visible launcher keeps the current input and selection.
Text abandoned when closing can also be recalled from history.

Press **↑** in the empty editor (or above the first home row) to replace the
results with recent input. History is newest first. **↑/↓** move in screen
direction without wrapping. **Return, →, Tab, a click, or ⌘1…9** fill the
editor; the launcher computes current results and waits for another execution.
Holding **⌘** displays the existing number badges. **⌘Return** asks AI using
the selected entry and current captured context. **⌘Delete** deletes an entry.

Typing filters history by substring or Chinese pinyin initials, without running
keyword plugins. **Escape** clears a filter, then returns home, then closes the
launcher. **Backspace** on an empty filter returns home. Right-click offers fill,
ask AI, copy, delete and confirmed clearing. Input-method composition retains its
native keys. Both complete and simple launcher modes support recall.

Entries contain input text, a destination label and timestamp. Running a result
records its receipt; closing an unfinished input records it as unsent. Whitespace
and bare keywords are skipped. Unsent input needs at least two characters.
Identical input, ignoring case and surrounding whitespace, moves to the top.
Text is capped at 500 characters; labels at 200. Recall never replays an old
application or file action.

Launcher → General provides a history toggle (enabled by default), a 50/100/200
entry limit (default 100), and confirmed clearing. Disabling preserves existing
records but hides them and stops recording. History is stored only in this Mac's
`UserDefaults`, under `ask.launcher.inputHistory`. It is excluded from cloud sync
and contains no captured selections, screenshots, attachments or AI answers.
Launcher drafts are no longer restored from the conversation draft cache.

`AskLauncherInputHistoryTests` covers persistence, filtering, bounds, settings,
receipts, recall, fresh capture and attachment races.
`AskLauncherInputHistoryInteractionTests` drives the native editor and current
search results. Set `TYPEFLUX_HISTORY_SNAPSHOTS` to a directory when running the
interaction suite to export light/dark screenshots.
