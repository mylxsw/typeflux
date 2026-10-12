import SwiftUI

/// Settings and library window structure. The caller owns data, localization and actions.
public struct TypefluxWindow<Detail: View>: View {
    @Binding private var selection: String?
    @Environment(\.interfaceStyle) private var style
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.typefluxAccessibilityOptions) private var accessibility
    private let title: String
    private let items: [TypefluxNavigationItem]
    private let groups: [TypefluxToolbarGroup]
    private let prominent: TypefluxToolbarAction?
    private let search: TypefluxSearchState
    private let searchPrompt: String
    private let detail: Detail

    public init(title: String, items: [TypefluxNavigationItem], selection: Binding<String?>,
                search: TypefluxSearchState, searchPrompt: String,
                groups: [TypefluxToolbarGroup] = [], prominent: TypefluxToolbarAction? = nil,
                @ViewBuilder detail: () -> Detail) {
        self.title = title
        self.items = items
        _selection = selection
        self.search = search
        self.searchPrompt = searchPrompt
        self.groups = groups
        self.prominent = prominent
        self.detail = detail()
    }

    public var body: some View {
        NavigationSplitView {
            TypefluxGlassContainer(radius: .sidebar, placement: .windowEdge) {
                List(items, selection: $selection) { item in
                    HStack {
                        Image(systemName: item.systemImage).foregroundStyle(TypefluxColor.accent.color)
                        Text(item.title)
                        Spacer()
                        if let count = item.count {
                            Text(count, format: .number).foregroundStyle(TypefluxColor.secondaryLabel.color)
                                .monospacedDigit()
                        }
                    }
                    .frame(minHeight: TypefluxControlHeight.sidebarRow.value(for: style))
                    .accessibilityElement(children: .combine)
                    .tag(item.id)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
            .padding(TypefluxSpacing.sidebarInset.value(for: style))
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(TypefluxColor.contentBackground.color)
                .navigationTitle(title)
                .toolbar { TypefluxToolbar(groups: groups, prominent: prominent) }
        }
        .typefluxSearchable(state: search, prompt: searchPrompt)
        .toolbarBackground(TypefluxColor.windowBackground.color, for: .windowToolbar)
        .toolbarBackground(style.usesGlass && !reduceTransparency && contrast != .increased
            && !accessibility.reduceTransparency && !accessibility.increasedContrast
            ? .automatic : .visible, for: .windowToolbar)
    }
}
