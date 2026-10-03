# Ask selection diagnostics

Ask captures the source application and a capture ID before showing the launcher.
Selection reads use AX only: no automatic copy shortcut, clipboard probe, menu
action or focus restoration. Applications with incomplete AX support can still
be used by manually copying and pasting context into Ask.

Find the structured `[Ask Selection]` events in the macOS unified log:

```sh
log stream --level info --predicate 'subsystem == "ai.gulu.app.typeflux" AND eventMessage CONTAINS "[Ask Selection]"'
```

Events share `captureID`, `pid`, `app`, `bundleID`, `status` and
`clipboardProbe=disabled`. The AX search event also contains visited `nodes`,
`roles`, `positiveRanges`, `emptySelections`, `selectionReads`, `unsupportedReads`,
`noValueReads`, `invalidValues`, `axErrors`, `operations`, `elapsedMS`, `budgetStop`
and `treeTruncated`. `axErrors` maps `attribute:rawAXErrorCode` to occurrence counts.
The final event (`phase=capture-result`) reports the injector result; a later
`target-changed` or `capture-cancelled` event means the context was discarded.
Selection text, AX values, window titles and screenshot contents are not logged.

| Status | Meaning |
| --- | --- |
| `accessibility-context` | AX supplied usable selection text. |
| `no-selection-found` | Empty text/ranges were observed and no usable selection was found. This is not proof that every control supports AX. |
| `selection-unreadable` | A nonempty range was found, but its text could not be read. |
| `ax-unsupported` | All attempted selection attribute reads reported unsupported/not implemented. Applies to the searched nodes, not necessarily every window in the app. |
| `ax-no-value` | AX reported no value, without positive evidence of an empty selection. |
| `ax-cannot-complete` | AX returned `cannotComplete`; this may indicate an unresponsive app or timeout, not proven lack of support. |
| `ax-error` | Another AX error occurred; inspect the raw codes and attributes. |
| `invalid-ax-value` | AX returned malformed text/range data. |
| `search-incomplete` | Operation/deadline budget or a tree limit stopped the search; do not interpret this as no selection or unsupported AX. |
| `selection-unavailable` | No usable evidence was available, for example no accessible roots. |
| `permission-missing` | Accessibility permission is missing. |
| `source-unavailable` / `target-changed` | No original app, or the source app/window changed; no new app is queried as fallback. |
| `capture-cancelled` / `capture-busy` | Cancellation or the serialized text-operation queue prevented capture. |
| `selection-not-requested` | Screenshot-only refresh. |
| `pinned-source-unavailable` | The injector does not implement pinned-source capture. |

Counts and raw AX errors remain available even when the primary status reports a
successful selection or a higher-priority failure. One collapsed caret never
stops the source-window subtree search. Ordinary empty or unsupported selections
do not show a warning to the user.

For manual regression checks, compare TextEdit and an affected application with
and without selected text. Verify immediate typing into the launcher, closing
and reopening during capture, switching applications, Chinese/emoji text and
multiple ranges. Correlate logs by capture ID; confirm no clipboard change or
automatic-copy beep. Automated AX tests do not verify audible behavior.
