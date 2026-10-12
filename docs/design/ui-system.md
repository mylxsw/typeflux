# Typeflux UI System v1

The interactive board is `docs/design/ui-system.html`. Open it in a browser and use the switches in the top right for **传统 / Liquid Glass** and **浅色 / 深色**. This file is the written spec. When it disagrees with the board, this file wins.

## 1. Why

The audit in GUL-342 found that the client has several separate design languages:

| Measure (from `Sources/Typeflux`) | Today | Target |
| --- | --- | --- |
| Distinct literal font sizes (`.system(size: n)`, 1,302 uses) | 37 | 8 text styles |
| Distinct literal corner radii (`cornerRadius: n`, 494 uses) | 23 | 6 radius tokens |
| Theme / style / metrics enums | 14 | 1 token layer |
| Search field implementations | 11 | 2 (`.field`, `.palette`) |
| Button styles + button views | 9 + 24 | `TFButton`, `TFIconButton` |
| Segmented / tab controls | 6 | `TFSegmented`, `TFTabs` |
| Chip / badge / pill / tag views | 41 | `TFBadge`, `TFChip`, `TFKeyHint` |
| Dropdown pickers | 5 | `TFSelect`, `TFMenuButton` |

The full per-page findings are in tab ① of the board.

## 2. Principles

1. **One intent, one component.** Search, choose, switch and confirm each map to exactly one component. Pages do not restyle them.
2. **Geometry is shared. Shape and material follow the style.** Control heights, spacing and type are the same in Classic and Liquid Glass, so switching style never reflows a page. Only corner radii, surfaces (opaque vs. translucent with blur and rim light) and shadows change.
3. **Components never check `usesGlass`.** They read tokens. The token layer resolves `(InterfaceStyle, ColorScheme, reduceTransparency, increasedContrast)`. With Reduce Transparency or Increase Contrast on, Glass falls back to the Classic values.
4. **Content first.** Hierarchy comes from weight, spacing and grouping. Each region has at most one primary button. No gradients and no coloured shadows.
5. **Native behaviour.** ⌘F focuses search, and Esc clears it (pressing Esc again blurs). In menus, the check mark sits on the left and ↑ ↓ ↵ Esc all work.

## 3. Tokens

### Type (SF Pro / PingFang)

| Token | Size / line | Weight | Use |
| --- | --- | --- | --- |
| display | 26 / 32 | semibold | metrics, hero numbers |
| title1 | 22 / 28 | semibold | page title |
| title2 | 17 / 22 | semibold | sheet title, list-column title |
| headline | 13 / 18 | semibold | row title, card title |
| body | 13 / 18 | regular | body text, all control labels |
| callout | 12 / 16 | regular | secondary text, help |
| caption | 11 / 14 | medium | section labels, badges, timestamps |
| mono | 12 / 16 | SF Mono | model IDs, URLs, shortcuts |

### Spacing (4pt grid)

The scale is 4, 8, 12, 16, 20, 24, 32. Use 8 inside controls, 16 for row and card padding, 12 between cards, 24 between groups, and 28/32 for page padding. The 10/14/18/22 steps go away.

### Control heights (identical in both styles)

sm **24** (table rows, dense toolbars) · md **30** (default for buttons, fields, selects and segmented controls) · lg **36** (onboarding, login and empty-state CTAs only) · list row **40** single-line / **56** two-line · palette input **52**.

### Radii

| Token | Classic | Liquid Glass |
| --- | --- | --- |
| control (button, search, select, segmented) | 6 | capsule |
| text field | 6 | 10 |
| row / nav item | 6 | 10 |
| card | 10 | 16 |
| menu / popover | 8 | 14 |
| side panel | 0, flush with a hairline | 20, floating inset |
| window / sheet | 10 / 12 | 24 / 22 |

Nested shapes are concentric: inner radius = outer radius − inset.

### Colour (semantic only)

`bg.window`, `bg.sidebar`, `surface.card`, `surface.raised`, `surface.control`, `surface.field`, `surface.menu`, `surface.track`, `border`, `border.strong`, `divider`, `text.primary/secondary/tertiary/disabled`, `accent`, `accent.hover`, `accent.soft`, `accent.text`, `success/warning/danger/private` (each with a `.soft` variant), and `hover/press/selected` washes. The board's tab ② shows the exact values for all four style × appearance combinations. The accent stays `#2563EB` (light) and `#178CFF` (dark), as today.

### Elevation

The levels are 0 canvas · 1 card (Classic: 1px border; Glass: rim light plus soft shadow) · 2 menu/popover/toast · 3 window/sheet.

## 4. Components

| Component | Replaces | Rules |
| --- | --- | --- |
| `TFButton(role: .primary/.secondary/.plain/.destructive, size:)` | `StudioButton`, `SettingsActionButton`, `ModelActionStyle`, `AskWorkflowActionStyle`, `AskCapsuleButtonStyle`, `.borderedProminent` | At most one primary per region. Secondary actions go on the left and the primary sits rightmost. Sheet footers are right-aligned. |
| `TFIconButton` | `StudioIconButton`, `AskIconGhostButton`, `AgentSettingsIconButton`, `AskHeaderIconButton` … | Square, same heights as buttons. Must have a tooltip and an accessibility label. |
| Label rule | — | Window and list toolbars use icon-only buttons. Page headers use text (an icon is optional). Card and sheet footers use text only. Table rows use sm icon buttons that appear on row hover. Never mix icon-only and labelled buttons in one toolbar. |
| `TFSearchField(.field)` | `SettingsSearchBox`, `AskLibrarySearchSurface`, the collapsing vocabulary search, persona/workflow/gallery inline fields | Always visible (never expand-on-click). md 30. Shows the ⌘F hint when empty and a clear button when filled. Filters live with a 150ms debounce. Placeholder is “搜索{对象}” with no ellipsis. |
| `TFSearchField(.palette)` | Launcher, ⌘K, clipboard headers | 52 high, 17pt, no fill, divider below. Only in floating panels. ↑ ↓ ↵ Esc work, and a 32pt hint bar sits at the bottom. |
| `TFSelect` | `Picker(.menu)`, `SettingsMenuPicker`, `CloudServerMenuPicker`, model chooser popover | Shows the current value with ⇅. Width follows the form column or is 180/240. Adds an inline search above 12 options. |
| `TFMenuButton` | `SettingsActionMenu`, “···” menus | Shows the action name with ⌄, or a “···” icon. Menu rows are 26 high, with group captions and separators. Destructive items go last, in red. |
| `TFSegmented` | `StudioSegmentedControl`, `AskSegmentedControl`, `Picker(.segmented)` | Switches a view or filter within a region. ≤5 items. |
| `TFTabs` | `ModelPageTabBar`, `VoiceInputTabBar`, `StudioUnderlineTab` | Page-level sections directly under the page header. 2pt accent underline. |
| `TFToggle` / `TFCheckbox` / `TFRadio` | — | Settings use a Toggle at the row's trailing edge. Multi-select uses Checkbox. Radio is only for 2–4 options that need visible descriptions; otherwise use `TFSelect`. |
| `TFTextField` / `TFTextArea` / `TFForm` | `ModelFieldStyle`, ad-hoc fields | The label column is 120 and right-aligned. Below 480 width, labels move above the field. Focus shows an accent border plus a 3px ring. Errors show a danger border and the reason below the field. |
| `TFCard(.content/.grouped/.interactive)` | `StudioCard`, `ModelSurface`, `AskContentCardSurface`, private cards | Padding is 16. In grouped cards, dividers start at the content edge. Interactive cards deepen their border on hover, and selection adds an accent outline. |
| `TFListRow` | `StudioHistoryRow`, `StudioSettingRow`, `ModelProviderRow`, Ask history row | 28pt leading tile, body title, callout subtitle, trailing accessory. 40 / 56 high. |
| `TFSection` | `ModelSectionLabel`, `StudioSectionTitle` | Caption semibold tertiary, optional count, optional trailing plain button. |
| `TFBadge` | `StudioPill`, `StudioTag`, `AgentStatusBadge`, `AskStatusBadge`, `ModelUsageBadge` … | 18 high capsule, 11pt semibold. Tones are neutral, accent, success, warning, danger and private. For status, prefer a dot plus label. |
| `TFChip` | `AskChip`, `AskKeywordChip`, `ClipboardAppFilterChip`, `AgentFactChip` … | 24 high capsule. Selected state uses `accent.soft`. Optional count or remove ✕. |
| `TFKeyHint` | `AskKeyHint`, `KeywordHotkeyBadge` | 18 high, 10.5pt. Used everywhere a shortcut is shown. |
| `TFBanner` | promo cards, inline notices | Info, success, warning and danger, with an optional trailing action. |
| `TFToast` | — | Short result feedback, 2.5s, bottom centre. |
| `TFEmptyState` | `AgentEmptyState`, per-page empty views | Icon 26 tertiary, headline, callout, optional sm button. Search misses say “没有找到 “xxx”” and offer an action. |
| `TFSheet` | ad-hoc sheets | 440 / 560 / 720 wide. title2 header with a close button. 20pt body. Right-aligned footer. |

## 5. Layout templates

- **A · Settings page** (all settings sections, account). Sidebar is 220 wide with 32/34 rows. Page padding is 28 top / 32 sides. The page header has a title1 title, a callout subtitle and right-aligned actions. Optional `TFTabs` come next, then a toolbar (search → filters → flexible space → icon actions, 8 apart), then sections with grouped cards. Content max width is 760 for forms and 1160 for lists.
- **B · Library (list + detail)** (notes, word book, Ask conversations, personas, history). The list column is 280 wide: title2 header plus a new-item icon button, `TFSearchField(.field)`, optional `TFSegmented`, then two-line rows. The detail side has a 48pt icon-only toolbar and reading width ≤ 720.
- **C · Floating panel** (launcher, ⌘K, clipboard, command palette). Palette input 52 → optional chip filters → 40pt result rows (the selected row uses solid accent) → 32pt hint bar.
- **D · Sheet** as specified in `TFSheet` above.

## 6. Roll-out

1. **Tokens (≈1 week).** Add `UI/DesignSystem/TFTokens.swift` (`TFColor`, `TFFont`, `TFSpace`, `TFRadius`, `TFHeight`, `TFElevation`). Have `StudioTheme`, `AskTheme`, `ModelVisualStyle` and `AskStyleMetrics` forward to it as deprecated aliases. Rendering does not change yet. Unit-test the resolution table (2 styles × 2 appearances × reduce transparency).
2. **Components (≈2 weeks).** Build the components in §4 under `UI/DesignSystem/`. For each one, add snapshot renders in the style of `AskConversationVisualTests` for all 4 combinations, plus hover, pressed, disabled and focus states.
3. **Page migration**, one page per PR, each with before/after captures in all 4 combinations:
   - 2a: settings pages (vocabulary, personas, models, agent, launcher, history)
   - 2b: floating panels
   - 2c: library windows
   - 2d: workflow editor, system monitor, onboarding, update alert, clipboard snippet editor
4. **Guard against regressions.** Add SwiftLint custom rules that forbid literal `.font(.system(size:`, literal `cornerRadius:` and `NSColor(calibrated…)` outside `UI/DesignSystem/`. Use today's counts as the baseline; they may only go down. Then delete the private style enums (`ModelVisualStyle`, `AskWordBookStyle`, `AskNotesStyle`, `AskWorkflowEditorStyle`, `SystemMonitorTheme`, `OnboardingProviderStyle`).
