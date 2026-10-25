# Clipboard snippet editor

The editor now uses TFSectionHeader, TFTextFieldStyle, TFTextArea, TFFieldMessage,
TFFootnote, TFIconTile and TFButton, with the shared in-window surface and sheet radius.
The form scrolls independently of its fixed action footer. Expanding voice aliases
reserves more room for the alias field. Editing clears stale save errors.

Validation: `make coverage SUITE="ClipboardSnippetTests"` passed all 9 methods,
covering persistence, validation, panel editing, and native rendering. Final runner
wall time: 84.52 seconds including build and discovery. Changed executable-line
coverage: 73/76 (96.1%); editor file line coverage: 97.40%.
Earlier attempts were interrupted by concurrent source edits (36.97s and 51.47s).
The first successful pass took 265.59s including shared build-directory waits;
screenshot review then prompted the final height adjustment and compact fixture fix.

Snapshots were visually reviewed in dark, light, error and compact states. The
compact fixture hosts the editor directly because the clipboard panel itself has
a larger minimum size. These are NSHostingView renders with an opaque material,
not screenshots of an installed app. The running app was not repackaged or relaunched.
