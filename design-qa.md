# Ask surfaces — approved redesign (GUL-124, revision 6)

Source visual truth: the five review boards attached to GUL-124
(`ask-redesign-01-launcher`, `-02-workspace-light`, `-03-workspace-dark`,
`-04-components`, `-05-tokens`) and their written spec. They replace the
earlier "design 2" reference in `docs/images/ask-design2-reference.png`.

The boards are HTML/CSS review renders, not AppKit captures. Where a board and
the interaction specification disagree, the specification wins.

## What the redesign changes

- **Launcher** — 680 × 102 pt card (58 pt editor row + 44 pt footer) inside a
  6 pt transparent gutter, centred above the bottom of the screen with the same
  58 pt visible offset as before. The footer uses a lighter backplate so the
  panel reads as a command palette rather than a form.
- **Capsules instead of controls** — the screenshot switch, the selection and the
  source application are capsules: filled accent when on, amber when a
  permission is missing, dashed when available but off. The native check box and
  the inline orange warning text are gone; a missing permission never blocks
  sending.
- **Colour means state** — accent for running/sendable, green for a finished
  tool, amber for "needs your decision", red for a failure. Ordinary focus keeps
  a neutral border; only recording paints the card accent with a 5 pt glow.
- **Workspace** — 248 pt sidebar with local search, a primary "new conversation"
  button and date groups; user turns are right-aligned bubbles and assistant
  turns are signed paragraphs capped at 680 pt for readability. The grey "You"
  label is removed.
- **Tool calls** — one 40 pt collapsed card per call with a status badge,
  expanding to monospaced arguments and result. Approval happens inside the card.
- **Message actions** — a persistent row with copy and quote-as-follow-up,
  replacing the unlabelled floating icon.
- **Empty state, banners** — a new conversation offers three starting prompts;
  errors, retries and resume prompts share one rounded banner instead of red
  body text.

## Fidelity surfaces

- Typography: system fonts with the Chinese system fallback. Launcher editor
  15.5 pt, workspace editor 14 pt, message body 13.5 pt, sidebar row 12.8 pt,
  footer and captions 11.5–12 pt, group labels 10.5 pt.
- Spacing and shape: launcher radius 18, composer and panel cards 14, window and
  tool cards 12/11, buttons 8, banners 10, capsules fully rounded. Borders are
  1 pt; the recording border is 1.5 pt.
- Colour: opaque backplates in both appearances (`AskTheme.surface`,
  `raisedSurface`, `sidebarSurface`). Only the rounded exterior, the shadow and
  the recording glow carry transparency.
- Motion: the level meter is the only continuous animation and it is replaced by
  a static meter when "Reduce Motion" is enabled. Every state is also
  distinguishable from its label alone.

## Verification

- `AskPresentationTests` covers history search, selection line counts, tool
  state and symbol mapping, quoting, launcher panel geometry, the neutral-focus
  border rule and the level-meter bounds.
- `AskRedesignLayoutTests` renders the real views: the launcher reports the new
  panel height at rest and while growing, and the workspace keeps an opaque,
  visually distinct sidebar in both appearances.
- `AskSurfaceOpacityTests` still proves no desktop colour bleeds through the
  launcher card or the workspace, at the new panel size.
- `AskComposerInteractionTests` and `AskVoiceInputTests` are unchanged and keep
  covering hold-to-talk, focus hand-off between the two windows, IME and
  selection behaviour.

## Known gaps

- The PNGs in `docs/images/` still show the previous revision. They are produced
  by the opt-in `TYPEFLUX_ASK_SNAPSHOTS` run on a real macOS host and have not
  been regenerated for this revision.
- Sidebar rows stay single-line: the history list API returns only a title and a
  timestamp, so the two-line snippet in the board needs a server-side field
  before it can be implemented.
- The message action row shows copy and quote. Per-answer token usage is not
  available to the client, so the board's "duration · tokens" caption is not
  implemented rather than being faked.
