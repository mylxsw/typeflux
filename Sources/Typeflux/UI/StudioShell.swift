import SwiftUI

/// The shared native split view owns navigation, toolbar title and search.
struct StudioShell<Content: View>: View {
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    let currentSection: StudioSection
    let title: String
    let onSelect: (StudioSection) -> Void
    let onAccountAction: () -> Void
    let search: TypefluxSearchState?
    let searchPlaceholder: String
    let accountDefaults: UserDefaults
    var toolbarCenter: AnyView?
    var toolbarGroups: [TypefluxToolbarGroup] = []
    @ViewBuilder let content: (CGSize) -> Content

    var body: some View {
        GeometryReader { windowGeometry in
            let showsSidebar = StudioShellLayout(width: windowGeometry.size.width).sidebarWidth > 0
            TypefluxWindow(title: title, search: search, searchPrompt: searchPlaceholder,
                           groups: toolbarGroups, sidebarVisibility: $sidebarVisibility, center: toolbarCenter) {
                StudioSidebar(currentSection: currentSection, onSelect: onSelect,
                              onAccountAction: onAccountAction, defaults: accountDefaults)
            } detail: {
                GeometryReader { proxy in
                    Group {
                        if [.models, .personas, .agent, .launcher, .settings, .account].contains(currentSection) {
                            pageContent(size: proxy.size)
                        } else {
                            ScrollView { pageContent(size: proxy.size) }
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .environment(\.studioUsesToolbarTitles, true)
            .environment(\.studioWindowWidth, windowGeometry.size.width)
            .onAppear { sidebarVisibility = showsSidebar ? .all : .detailOnly }
            .onChange(of: showsSidebar) { sidebarVisibility = $0 ? .all : .detailOnly }
        }
    }

    private func pageContent(size: CGSize) -> some View {
        let layout = StudioShellLayout(width: size.width, sidebarWidth: 0)
        let inset = layout.horizontalInset
        let contentWidth = layout.contentWidth
        return content(CGSize(width: contentWidth, height: max(0, size.height - 24)))
            .frame(width: contentWidth, alignment: .topLeading)
            .padding(.horizontal, inset)
            .padding(.top, 12)
            .padding(.bottom, [.models, .personas, .agent, .launcher, .settings,
                               .account].contains(currentSection) ? 0 : 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
