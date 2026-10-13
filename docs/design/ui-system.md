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
| Custom composer menu card / choice row / hover card | r14 / r8 / r10 | r18 / r10 / r14 |
| Popover / sheet | r10 / r10 | r18 / r22 |
| Spotlight panel | 640 wide, 52 input, single r12 panel | 680 wide, 56 capsule input + 56 round mode buttons + r24 results |

Text styles (macOS values): largeTitle 26, title 22, title2 17, title3 15, headline 13 bold, body 13, callout 12, subheadline 11, footnote 10.

The custom Spotlight display input follows template C's system font at 20pt in Classic and 21pt in Liquid Glass,
through `TypefluxSpotlightMetrics.inputFont`. Panel width uses `TypefluxControlWidth.spotlightPanel`;
the clipboard's optional reading preview adds 280pt to either style.

Native menus use the system metrics above. Custom composer menu cards use `TypefluxRadius.menuCard` and `menuRow` at a 6pt row inset; `hoverCard` is smaller than the enclosing menu. These roles keep the floating choice rows concentric without changing native menu or popover geometry.

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

## 7. Implemented library and migration

`Sources/TypefluxUI` owns semantic colors, text styles, spacing, radii, accessibility fallbacks and native control wrappers. The debug app's status menu → **Dev → Component Gallery** opens the runnable controls and navigation gallery. Style and appearance can be switched independently there.

| Surface | Implemented structure |
| --- | --- |
| Settings, model/provider pages, vocabulary and history | `TypefluxWindow`, toolbar search and native grouped forms/lists/tables |
| Notes, word book and Ask libraries | Native split navigation and solid detail panes |
| Launcher and clipboard | `TypefluxSpotlightPanel`, glass input/mode/result navigation; solid reading previews and opaque Classic/accessibility fallbacks |
| Workflow editor | `TypefluxWindow` with toolbar actions, native radio/segmented controls and solid code/form/test panes |
| System monitor | Floating navigation shell with `TypefluxGlassContainer`, solid metrics and native mode/sort segments |
| Onboarding | Grouped `TypefluxForm`, native choices/fields/actions and a navigation footer with accessibility fallback |
| Login | Native library fields and buttons, preserving policy checks, secure entry and browser sign-in |
| About | Grouped form, shared navigation rows and a toolbar title |
| Update alert and feedback | Navigation sheet shell, solid reading/input surfaces and native actions |
| Overview | Grouped metric rows with `.largeTitle` values; recent records reuse the History navigation row and its context actions |

Cloud promotion is a dismissible notice with native actions. Clipboard app-context and pause-state tokens use `TypefluxToken`; media dimensions and duration use a plain metadata label.

Custom navigation containers use the shared independent AppKit glass layer, including the window-edge backdrop in light appearance. The workspace composer's editor stays solid while its footer controls occupy a navigation glass container. Reduce Transparency or Increase Contrast resolves every container to an opaque surface.

The app no longer has the old model, library, workflow, monitor, onboarding or Studio/Ask theme enums. App-owned window dimensions remain in `StudioWindowMetrics`; tool titles and reasoning emphasis live in their own presentation helpers. Frozen `LegacyStudioPalette` / `LegacyAskPalette` values remain inside the library for the floating launcher compatibility surfaces. New UI uses semantic tokens.

## 8. Regression guard and remaining baseline

Run `make lint`, or `scripts/lint_ui.sh --base-ref origin/main` to include the Git comparison. CI runs this check for source/lint changes. The three SwiftLint custom rules reject numeric SwiftUI font sizes (including ternaries), numeric `cornerRadius:` arguments and calibrated/sRGB `NSColor` constructors in app sources outside `Sources/TypefluxUI`.

The migration leaves existing literals in older Ask, clipboard preview and screenshot drawing code. The committed baseline is a limit, not an allowance for new occurrences. The independent Python checker reads the same expressions from `.swiftlint.yml`, counts each file/signature and rejects duplicates, new locations and baseline growth against the PR base. No entire feature folder is exempted.

| Rule | Before GUL-355 (main `77945be8`) | Remaining |
| --- | ---: | ---: |
| Numeric SwiftUI font size | 710 | 397 |
| Numeric corner radius | 397 | 205 |
| Calibrated/sRGB `NSColor` constructor | 46 | 36 |

All seven window families in this wrap-up, the Overview metrics and the workflow editor directory have zero occurrences of these rules. The existing general SwiftLint baseline was also refreshed because prior migrations had left it stale; new UI literal exceptions may only be removed. Lint success does not replace macOS build, interaction tests or visual acceptance.

At acceptance, capture Classic / Liquid Glass × light / dark, plus Reduce Transparency and Increase Contrast. Check the workflow toolbar and sheets, full/compact/mini monitor, every onboarding step, browser and legacy login, About, update notes, feedback validation/upload errors, Overview recent-record navigation and clipboard context tokens. Glass stays on navigation surfaces; the library makes it opaque for either accessibility setting.

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
