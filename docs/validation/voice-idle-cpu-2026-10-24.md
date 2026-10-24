# Voice idle CPU: hidden overlay clock

## Supplied runtime evidence

The local collector measured 4.119 seconds before sampling. CPU-time deltas
were voice PID 11789: **20.15%**, host PID 11752: **1.46%**, background PID
11790: **0.24%**, chat PID 14253: **0.24%**. No screenshot process was present.
This interval does not establish a long-term average or prove CPU usage in
another window state. It does establish that voice, rather than chat or the
background worker, dominated this collection.

The voice sample contains 960 main-thread observations, including 330 in the
run-loop observer branch and 302 under the display-link transaction flush.
The layout branch enters SwiftUI, `TimelineView.UpdateFilter`, then
`VoiceCapsuleOrb.body` / `orb(angle:)` in `VoiceCapsuleContent.swift`. These
counts are stack observations, not CPU percentages. RPC receive is blocked
waiting for input, and worker threads predominantly wait for work. There is no
sampled active ASR inference hotspot. Voice footprint was 104.9 MiB, with a
109.4 MiB peak in this sample.

## Code cause and correction

`WorkflowController.start` prewarms the overlay with
`prepareRecordingPresentation`. This intentionally keeps its hosting view and
panel ready for the first recording. The initial presentation is
`recordingHold`, even when `isPresented` is false. Dismissal also preserves the
last recording/processing phase. Previously the orb's 30 Hz timeline tested
only that phase and Reduce Motion. Opacity zero and ordering the panel out
did not remove its timeline, matching the sampled repeated layout/rendering.
Window visibility itself is not recorded in the supplied archive; the hidden
clock defect is independently established by this lifecycle in source.

The overlay now propagates its existing presentation state through a local
SwiftUI environment value. The orb mounts a timeline only while presented,
in a live phase, and allowed by Reduce Motion. Otherwise it keeps static
artwork with no timeline. Hidden ripples are omitted, and the failure countdown
timeline pauses when the overlay is unpresented. All orb skins inherit the
same state; settings/previews retain their default animation behavior.

No model loading, retention, recording, audio, shortcut routing, window
preparation, or process ownership is changed. Closing still preserves the
panel for fast reuse; showing it reinstates animation. Appearance and dismissal
transitions continue to use the existing presentation state and cancellation
identity.

## Validation boundaries

Focused scope: `VoiceCapsuleAnimationTests` covers presentation/phase/Reduce
Motion policy, static prepared artwork and rendering of active states;
`VoiceCapsuleOverlayTests` covers all four skins' prewarm/show/hide/reuse and
existing controls/geometry; `OverlayTransitionTests` covers dismissal races and
late updates; `OverlayTransitionRenderingTests` covers native transition layout.
The tests use synthetic windows and bitmap rendering. They do not capture the
real desktop, record audio, send keyboard input or start the development app.

All **30 tests in four suites passed**. The successful focused coverage command
took **103.60 s** total (45.23 s preparation/discovery; tests 53.413 s). Changed
executable source-line coverage is **17/17 (100%)**, using the final matching
binary/profile and added-line intersections for the three changed production
files. This is line coverage for this correction, not project-wide or complete
branch coverage. `git diff --check` also passed.

Two preparation attempts ran no tests: the first took 331.59 s, including a
wait for another build, and found an invalid test attempt to set the read-only
system Reduce Motion environment value; correcting it while compilation was
draining also produced an input-file-changed diagnostic. Reduced Motion is now
covered by the policy matrix without changing that system environment value.
The second took 104.18 s and stopped when discovery returned another build's
smaller test inventory. The same focused scope was retried after that build
finished; the final discovery selected the intended 30 methods. No full test
suite or duplicate plain test pass was executed.

Before pushing, the unchanged correction was rebased onto upstream `a591cdb9`
(PermissionFlow integration), with no overlapping files or conflicts. An
integration build using `swift build --build-system native --enable-code-coverage
--target Typeflux --jobs 4` succeeded (target build reported 167.21 s). The
focused runtime results above precede that unrelated upstream integration;
they were not repeated after rebasing.

Actual CPU reduction on the user's Mac remains a local acceptance boundary.
After updating/restarting, leave the app untouched for two minutes, collect
again with `python3 scripts/collect_idle_cpu.py`, then exercise recording,
processing, dismiss/reopen and the selected capsule skin locally. Compare the
voice interval CPU before stack sampling; do not infer an exact CPU target
from the regression tests.
