import SwiftUI

// MARK: - Foundations

struct GalleryFoundationsPage: View {
    private let colors: [(String, Color)] = [
        ("accent", TFColors.accent), ("selection", TFColors.selection), ("control", TFColors.control),
        ("raised", TFColors.raised), ("card", TFColors.card), ("border", TFColors.border),
        ("danger", TFColors.danger), ("success", TFColors.success), ("warning", TFColors.warning),
        ("textPrimary", TFColors.textPrimary), ("textSecondary", TFColors.textSecondary), ("textTertiary", TFColors.textTertiary)
    ]
    private let shapes: [(String, CGFloat?)] = [
        ("Capsule · buttons, segments, menus, search", nil), ("8 · text field", TFMetrics.fieldCornerRadius),
        ("10 · text area", TFMetrics.textAreaCornerRadius), ("12 · card, menu", TFMetrics.cardCornerRadius),
        ("7 · menu item, selected row", TFMetrics.itemCornerRadius), ("18 · sheet, dialog", TFMetrics.sheetCornerRadius)
    ]

    var body: some View {
        GalleryPage(title: "Foundations",
                    summary: "Three control heights, one shape rule and one set of states. Things you click are " +
                        "capsules; things you type into are rounded rectangles; containers nest concentrically.") {
            GallerySpecimen(title: "Control sizes", component: "TFControlSize",
                            spec: "Only 36 / 30 / 24pt. Regular is the default; small is for rows and card " +
                                "headers; large is for onboarding and full-page empty states. Controls in one row " +
                                "share a size (set it once with .tfControlSize).") {
                GalleryMatrix(rows: Array(TFControlSize.allCases.reversed()), columns: ["button", "icon", "segmented", "spec"],
                              rowTitle: { "\($0.rawValue) \(Int($0.height))pt" }, columnTitle: { $0 }) { size, column in
                    switch column {
                    case "button": TFButton(title: "Add", systemImage: "plus", kind: .primary, size: size) {}
                    case "icon": TFButton(title: "More", systemImage: "ellipsis", size: size, iconOnly: true) {}
                    case "segmented":
                        if size == .large {
                            GalleryCaption("not offered")
                        } else {
                            GalleryStaticSegments(size: size)
                        }
                    default:
                        GalleryCaption(Self.spec(size))
                    }
                }
            }
            GallerySpecimen(title: "Shapes", component: "TFMetrics",
                            spec: "Inner radius = outer radius − inset (menu 12 − padding 5 = item 7).") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(shapes, id: \.0) { title, radius in
                        Group {
                            if let radius {
                                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(TFColors.control)
                                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                                        .strokeBorder(TFColors.border, lineWidth: TFMetrics.borderWidth))
                            } else {
                                Capsule().fill(TFColors.control)
                                    .overlay(Capsule().strokeBorder(TFColors.border, lineWidth: TFMetrics.borderWidth))
                            }
                        }
                        .frame(height: 44)
                        .overlay { GalleryCaption(title).multilineTextAlignment(.center).padding(.horizontal, 8) }
                    }
                }
            }
            GallerySpecimen(title: "Colors", component: "TFColors → StudioTheme",
                            spec: "Components only use these roles. Switch Light/Dark in the toolbar to compare.") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach(colors, id: \.0) { name, color in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color).frame(width: 28, height: 28)
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(TFColors.border, lineWidth: TFMetrics.borderWidth))
                            Text(verbatim: name).font(.system(size: 11.5, design: .monospaced))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            GallerySpecimen(title: "States", component: "TFButtonAppearance",
                            spec: "Hover adds a 6% text-color wash, press 11% and scales to 0.97, disabled is 45% " +
                                "opacity, loading swaps the icon for a spinner at the same width. Keyboard focus " +
                                "uses the system focus ring, shaped like the control.") {
                GalleryStateMatrix(kinds: [.secondary])
            }
        }
    }
}

extension GalleryFoundationsPage {
    static func spec(_ size: TFControlSize) -> String {
        let weight = size == .large ? "semibold" : "medium"
        return "\(Int(size.fontSize))pt \(weight) · padding \(Int(size.horizontalPadding)) · icon \(Int(size.iconSize))"
    }
}

/// A non-interactive segmented control for size comparisons.
private struct GalleryStaticSegments: View {
    var size: TFControlSize
    @State private var value = "all"

    var body: some View {
        TFSegmentedControl(options: [TFOption("all", "All"), TFOption("on", "Enabled")], selection: $value, size: size)
    }
}

/// Buttons drawn in fixed interaction states.
struct GalleryStateMatrix: View {
    var kinds: [TFButtonKind]
    private let states = ["Default", "Hover", "Pressed", "Disabled", "Loading"]

    var body: some View {
        GalleryMatrix(rows: kinds, columns: states, rowTitle: { $0.rawValue }, columnTitle: { $0 }) { kind, state in
            switch state {
            case "Hover", "Pressed":
                TFButtonChrome(kind: kind, destructive: false, size: .regular, iconOnly: false,
                               isPressed: state == "Pressed", hoverOverride: true) {
                    Label("Save", systemImage: "checkmark").labelStyle(.titleAndIcon)
                }
            case "Disabled":
                TFButton(title: "Save", systemImage: "checkmark", kind: kind) {}.disabled(true)
            case "Loading":
                TFButton(title: "Save", systemImage: "checkmark", kind: kind, isLoading: true) {}
            default:
                TFButton(title: "Save", systemImage: "checkmark", kind: kind) {}
            }
        }
    }
}

// MARK: - Buttons

struct GalleryButtonsPage: View {
    @State private var loading = false
    /// Large, regular and small, then an icon-only column.
    static let sizeColumns: [TFControlSize?] = TFControlSize.allCases.reversed().map { Optional($0) } + [nil]

    static func columnTitle(_ size: TFControlSize?) -> String {
        size.map { "\($0.rawValue) \(Int($0.height))" } ?? "icon only"
    }

    var body: some View {
        GalleryPage(title: "Buttons",
                    summary: "Five styles plus a destructive modifier. A region has at most one primary button and " +
                        "it goes last. Destructive actions ask first; only the confirmation dialog fills red.") {
            GallerySpecimen(title: "Styles × sizes", component: "TFButton(kind:size:)") {
                GalleryMatrix(rows: [TFButtonKind.primary, .secondary, .plain, .link], columns: Self.sizeColumns,
                              rowTitle: { $0.rawValue }, columnTitle: Self.columnTitle) { kind, size in
                    if let size {
                        TFButton(title: kind == .link ? "Learn More" : "Add Keyword", systemImage: kind == .link ? nil : "plus",
                                 kind: kind, size: size) {}
                    } else if kind == .link {
                        GalleryCaption("—")
                    } else {
                        TFButton(title: "Refresh", systemImage: "arrow.clockwise", kind: kind, iconOnly: true) {}
                    }
                }
            }
            GallerySpecimen(title: "Destructive", component: "TFButton(destructive: true)",
                            spec: "Secondary or plain with red text as the entry point; red fill (primary + " +
                                "destructive) only inside the confirmation dialog.") {
                HStack(spacing: 10) {
                    TFButton(title: "Reset…", destructive: true) {}
                    TFButton(title: "Delete", systemImage: "trash", kind: .plain, destructive: true) {}
                    TFButton(title: "Delete", systemImage: "trash", destructive: true, iconOnly: true) {}
                    TFButton(title: "Delete", kind: .primary, destructive: true) {}
                    GalleryCaption("← dialog only")
                }
            }
            GallerySpecimen(title: "States", component: "TFButtonChrome",
                            spec: "Hover and pressed are forced here for comparison.") {
                GalleryStateMatrix(kinds: [.primary, .secondary, .plain])
            }
            GallerySpecimen(title: "Loading keeps the width", component: "TFButton(isLoading:)") {
                HStack(spacing: 10) {
                    TFButton(title: "Check for Updates", systemImage: "arrow.clockwise", isLoading: loading) {}
                    TFButton(title: "Test Connection", kind: .primary, isLoading: loading) {}
                    TFButton(title: "Test", size: .small, isLoading: loading) {}
                    TFSwitch(title: "Loading", isOn: $loading)
                    GalleryCaption("toggle loading")
                }
            }
            GallerySpecimen(title: "Glass", component: "TFButton(kind: .glass)",
                            spec: "Only on layers floating over content (bottom action bars, floating toolbars). " +
                                "Reduce Transparency and the Classic style turn it opaque.") {
                ZStack {
                    LinearGradient(colors: [.blue, .purple, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .frame(height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    HStack(spacing: 6) {
                        TFButton(title: "Copy", systemImage: "doc.on.doc", kind: .glass) {}
                        TFButton(title: "Ask AI", systemImage: "sparkles", kind: .glass) {}
                        TFButton(title: "More", systemImage: "ellipsis", kind: .glass, iconOnly: true) {}
                    }
                }
            }
            GallerySpecimen(title: "Rules", spec: nil) {
                GalleryRules(rules: [
                    "Order left to right: secondary → primary. Sheets: [Cancel] [Primary], Return = primary, Esc = " +
                        "cancel.",
                    "Labels start with a verb and stay short (\"Add Keyword\", \"Open Folder\").",
                    "Icon-only buttons are circles, only for well-known actions, and always carry a tooltip.",
                    "Text buttons are at least 64pt wide at regular and large sizes."
                ])
            }
        }
    }
}

/// A bulleted list of usage rules.
struct GalleryRules: View {
    let rules: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rules, id: \.self) { rule in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "•").foregroundStyle(TFColors.textTertiary)
                    Text(verbatim: rule).font(.system(size: 12.5)).foregroundStyle(TFColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Tabs

struct GalleryTabsPage: View {
    @State private var page = "vocabulary"
    @State private var filter = "on"
    @State private var appearance = "auto"
    @State private var view = "list"
    @State private var pane = "skills"

    private let panes: [TFPaneSection<String>] = [
        TFPaneSection("Capabilities", items: [TFPaneItem("web", "Web Search", systemImage: "globe", status: .active),
                                              TFPaneItem("image", "Image Generation", systemImage: "photo", status: .inactive)]),
        TFPaneSection("Extensions", items: [TFPaneItem("skills", "Skills", systemImage: "sparkles"),
                                            TFPaneItem("mcp", "MCP Servers", systemImage: "server.rack")]),
        TFPaneSection("Personal", items: [TFPaneItem("memory", "Memory", systemImage: "note.text")])
    ]

    var body: some View {
        GalleryPage(title: "Tabs",
                    summary: "Three levels, chosen by what changes when you switch: the whole page (page tabs), " +
                        "the same content's view or filter (segmented control), or one of many grouped sections " +
                        "(pane list).") {
            GallerySpecimen(title: "① Page tabs", component: "TFTabBar",
                            spec: "2–6 tabs under the page title. 13pt, selected semibold with a 2pt accent line " +
                                "that slides; counts 11pt tertiary; 22pt apart; 32pt high. ←/→ switch when " +
                                "focused.") {
                TFTabBar(options: [TFOption("overview", "Overview"), TFOption("vocabulary", "Vocabulary", count: 129),
                                   TFOption("history", "History"), TFOption("personas", "Personas", count: 9)],
                         selection: $page)
                GalleryCaption("selection: \(page)")
            }
            GallerySpecimen(title: "② Segmented control", component: "TFSegmentedControl",
                            spec: "Up to 4 options in a toolbar, 5 in a form. Capsule track, raised thumb that " +
                                "slides. As a filter, each segment shows its count.") {
                TFSegmentedControl(options: [TFOption("all", "All", count: 7), TFOption("on", "Enabled", count: 6),
                                             TFOption("off", "Disabled", count: 1)], selection: $filter)
                GalleryCaption("regular 30 · filter with counts")
                TFSegmentedControl(options: [TFOption("light", "Light"), TFOption("dark", "Dark"), TFOption("auto", "Auto")],
                                   selection: $appearance, fillsWidth: true)
                    .frame(width: TFMetrics.formControlWidth)
                GalleryCaption("regular 30 · equal widths filling a 220pt form column")
                TFSegmentedControl(options: [.icon("list", systemImage: "list.bullet", help: "List"),
                                             .icon("grid", systemImage: "square.grid.2x2", help: "Grid")],
                                   selection: $view, size: .small)
                GalleryCaption("small 24 · icon-only with tooltips")
            }
            GallerySpecimen(title: "③ Pane list", component: "TFPaneList · TFPanePicker · TFPaneLayout",
                            spec: "For more than six or grouped sections. 200pt column; rows 30pt, radius 7, 16pt " +
                                "symbol; selected uses the selection fill. Below 720pt of content (try Compact) " +
                                "TFPaneLayout folds it into a picker.") {
                TFPaneLayout(sections: panes, selection: $pane) {
                    TFCard {
                        Text(verbatim: "Content for “\(pane)”").font(.system(size: 13)).foregroundStyle(TFColors.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 160)
                    }
                }
                .frame(height: 270)
            }
        }
    }
}
