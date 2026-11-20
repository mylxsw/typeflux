# Installed chat automation diagnosis

## Observed evidence

The earlier combined `click` and `getAXState` call exceeded the tool's 30-second execution limit. That observation did not establish a connection timeout or a frozen image renderer; the two operations were not separately timed.

On 2026-11-19, separate calls to the installed development application showed:

- App connection: 0.25 seconds.
- Settings navigation click: 0.24 seconds.
- Accessibility-state read after navigation: 0.42 seconds.
- Settings screenshot: successful in 0.09 seconds.
- The console was unlocked.
- Automated global shortcut attempts did not visibly open the launcher. A Finder menu action and a plain Return key did work. This does not establish why the modified/global shortcut was ineffective.

After the user manually opened Chat, process inspection found host PID 73587 and chat PID 85052. The chat executable is the same installed Typeflux binary, launched with `--feature-process chat --ipc-fd 100`. A one-second process sample identified the chat bundle as `ai.gulu.app.typeflux`, parent PID 73587, with its main thread predominantly waiting in the normal AppKit event loop. There was no evidence of a blocked chat main thread during this sample.

Despite Chat being open, repeated tool selection by full application path and bundle identifier returned a `WindowSharingSessionButton` dialog and the host menu bar, rather than the chat conversation. Tool inventory exposed a single Typeflux application identifier. The documented macOS app-selection API accepts name, bundle identifier or path, but has no PID or window selector. Rebinding by display name returned `Invalid app: Typeflux`.

## Conclusion and remaining boundary

The reproducible current blocker is selecting the correct window/process in a multi-process app with the same executable and bundle identity. It should not be reported as proof that the application, image service or network is timing out. The original combined-call timeout itself remains unattributed without tool-side tracing.

The automation adapter needs macOS PID/window selection (or correct selection of the frontmost visible window across matching processes). No product architecture, security permissions or data were changed to work around the adapter. Until the tool can bind the actual chat window, installed-chat click acceptance remains incomplete. Model/cache regression tests remain separate evidence.
