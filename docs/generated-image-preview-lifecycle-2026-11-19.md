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

## Additional fidelity and reopen acceptance

The added `testRealPNGReopensOfflineWithFreshModelsAndDecoder` uses a real PNG and the production media-helper decoder, without an injected decoder. Five successive presentations use fresh model, worker, scope and disk-cache instances. The first fetch supplies the PNG; every later transport is explicitly offline. Each presentation must restore the expected dimensions, preserve the exact original PNG bytes on disk, and release its pixels when its scope becomes invisible. The whole sequence must issue exactly one GET. Fresh objects exercise disk reconstruction; this is not an installed-app process restart test.

A read-only check of the installed development app's cache found three originals totaling 11,750,249 bytes. Each was copied to an isolated temporary directory and successfully decoded by the installed `TypefluxMediaHelper`, producing 1600x900, 1254x1254 and 1600x900 rasters. No network or generation request was involved, and the original cache files were not changed. The installed bundle also passed strict deep code-signature verification.

Installed-chat acceptance remains incomplete: the UI connection could read the launcher and settings, but opening Chat timed out and a subsequent screenshot was unavailable. These checks do not establish that clicking the user's image, switching conversations, restarting the installed app or using it offline has passed. Do not replace this outstanding acceptance with a claim of complete resolution.

Focused coverage for the new real-PNG regression passed one selected method; total runner wall time was 83.47 seconds including compilation and discovery. No production source changed in this acceptance pass.
