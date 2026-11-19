# Preserve generated images while previewing

## Evidence and correction

The reported failure occurred after an image had already displayed. The client recorded two imageLoad events at 2026-11-19T03:07:58Z in the chat process, both MediaFailure.unavailable. That error alone cannot distinguish decoder availability from resource admission and does not establish a network failure.

Inspection found that every model load unconditionally cancelled the existing presentation and released its pixels, including repeat loads for an already-ready asset under the same access scope. A subsequent unavailable error therefore replaced a successfully displayed image with a failure card. A regression fixture reproduces this destructive repeated-load behavior by making the transport unavailable after the first successful load.

Ready same-asset loads are now idempotent while the original and current access scopes remain authorized. An explicit refresh keeps the current pixels until replacement succeeds; failure leaves the image visible and shows a secondary error. Actual scope revocation and disappearance still release the image and cancel work. Generation identity checks continue to exclude stale completions.

The preview popover is attached to the stable image-card container rather than its conditional ready-image button. It displays the already-decoded image with an explicit bounded size and a close control. Opening it does not invoke download or decoding.

## Verification

`make coverage SUITE="AskRemoteImageTests AskGeneratedImageCacheTests"` passed all 23 methods in 105.28 seconds including compilation/discovery. AskRemoteImage.swift had 93.42% file line coverage in this scope; this is not whole-project or changed-line coverage.

The native-window regression uses accessibility presses to open and close the actual SwiftUI popover three times, verifies its image and close controls, retains the same NSImage instance, and asserts exactly one GET throughout. Another regression checks repeated loads, a failed explicit refresh and subsequent scope revocation. Existing cache, cancellation and view cleanup tests also pass. This verifies a real native fixture interaction, not a replay of the user's installed conversation or its original unavailable event. No paid image generation was requested.

The local development application is installed using the debug configuration.
