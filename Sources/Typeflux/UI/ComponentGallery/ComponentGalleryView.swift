import SwiftUI

/// Gallery pages. The gallery is a developer tool, so its own copy is English.
enum ComponentGallerySection: String, CaseIterable, Identifiable {
    case foundations, buttons, tabs, menus, inputs, lists, rows, feedback, compositions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .foundations: "Foundations"
        case .buttons: "Buttons"
        case .tabs: "Tabs"
        case .menus: "Menus"
        case .inputs: "Search & Fields"
        case .lists: "Lists & Forms"
        case .rows: "Rows & Panes"
        case .feedback: "Feedback"
        case .compositions: "Compositions"
        }
    }

    var systemImage: String {
        switch self {
        case .foundations: "ruler"
        case .buttons: "capsule"
        case .tabs: "rectangle.split.3x1"
        case .menus: "filemenu.and.selection"
        case .inputs: "magnifyingglass"
        case .lists: "list.bullet.rectangle"
        case .rows: "rectangle.grid.1x2"
        case .feedback: "bubble.left.and.exclamationmark.bubble.right"
        case .compositions: "square.grid.2x2"
        }
    }

    static let paneSections: [TFPaneSection<ComponentGallerySection>] = [
        TFPaneSection("Basics", items: items([.foundations])),
        TFPaneSection("Controls", items: items([.buttons, .tabs, .menus, .inputs])),
        TFPaneSection("Content", items: items([.lists, .rows, .feedback])),
        TFPaneSection("Patterns", items: items([.compositions]))
    ]

    private static func items(_ sections: [ComponentGallerySection]) -> [TFPaneItem<ComponentGallerySection>] {
        sections.map(\.paneItem)
    }

    var paneItem: TFPaneItem<ComponentGallerySection> {
        TFPaneItem(self, title, systemImage: systemImage)
    }
}

/// The component gallery: every shared component (`UI/Components`) with its variants,
/// specifications, states and compositions, previewed in light/dark, glass/classic and
/// regular/compact layouts.
struct ComponentGalleryView: View {
    var onAppearanceChange: (ComponentGalleryAppearance) -> Void = { _ in }
    @State private var section: ComponentGallerySection = .foundations
    @State private var appearance: ComponentGalleryAppearance = .system
    @State private var style: InterfaceStyle = .liquidGlass
    @State private var compact = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            TFDivider(inset: 0)
            HStack(alignment: .top, spacing: 0) {
                TFPaneList(sections: ComponentGallerySection.paneSections, selection: $section)
                    .padding(.top, 16)
                    .padding(.horizontal, 10)
                TFDivider(inset: 0).frame(width: TFMetrics.borderWidth).frame(maxHeight: .infinity)
                ScrollView {
                    ComponentGalleryPage(section: section)
                        .frame(maxWidth: compact ? 600 : 920, alignment: .topLeading)
                        .padding(28)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .tfCompactLayout(compact)
            }
        }
        .background(ModelVisualStyle.canvas)
        .environment(\.interfaceStyle, style)
        .onChange(of: appearance) { onAppearanceChange($0) }
    }

    private var toolbar: some View {
        HStack(spacing: TFMetrics.toolbarSpacing) {
            Text(verbatim: "Component Gallery").font(.system(size: 15, weight: .semibold))
            Text(verbatim: "UI/Components · TF*").font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(TFColors.textTertiary)
            Spacer()
            TFSegmentedControl(options: ComponentGalleryAppearance.allCases.map { TFOption($0, $0.title) },
                               selection: $appearance, identifier: { "gallery.appearance.\($0.rawValue)" })
            TFSegmentedControl(options: [TFOption(InterfaceStyle.liquidGlass, "Glass"), TFOption(.classic, "Classic")],
                               selection: $style, identifier: { "gallery.style.\($0.rawValue)" })
            TFSegmentedControl(options: [TFOption(false, "Regular"), TFOption(true, "Compact")],
                               selection: $compact, identifier: { "gallery.layout.\($0 ? "compact" : "regular")" })
        }
        .padding(.leading, 84)
        .padding(.trailing, 16)
        .frame(height: 52)
    }
}

/// The page shown for a gallery section.
struct ComponentGalleryPage: View {
    var section: ComponentGallerySection

    var body: some View {
        switch section {
        case .foundations: GalleryFoundationsPage()
        case .buttons: GalleryButtonsPage()
        case .tabs: GalleryTabsPage()
        case .menus: GalleryMenusPage()
        case .inputs: GalleryInputsPage()
        case .lists: GalleryListsPage()
        case .rows: GalleryRowsPage()
        case .feedback: GalleryFeedbackPage()
        case .compositions: GalleryCompositionsPage()
        }
    }
}

// MARK: - Gallery building blocks

/// A page title and lead paragraph.
struct GalleryPage<Content: View>: View {
    let title: String
    let summary: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: title).font(.system(size: 24, weight: .bold))
                Text(verbatim: summary).font(.system(size: 13)).foregroundStyle(TFColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
    }
}

/// One specimen: a name, the component it uses, its specification and a live preview.
struct GallerySpecimen<Content: View>: View {
    let title: String
    var component: String?
    var spec: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: title).font(.system(size: 13, weight: .semibold))
                if let component {
                    Text(verbatim: component).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(TFColors.accent)
                }
            }
            if let spec {
                Text(verbatim: spec).font(.system(size: 11.5)).foregroundStyle(TFColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(TFColors.card.opacity(0.6),
                            in: RoundedRectangle(cornerRadius: TFMetrics.cardCornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: TFMetrics.cardCornerRadius, style: .continuous)
                    .strokeBorder(TFColors.border, style: StrokeStyle(lineWidth: 0.5, dash: [3, 3])))
        }
    }
}

/// A small grey caption under or beside a preview.
struct GalleryCaption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(verbatim: text).font(.system(size: 11)).foregroundStyle(TFColors.textTertiary)
    }
}

/// A table-like grid: a header row and labelled rows of previews.
struct GalleryMatrix<Row: Hashable, Column: Hashable, Cell: View>: View {
    let rows: [Row]
    let columns: [Column]
    let rowTitle: (Row) -> String
    let columnTitle: (Column) -> String
    @ViewBuilder let cell: (Row, Column) -> Cell

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
            GridRow {
                Text(verbatim: "")
                ForEach(columns, id: \.self) { column in
                    Text(verbatim: columnTitle(column)).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TFColors.textTertiary)
                }
            }
            ForEach(rows, id: \.self) { row in
                GridRow {
                    Text(verbatim: rowTitle(row)).font(.system(size: 12)).foregroundStyle(TFColors.textSecondary)
                    ForEach(columns, id: \.self) { column in
                        cell(row, column)
                    }
                }
            }
        }
    }
}
