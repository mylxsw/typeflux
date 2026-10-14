# GUL-366 validation

Environment: macOS 26.6.2, Swift 6.4, Xcode macOS 27 SDK; deployment target macOS 13. Production code was reviewed before committing. `git diff --check` and the app/resource plist and signing entitlement checks pass.

## Automated checks

- Focused recording, screenshot integration and localization checks passed: 68 XCTest tests and 38 Swift Testing tests. The final focused recording pass after the native callback fencing and mixed audio format changes passed 45 XCTest tests and 33 Swift Testing tests.
- One final full `make coverage` run executed 3,789 XCTest tests (17 skipped) and 2,789 Swift Testing tests in 420 suites. It reported one XCTest failure and five Swift Testing issues, all from two existing menu assertions that omitted the newly added recording entry. No other failures were reported.
- Updated both menu expectations and added a behavior test confirming that recording starts after the menu action returns. The focused retry `swift test --no-parallel --enable-code-coverage --filter 'StatusBarMenuSupportTests|StatusBarWordBookMenuTests'` passed all 11 XCTest tests and 4 Swift Testing tests (including all five language variants). No known test failures remain. The full suite was not repeated, following repository policy.
- Because the full run exited on test failures before the coverage script's report step, its raw profiles were merged with `xcrun llvm-profdata merge -sparse` and exported with `xcrun llvm-cov export` before the focused retry. `coverage.json` records this full-run measurement, including native adapters and UI.

The tests exercise real AVFoundation and ImageIO using synthetic frames and audio: H.264/AAC MP4, two-source audio mixing (48 kHz stereo system audio and 44.1 kHz mono microphone), pause removal, static-screen tail duration, camera motion on a static screen, trimming, GIF frame delays and looping, cancellation, recovery and collision-safe publication. Coordinator tests cover permissions, delayed startup, interruption, export failure, screenshot interlocks and region handoff. They do not establish end-to-end hardware capture correctness.

## Coverage

New recording module: **73.05%** of executable lines (1,580 / 2,163, as reported by LLVM). This is below the repository's 90% target; native capture/device coverage remains a gap.

| Component | Line coverage |
| --- | ---: |
| Capture and native engine | 0% |
| Source catalog and authorization | 7.55% |
| Coordinator | 87.88% |
| Export and file handling | 92.49% |
| Models and geometry | 100% |
| Views and window controller | 78.90% |
| Media writer | 93.92% |

## UI snapshots

Generated from native views with synthetic recording data. These demonstrate layout, not live device recording.

| Setup (light) | Setup (dark) |
| --- | --- |
| ![Light setup](recording-setup-light.png) | ![Dark setup](recording-setup-dark.png) |

![Recording controls](recording-controls.png)

![Preview and trim](recording-preview.png)

## Manual acceptance still needed

- On macOS 13 and a current macOS release: grant/deny screen, microphone and camera permissions; record a display, a region on each monitor and an independent window.
- Record system audio and microphone separately and together; verify audible content and synchronization with camera picture-in-picture in each corner/size. Change window size, minimize it, remove a display and disconnect a device; verify interruption behavior.
- Pause/resume repeatedly, stop, trim and export both formats; verify GIF's silent 30-second limit. Quit normally during recording and recover the finalized source on relaunch.
- Exercise insufficient disk space and unwritable save directories, then retry export. Check long-duration CPU/memory and disk consumption, and GIF peak memory. These have not been measured here.

macOS 13 compatibility has only been checked through minimum-version compilation, not a macOS 13 runtime. MOV recovery depends on successful finalization and does not guarantee recovery after a crash or power loss. Camera and microphone use the system default devices.
