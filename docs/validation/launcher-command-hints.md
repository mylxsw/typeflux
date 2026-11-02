# Launcher Command hints: remote-session input

Date: 2026-11-02 (UTC+08:00).

## Confirmed cause

`AskLauncherCommandMonitor` read `CGEventSource.flagsState(.hidSystemState)` when
attaching, becoming key, receiving modifier events, and polling for release.
That table describes hardware sources, not the current login session's combined
input. Screen Sharing generates input with a private event source. Its releases
can update the session table while leaving the hardware table unchanged.

Opening the launcher with Option-Space therefore evaluated an unrelated hardware
Command state and displayed persistent shortcut badges. The release timer kept
reading the same wrong table; waiting or reopening the panel could not fix it.

## Captured evidence

A passive, listen-only event observer sampled both tables and observed modifier
events at HID, session, and annotated-session taps. It did not suppress or generate
input, or record typed characters.

- Initial hardware flags: `0x20100000`; left Command key state: `true`.
- Initial combined-session flags: `0x20000000`; both Command key states: `false`.
- Screen Sharing process: `ScreensharingAgent`, PID `26822`.
- Its captured modifier events carried private source state ID `1577418325`.
- At observer offset `144.856s`, its Shift press changed session flags to
  `0x20020002`; at `145.040s`, its Shift release changed them to `0x20000000`.
- Throughout both transitions, hardware flags stayed at `0x20100000` and hardware
  left Command stayed `true`.
- The user confirmed the launcher was opened with Option-Space.

This proves that the active remote input and HID table diverge on this machine.
The original physical Command press predates this observation; no historical
input log exists to identify its origin. Do not claim that Ring, synthetic paste,
or Screen Sharing dropped that original release.

Apple defines the combined-session table as the combined state of all event
sources posting to the login session, and explicitly describes private sources
for remote-control programs:
<https://developer.apple.com/documentation/coregraphics/cgeventsourcestateid>

## Fix and regression contract

Read `.combinedSessionState` directly, including the existing 100ms release poll.
Do not use cached `NSEvent.modifierFlags`, the HID table, or an intersection with
the HID table. Requiring agreement would hide a real remote Command press when
no local hardware Command is held.

Regression checks cover:

- hardware Command held, session Command released: hide;
- hardware Command released, session Command held: show;
- unrelated hardware Shift: do not block a session Command press;
- session Shift, Option, or Control with Command: hide;
- release without a local AppKit event: the timer hides hints;
- window focus loss and monitor teardown: clear hints;
- launcher Command action, clipboard numbering, and recording shortcut layout.

## Validation

Focused command:

```sh
make test FILTER='AskLauncherNumberShortcutTests/|ClipboardPanelNumberShortcutTests/|ScreenRecordingUIInteractionTests/|AskLauncherPrimaryActionTests/holdingCommandOnEmptyHomeTurnsTheButtonIntoOpenChat'
```

Result: 22 tests passed (3 XCTest and 19 Swift Testing cases). Total command wall
time: 118.94 seconds, including runner queueing and preparation. The timer
regression used a real key window and completed successfully in 0.321 seconds.

The debug development app was rebuilt, installed, signed, and launched through
`make run`. Build and installed binary UUIDs both matched
`B65005A2-53CB-3534-9320-8C17BB72183A`. Deep/strict signature verification passed.
The new host process was observed running. After installation, the user opened
the launcher with Option-Space without holding Command and confirmed that the
shortcut hints no longer remain visible. This verifies the original reported
scenario on the running development app.
