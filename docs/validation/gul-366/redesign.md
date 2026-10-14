# Recording UI redesign — GUL-366

The implementation replaces the setup form and recording window with desktop selection and a floating toolbar/capsule. It follows the approved interactive design attached to GUL-366 on 2026-10-14. The existing capture, audio mixing, camera composition, MP4/GIF export and recovery paths remain connected to the same coordinator.

| Design surface | Implementation and behavior |
| --- | --- |
| Region selection | Live transparent desktop overlay; screenshot move/resize geometry, eight handles, point dimensions, 40 × 40 pt minimum. |
| Window and full screen | Window hover/point selection using front-to-back capture choices; direct selection on each display. Window border follows the current native window bounds. |
| Toolbar | Bottom centered, draggable; region/window/full screen, MP4/GIF, audio and camera switches, options, cancel and red start. Output summary and keyboard hints sit below it. |
| Options and permission | Segmented quality/FPS/countdown, cursor and folder controls. Device permissions are requested at toggle time, with a settings action or a way to omit the device. GIF audio controls are disabled. |
| Camera | AVCapture preview layer, snapped corner placement and 12–40% resizing mapped to the encoder's camera geometry. Setup device inputs shut down before recording opens its own inputs. |
| Countdown | Centered circular counter; Space skips, Escape returns to selection. |
| Recording | Undimmed desktop, corner brackets and pause dashes, movable capsule, level meter, pause/restart/discard/stop, confirmation, GIF countdown and menu bar stop indicator. Recorder windows are excluded from capture. |
| Editor | 920 × 632 target size, editable filename, format selector, AVPlayer, actual video thumbnails and PCM waveform, trim handles/playhead, 0.5-second minimum when available, Space/I/O/Command-S, GIF 30-second remedies. |
| Export | Named save, folder selection, explicit Save As, file URL copy, progress/cancellation, collision preservation and recoverable source on failure. |
| Saved and recovery | Draggable file thumbnail toast, Finder/copy/open, startup recovery with edit/discard/later. |

## Self-review

Reviewed the full route from menu/launcher/screenshot selection through recording, playback, trim, export and recovery; state guards and permission failures; owned file deletion and collision handling; cancellation/generation checks; device/sample queues and player/media observers; localization and appearances.

The review corrected interrupted restart starting another take, device previews not refreshing after authorization, capsule placement resetting after pause, file-name byte limits, and missing native save-button styling. The synthetic long recording also exposed a pre-existing writer bug: a busy encoder could omit the last static frame. Finalization now finishes audio inputs, waits for video readiness, appends the tail and completes with a bounded timeout. [Apple's input completion contract](https://developer.apple.com/documentation/avfoundation/avassetwriterinput/markasfinished%28%29) explains the interleaving requirement.

## Validation

Focused checks completed:

- `swift build`: passed; final code was also rebuilt by the instrumented test build.
- Recording coordinator, presentation, real codecs, visual snapshots, direct native input, device preview: 38 tests in 7 suites passed, 63.54 s total command time (57.63 s test-runner time); separate instrumentation build 198.27 s.
- Layout, publication, models, exclusion policy and localization isolation: 30 tests in 5 suites passed, 40.43 s total command time (36.71 s runner time). This included both enabled real ScreenCaptureKit page-pixel exclusion cases.
- Actual toolbar/capsule switches, permission omission, copy toast, progress rendering, native catalog and real MP4 region capture: 5 tests in 2 suites passed, 20.30 s total command time (15.49 s runner time). The native capture checked that the underlying green window was recorded while the red control window was excluded.
- Recording-source SwiftLint strict check and `git diff --check`: passed.

After rebasing onto main `1e94444b`, the five-language conflicts were resolved by preserving main and applying recording-only entries. The instrumented rebuild passed (132.06 s); the affected recording UI/presentation/model/localization scope passed 33 tests in 5 suites, 52.01 s total command time (49.18 s runner time).

Coverage uses an explicit `swift build --build-system native --build-tests --enable-code-coverage`, then the repository coverage runner with `--skip-build`. `swift test list --enable-code-coverage` in this Swift 6.3.1 environment built runnable tests without producing coverage output; both default and compatibility attempts executed passing tests but failed the coverage export. The successful runs above use the explicit instrumented build. Earlier compilation/fixture failures were corrected and rerun only in the affected scopes. The native window images in `redesign/` use synthetic media. AppKit display caching does not include the AVPlayer video layer; the `recording-native-editor-*` images capture the rendered window and include video.

Merged focused coverage: **1,863 / 2,190 changed executable lines (85.07%)**; recording module **4,772 / 5,525 lines (86.37%)**. Changed lines are matched against `origin/main` using `git diff --unified=0` and llvm-cov line counts, including newly added Swift files. This remains below the repository's 90% target. The largest remaining gaps are native file dialogs, device failure branches and some popover/drag actions.

Physical camera/microphone equipment, multiple physical displays and a macOS 13 runtime are not represented by these checks. The real screen capture cases above ran on the local macOS host.
