# Recording-time screenshot and clipboard shortcuts

## Behavior and review

The recording-stop gate returned before screenshot/history dispatch for every new
physical press. Route these independent features through their existing request
methods before returning, retaining deduplication with system hotkeys. Do not send
their chords into the voice gesture arbiter: that would change a held voice gesture.
Stop recognition still runs first, and voice releases still reach the original arbiter.

Review also found and addressed three adjacent cases:

- While holding Fn (or another voice shortcut), feature matching ignores only extra
  modifiers owned by that held voice shortcut. Required feature modifiers remain.
- Repeated feature key-downs are consumed without reopening the feature or leaking
  characters into the focused editor.
- The clipboard controller's synchronous and asynchronous open paths blocked
  recording. Both now permit recording, while retaining the processing guard.
  Empty/error notices use the clipboard panel during recording so they cannot
  replace the voice overlay and its stop controls.

Screenshot coordination checks screen recording, not voice recording; no native
capture change was needed. Clipboard copy/dismiss does not cancel the audio or
replace the voice processing session. Existing retry handling refuses to replace
an active voice recording. The native clipboard window is non-activating; actual
OS focus and paste behavior still require desktop acceptance below.

## Focused validation

74 distinct test methods passed across the initial scope and focused retry:

- `RecordingFeatureHotkeyTests` (3): locked/held voice, screenshot and clipboard
  dispatch, ordinary typing, repeat suppression, modifier-only feature shortcut,
  held Fn, and release/stop without cancellation.
- `RecordingStopGestureTests`, `HotkeyGestureArbiterTests`, `ScreenshotHotkeyTests`:
  existing stop, double-tap, hold/release and screenshot routing behavior.
- `FeatureShortcutOwnerTests`: multi-process dispatch destinations while recording.
- Selected `WorkflowControllerProcessingTests`: clipboard open/copy/dismiss during
  recording, unchanged audio/session state, final transcription delivery, empty
  clipboard retaining the voice overlay, and existing history/voice controls.

The final-delivery fixture uses an actual generated WAV file, with injected audio
recorder, transcriber and text injector. It verifies the production workflow but
is not evidence of physical microphone recognition or typing into another app.

Commands used `make coverage FILTER=...`. Initial build failed before executing
any tests because this Xcode's native SwiftPM coverage build did not discover
`SwiftUIMacros` (20.68 s). A temporary, uncommitted Swift wrapper supplied
`-Xswiftc -external-plugin-path -Xswiftc` with the installed macOS host-plugin and
Swift plugin-server paths. No dependency or build configuration was committed.

The first completed scope selected 73 methods (251.51 s including build/discovery):
72 passed; the new delivery fixture failed because its original mock returned a
nonexistent WAV. Replaced it with the generated file. A retry build was invalidated
by the final repeat-handling review edit (69.36 s; no tests executed). The final
retry selected the three feature tests plus the corrected delivery test: all four
passed (77.31 s including build/discovery).

Changed-production-line coverage: **40/41 instrumented added lines, 97.6%**.
The final binary's coverage was used for the hotkey change; unchanged history
source coverage was combined by line with the first run. Incompatible hotkey
profiles were not combined. The uncovered added line is the clipboard read-error
notice call. This is line coverage, not proof of every switch branch or OS behavior.

## Desktop acceptance limitation

The desktop automation service timed out when selecting Typeflux by both path
and bundle identifier, and also timed out selecting TextEdit. Consequently no
claim is made that physical recording + real screenshot capture + clipboard
interaction + insertion into an external editor was manually accepted. This
remains unverified despite the passing focused tests.

The updated debug development app was subsequently built, signed with the existing
stable development identity, and launched successfully at
`~/Applications/Typeflux Dev.app`. Selecting the newly launched app through desktop
automation still timed out. Installation/launch is confirmed; desktop acceptance
is not. The development build includes the existing working tree; unrelated Ask
cache/API changes are excluded from this repair commit.
