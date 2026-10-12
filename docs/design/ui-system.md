# Typeflux UI System v2 — Apple native

The interactive board is `docs/design/ui-system.html`. Switch style (传统 / Liquid Glass), appearance and accent colour in its top-right corner. This file is the written spec. When it disagrees with the board, this file wins.

## 1. Direction

The two interface styles map to the two macOS generations Typeflux runs on:

| Style | Looks like | Notes |
| --- | --- | --- |
| 传统 (Classic) | macOS 15 Sequoia | Opaque surfaces and a vibrancy sidebar. This is also the baseline on macOS 13–15. |
| Liquid Glass | macOS 26 Tahoe | Liquid Glass on the navigation layer only. |

Every size, radius and material follows the system apps: Finder, Notes, Messages, System Settings and Spotlight.

On macOS 26, native controls always take the Tahoe shape, and an app cannot force them back to Sequoia. So on macOS 26, 传统 means **"no glass materials"**: opaque sidebar, toolbar, menus and panels. This matches the system's Tinted appearance.

## 2. Principles

1. **Glass is for the navigation layer only.** That means toolbar, sidebar, menus, popovers, floating panels and sheets. Content stays on solid surfaces with standard controls, as the HIG requires.
2. **Use system controls; don't draw them.** Native SwiftUI/AppKit controls render the Tahoe look on 26 and the Sequoia look on 13–15 automatically. Custom drawing is reserved for the Spotlight-style panel, the HUD and the recording overlay.
3. **Use system semantic colours and text styles.** Use `labelColor`, `separatorColor` and similar, and use `controlAccentColor` so the accent follows the user's choice in System Settings. Text uses `Font.TextStyle` (`.body`, `.headline`, …), with no numeric sizes and no half-point sizes.
4. **Titles live in the toolbar.** Use `.navigationTitle`, as in Finder and System Settings. Remove the 22pt in-content headings and subtitles.
5. **Concentric radii.** Window 26 → sidebar inset 8 → sidebar 18 → row inset 8 → row 10.

## 3. Changes from v1

| v1 | v2 |
| --- | --- |
| Search field always visible | A magnifier in the toolbar. Click or ⌘F expands it, with a spring, into a capsule field. It collapses when it is empty and loses focus. The first Esc clears it; the second collapses it. A non-empty query keeps it expanded. (`.searchable(placement: .toolbar)` / `NSSearchToolbarItem`.) Menus, popovers and pickers keep a small always-visible field because they have no toolbar. |
| Glass cards, buttons and fields | Glass only on the navigation layer; content is solid |
| Every control a capsule | Regular sizes use rounded rectangles; large and toolbar controls use capsules (Tahoe) |
| Custom select | Native pop-up button. The menu opens with the selected item over the button. Settings rows use the borderless style. |
| Filter chips | Segmented control (≤4 options) or a toolbar filter menu. Token style is only for attachments and context references. |
| Underline tabs | A segmented control in the toolbar centre (as in Finder and App Store) |
| Dark tooltip bubble and toast | Native help tag. Feedback happens in place (for example, a button icon turns into a check mark). A HUD is used only for confirmations that have no context. |
| Custom launcher/clipboard panel | Spotlight layout: a glass capsule input, circular glass mode buttons, and a glass results panel below |
| Hard-coded `#2563EB` accent | `controlAccentColor` |

## 4. Metrics

| Item | 传统 (Sequoia) | Liquid Glass (Tahoe) |
| --- | --- | --- |
| Window radius | 10 | 26 |
| Sidebar | Flush, row 28, radius 5 | Floating inset 8, radius 18, row 32, radius 10 |
| Toolbar | 52 high, borderless 28×24 items | 52 high, items grouped in 36pt glass capsules |
| Toolbar search | Collapsed 28×24; expanded 200×24, radius 6 | Collapsed ⌀36; expanded 240×36 capsule |
| Push button (regular / large) | 22 r5.5 / 28 r7 | 26 r8 / 34 capsule |
| Pop-up button | 22 r5.5, accent chevron box | 26 r8, grey chevrons |
| Text field | 22 r5, bezel | 26 r8, fill |
| Segmented | 22 r6 | 28 capsule |
| Switch | 32×18, round knob | 38×22, capsule knob (becomes a glass lens while pressed) |
| Checkbox | 14 r3.5 | 16 r5 |
| Grouped form | Group r8, row 36 | Group r14, row 40 |
| Table row | 24 | 28 |
| Menu / item / highlight | r6 / 22 / r4 | r14 / 24 / r8 |
| Popover / sheet | r10 / r10 | r18 / r22 |
| Spotlight panel | 52 input, single r12 panel | 56 capsule input + 56 round mode buttons + r24 results |

Text styles (macOS values): largeTitle 26, title 22, title2 17, title3 15, headline 13 bold, body 13, callout 12, subheadline 11, footnote 10.

## 5. Window templates

- **A · Settings window** (System Settings layout):
  - `NavigationSplitView` with a glass sidebar whose icons use the accent colour and whose counts are plain grey numbers.
  - Toolbar title, with an optional segmented control in the toolbar centre and grouped icon buttons plus the collapsible search on the right.
  - Content uses `Form(.grouped)` at most 640 wide and centred, or a `Table` for lists such as 词库 and 历史.
- **B · Library window** (Messages layout; used by notes, word book and Ask conversations):
  - The item list lives in the glass sidebar.
  - The detail pane holds a reading column up to 680 wide.
  - The toolbar has grouped icon actions, one prominent "new" button and the collapsible search.
- **C · Floating panel** (Spotlight layout; used by the clipboard, launcher and ⌘K):
  - A capsule input with circular mode buttons and a results panel below.
  - Keys: ↑↓ select, ↵ paste, ⌘↵ paste as plain text, ⌘1–9 quick paste, Esc closes.

## 6. Implementation mapping

| Component | API | Replaces |
| --- | --- | --- |
| Window | `NavigationSplitView`, `.toolbar`, `.navigationTitle` | `StudioSidebar`, `StudioHeroHeader` |
| Search | `.searchable(placement: .toolbar)` / `NSSearchToolbarItem` | `SettingsSearchBox`, `AskLibrarySearchSurface`, the collapsible vocabulary capsule, 8 inline fields |
| Buttons | `.bordered`, `.borderedProminent`, `.borderless`, `.glass`, `.glassProminent`, `.controlSize` | `StudioButton`, `ModelActionStyle`, `AskWorkflowActionStyle`, `AskCapsuleButtonStyle`, `SettingsActionButton` … |
| Select | `Picker(.menu)`, `Menu` | `SettingsMenuPicker`, `SettingsActionMenu`, `CloudServerMenuPicker` |
| Segmented | `Picker(.segmented)` | `StudioSegmentedControl`, `AskSegmentedControl`, `ModelPageTabBar`, `VoiceInputTabBar`, `StudioUnderlineTab` |
| Settings | `Form` + `.formStyle(.grouped)` + `LabeledContent` | `StudioCard`, `StudioSettingRow`, `ModelSurface` |
| Lists | `List`, `Table` | `StudioHistoryRow`, the custom vocabulary list |
| Empty | `ContentUnavailableView` (macOS 14+, plus a look-alike shim for 13) | `AgentEmptyState` and per-page empty views |
| Confirm | `.alert`, `.confirmationDialog` | Custom overlays |
| Tooltip | `.help()` | `StudioTooltipModifier` |
| Glass | `.glassEffect()`, `GlassEffectContainer` (search morph), `NSGlassEffectView`; `NSVisualEffectView` on 13–15 | Hand-drawn highlights in `StudioLiquidGlassBackground` |

## 7. Roll-out

1. **Window skeleton (~1 week).** Move the settings window to `NavigationSplitView` with a toolbar title and toolbar search, and drop the in-content headings. This is the smallest change with the biggest effect on how native the app feels.
2. **Forms (~2 weeks).** Turn each settings page into `Form(.grouped)` with native pop-ups, switches and segmented controls. 词库 and 历史 become `Table`s.
3. **Library windows (template B):** notes, word book, Ask.
4. **Floating panels (template C):** clipboard, launcher, ⌘K.

For every phase, add snapshot renders (macOS version × style × appearance) in the style of `AskConversationVisualTests`. Add SwiftLint rules that forbid literal `.font(.system(size:`, literal `cornerRadius:` and `NSColor(calibrated…)`; use today's counts as the baseline, which may only go down. Then delete `ModelVisualStyle`, `AskWordBookStyle`, `AskNotesStyle`, `AskWorkflowEditorStyle`, `SystemMonitorTheme` and `OnboardingProviderStyle`.

## Appendix: audit (v1)

Counts taken from `Sources/Typeflux`:

- 37 literal font sizes (1,302 uses)
- 23 literal corner radii (494 uses)
- 14 theme/style enums
- 11 search field implementations
- 9 custom `ButtonStyle`s and 24 `*Button` views
- 6 segmented/tab controls
- 41 chip/badge/pill/tag views
- 5 dropdown pickers
