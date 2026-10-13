import SwiftUI

/// Settings and library window structure. The caller owns data, localization and actions.
public struct TypefluxWindow<Detail: View>: View {
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @Environment(\.interfaceStyle) private var style
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.typefluxAccessibilityOptions) private var accessibility
    private let title: String
    private let sidebar: AnyView
    private let groups: [TypefluxToolbarGroup]
    private let prominent: TypefluxToolbarAction?
    private let center: AnyView?
    @ObservedObject private var searchState: TypefluxSearchState
    private let searchEnabled: Bool
    private let searchPrompt: String
    private let detail: Detail
    private let sidebarVisibility: Binding<NavigationSplitViewVisibility>?

    public init(title: String, items: [TypefluxNavigationItem], selection: Binding<String?>,
                search: TypefluxSearchState, searchPrompt: String,
                groups: [TypefluxToolbarGroup] = [], prominent: TypefluxToolbarAction? = nil,
                @ViewBuilder detail: () -> Detail) {
        self.init(title: title, search: search, searchPrompt: searchPrompt, groups: groups, prominent: prominent) {
            TypefluxWindowNavigationList(items: items, selection: selection)
        } detail: {
            detail()
        }
    }

    /// Custom sidebar content supports app-owned footer actions without changing the window skeleton.
    public init(title: String, search: TypefluxSearchState? = nil, searchPrompt: String = "",
                groups: [TypefluxToolbarGroup] = [], prominent: TypefluxToolbarAction? = nil,
                sidebarVisibility: Binding<NavigationSplitViewVisibility>? = nil,
                center: AnyView? = nil,
                @ViewBuilder sidebar: () -> some View, @ViewBuilder detail: () -> Detail) {
        self.title = title
        self.sidebar = AnyView(sidebar())
        _searchState = ObservedObject(wrappedValue: search ?? TypefluxSearchState())
        searchEnabled = search != nil
        self.searchPrompt = searchPrompt
        self.groups = groups
        self.prominent = prominent
        self.center = center
        self.detail = detail()
        self.sidebarVisibility = sidebarVisibility
    }

    public var body: some View {
        splitView
            .background {
                if searchEnabled {
                    TypefluxSearchToolbarBridge(state: searchState, style: style).frame(width: 0, height: 0)
                }
            }
            .toolbarBackground(TypefluxColor.windowBackground.color, for: .windowToolbar)
            .toolbarBackground(
                style.usesGlass && sidebarMaterial == .system ? .automatic : .visible,
                for: .windowToolbar
            )
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: sidebarVisibility ?? $columnVisibility) {
            sidebar
                .scrollContentBackground(sidebarMaterial == .opaque ? .hidden : .automatic)
                .background {
                    if sidebarMaterial == .opaque {
                        TypefluxColor.windowBackground.color
                    }
                }
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            searchableDetail.frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.typefluxToolbarSearchQuery, searchEnabled ? searchState.query : nil)
                .background(TypefluxColor.contentBackground.color)
                .navigationTitle("")
                .toolbar {
                    titleToolbarItem
                    if let center {
                        ToolbarItem(id: "typeflux.window.segments", placement: .principal) { center }
                    }
                    if searchEnabled {
                        #if compiler(>=6.2)
                            if #available(macOS 26, *) {
                                ToolbarSpacer(.flexible, placement: .primaryAction)
                            } else {
                                ToolbarItem(placement: .primaryAction) { Spacer() }
                            }
                        #else
                            ToolbarItem(placement: .primaryAction) { Spacer() }
                        #endif
                    }
                    TypefluxToolbar(groups: groups, prominent: prominent)
                }
                .background(TypefluxWindowTitleBridge(
                    title: title,
                    actionTitles: Set(groups.flatMap(\.actions).map(\.title))
                )
                .frame(width: 0, height: 0))
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ToolbarContentBuilder private var titleToolbarItem: some ToolbarContent {
        #if compiler(>=6.2)
            if #available(macOS 26, *) {
                titleItem.sharedBackgroundVisibility(.hidden)
            } else {
                titleItem
            }
        #else
            titleItem
        #endif
    }

    private var titleItem: some ToolbarContent {
        ToolbarItem(id: TypefluxWindowTitleBridge.itemIdentifier, placement: .principal) {
            Text(title).font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(TypefluxWindowTitleBridge.itemIdentifier)
        }
    }

    @ViewBuilder private var searchableDetail: some View {
        if searchEnabled {
            detail.typefluxSearchable(state: searchState, prompt: searchPrompt, bindsToolbar: false)
        } else {
            detail
        }
    }

    private var sidebarMaterial: TypefluxSidebarMaterial {
        let supportsGlass = if #available(macOS 26, *) {
            true
        } else {
            false
        }
        return .resolve(style: style, reduceTransparency: reduceTransparency || accessibility.reduceTransparency,
                        increasedContrast: contrast == .increased || accessibility.increasedContrast,
                        supportsLiquidGlass: supportsGlass)
    }
}
