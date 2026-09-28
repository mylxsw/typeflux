# Ask composer — approved design 2

Source visual truth: `docs/images/ask-design2-reference.png` (GUL-124, revision 5,
option 2, approved by the “2” comment). The interaction specification takes
precedence over incidental AI-rendered checkbox states or sample copy.

Implementation evidence: `docs/images/ask-launcher.png`,
`ask-launcher-listening.png`, `ask-launcher-transcribing.png`,
`ask-workspace.png`, `ask-workspace-listening.png`, `ask-history-pull.png`,
`ask-workspace-dark.png`, and `ask-workspace-small.png` in the same directory.
These are production AppKit/SwiftUI views rendered with synthetic conversations
and a stub recorder. They are not a capture of live microphone or cloud activity.

## Comparison basis

The source is a 1024 × 1536 design presentation containing several separate
surfaces, captions and a wallpaper illustration. Compare each UI region, not
the entire presentation's aspect ratio. Native snapshots are 1×: launcher
640 × 110 pt/pixels (including its transparent glow gutter), main 1100 × 740,
minimum 760 × 560. CSS size/density do not apply to this native application.
Window placement is separately asserted against NSScreen.visibleFrame: the card's
visible bottom edge is 58 pt above the usable bottom, including after growth.

Checked idle/focused, listening, transcribing and returned-text states; sidebar
pull threshold; light and dark appearances; minimum window size; long input.
Full-view comparisons confirm the sidebar/transcript/composer composition and
removal of the refresh, header context and microphone controls. Focused launcher,
footer and history-edge images confirm the whole-card outline, soft glow,
status copy, disabled send state and release-to-refresh strip.

## Findings and iteration history

- Initial implementation needed a transparent gutter: a 5 pt halo would be clipped
  by the former 1 pt panel padding. Added 6 pt padding, adjusted the native window's
  bottom origin, and retained the visible 58 pt alignment. Post-fix launcher
  snapshots show the complete halo; native growth/reopen assertions pass.
- The first history indicator overlaid list content. Replaced it with a top inset
  strip. `ask-history-pull.png` shows readable rows beneath “松开刷新”; existing
  selection, drafts and transcript-anchor tests still pass.
- Recording status originally used normal text color. It now uses the application
  accent, matching the selected source; transcribing uses a weaker accent.

## Fidelity surfaces

- Typography: native system fonts/Chinese system fallback, editor 14 pt, compact
  sidebar 13 pt, footer 12 pt, section labels 11 pt. Actual glyph rendering replaces
  AI typography artifacts. Wrapping and persistent controls fit at minimum size.
- Spacing/layout: 210 pt sidebar, existing compact history rows, 12/14 pt card
  radii, 1.5 pt recording outline. The complete footer belongs to the highlighted
  card. Long input grows upward before internal scrolling.
- Color: existing dynamic StudioTheme surfaces/accent, with a static 0.22-opacity
  soft blue shadow during listening. Dark appearance preserves text contrast and
  state distinctions. No motion is required, including Reduce Motion.
- Assets: native SF Symbols and standard controls. The reference wallpaper and
  presentation captions are not app content. No product image or logo is replaced.
- Copy: listening/release and transcription states match the agreed semantics.
  Screenshot stays enabled for the first question and disabled for follow-ups;
  sample screenshot warnings demonstrate the existing permission fallback.

Expected differences: native checkbox appearance, actual text wrapping, retained
message attachment/tool affordances, and content-dependent transcript whitespace.
The reference's main-window title-bar decoration is outside the borderless view
snapshots; production windows still use native macOS window controls.

## Validation and limits

Automated checks cover bottom alignment/growth, native Return/IME/Escape behavior,
long-press eligibility and thresholds, transactional insertion/cancellation,
release during recorder startup, stale results, Fn routing, history drag/wheel
thresholds/momentum, failed refresh retention and history reading-position restore.
The CLI test runner uses a deterministic key-window test double for text delivery;
physical mouse/trackpad feel, real microphone permissions, hardware interruptions
and actual provider audio must still be smoke-tested in a signed app.

No actionable P0/P1/P2 visual findings remain. P3 follow-up: calibrate the 350 ms
hold threshold with real-device usage, without changing native text selection.

## Transparency follow-up (2026-09-29)

The previous screenshots did not expose desktop bleed-through because the test
window's ordinary background masked translucent surfaces. Opaque Ask-specific
backplates now cover the launcher, workspace, sidebar and complete input card;
the native workspace window is explicitly opaque too. The floating panel retains
its transparent corner/glow gutter.

The new pixel regression uses production views over red/blue backgrounds with a
clear native window. It reproduced the old bug with 20 failing assertions and
passes after the fix in Aqua and Dark Aqua, including alpha-1 interior and alpha-0
outer-corner checks. All three existing native window/render tests also pass.
Updated screenshots use the same viewports and fixtures; `ask-launcher-dark.png`
adds the dark floating surface. The dark launcher and listening workspace were
visually inspected after the fix. This resolves the transparency mismatch without
changing the agreed edge glow.

Final result: passed
