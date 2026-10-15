import AppKit
import SwiftUI

/// The usage guide window, built like the notebook and conversation windows: one backdrop
/// for the whole window, the sidebar as an inset glass column (flush in classic), and one
/// page at a time beside it. It follows the interface style and the appearance.
struct HelpWindowView: View {
    @ObservedObject var model: HelpGuideModel
    @Environment(\.interfaceStyle) private var style

    static let defaultSize = CGSize(width: 1120, height: 740)
    static let minimumSize = CGSize(width: 900, height: 600)
    static let sidebarWidth: CGFloat = 248

    var body: some View {
        HStack(spacing: 0) {
            HelpSidebar(model: model)
                .frame(width: Self.sidebarWidth)
                .askSidePanel(edge: .leading, glassFill: AskTheme.glassFill, glassInset: [.leading, .top, .bottom])
            VStack(spacing: 0) {
                header
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                footer
            }
        }
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        .foregroundStyle(StudioTheme.textPrimary)
        // One surface for the whole window, as in the notebook and conversation windows.
        .background(AskWindowBackdrop())
        .ignoresSafeArea(.container, edges: .top)
        .tint(AskTheme.accent)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("help.title"))
    }

    /// The page title in the title bar row, level with the traffic lights.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(model.isSearching ? L("help.search.title") : model.page.title)
                .font(.system(size: 20, weight: .semibold))
            Text(model.isSearching ? L("help.search.count", model.searchResults.count) : model.page.subtitle)
                .font(.system(size: 12.5))
                .foregroundStyle(StudioTheme.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .frame(height: AskMetrics.titleBarRowHeight + 8)
    }

    @ViewBuilder private var content: some View {
        if model.isSearching {
            HelpSearchView(model: model)
        } else {
            switch model.page {
            case .start: HelpStartPage(model: model)
            case .keywords: HelpKeywordsPage(model: model)
            case .shortcuts: HelpShortcutsPage(model: model)
            case .faq: HelpQuestionsPage(model: model)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(footerHint).font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .frame(height: 36)
        .overlay(alignment: .top) { Rectangle().fill(AskTheme.separator).frame(height: 1) }
    }

    private var footerHint: String {
        if model.isSearching {
            return L(model.searchResults.isEmpty ? "help.hint.searchEmpty" : "help.hint.search")
        }
        return L(model.page == .keywords ? "help.hint.keywords" : "help.hint.default")
    }
}

/// The sidebar: the guide's name, its search field, the pages and outside links.
struct HelpSidebar: View {
    @ObservedObject var model: HelpGuideModel
    @Environment(\.interfaceStyle) private var style
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 9) {
                Image(nsImage: HelpAppIcon.image).resizable().interpolation(.high).frame(width: 22, height: 22)
                Text(L("help.title")).font(.system(size: 14, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 14)
            searchField.padding(.bottom, 10)
            ForEach(HelpPage.allCases) { page in
                navRow(page)
            }
            Spacer(minLength: 0)
            supportFooter
        }
        .padding(.horizontal, 10)
        // Below the traffic lights, which sit over the sidebar like in the notebook window.
        .padding(.top, AskMetrics.sidebarTopInset - (style.usesGlass ? AskMetrics.sidebarPanelInset : 0))
        .padding(.bottom, 12)
        .onAppear { searchFocused = true }
        .onChange(of: model.focusRequest) { _ in searchFocused = true }
    }

    static var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version.map { "Typeflux \($0)" } ?? "Typeflux"
    }

    private var supportFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(AskTheme.separator).frame(height: 1)
            HStack(spacing: 8) {
                Button {
                    model.open(HelpGuideModel.documentationURL)
                } label: {
                    footerLinkLabel(L("help.link.website.short"), symbol: "arrow.up.right.square")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("help.link.website"))
                .help(L("help.link.website"))

                Menu {
                    HelpFeedbackOptions(model: model)
                } label: {
                    footerLinkLabel(L("help.link.feedback.short"), symbol: "bubble.left")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(StudioTheme.textSecondary)
                .accessibilityLabel(L("help.link.feedback"))
                .help(L("help.link.feedback"))
            }
            Text(Self.version)
                .font(.system(size: 11.5))
                .foregroundStyle(StudioTheme.textTertiary)
                .padding(.horizontal, 4)
        }
    }

    private var searchField: some View {
        let shape = RoundedRectangle(cornerRadius: style.usesGlass ? 12 : 7, style: .continuous)
        return HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
            TextField(L("help.search.placeholder"), text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .accessibilityLabel(L("help.search.placeholder"))
            if model.isSearching {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(StudioTheme.textTertiary)
                .accessibilityLabel(L("help.search.clear"))
            } else {
                Text("⌘F").font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: style.usesGlass ? 34 : 28)
        .background(shape.fill(style.usesGlass ? AskTheme.hoverFill : AskClassic.card))
        .overlay(shape.strokeBorder(searchFocused ? AskTheme.accent.opacity(0.55) : HelpTheme.blockBorder(style),
                                    lineWidth: searchFocused ? 1.5 : 1))
    }

    private func navRow(_ page: HelpPage) -> some View {
        let selected = !model.isSearching && model.page == page
        let shape = RoundedRectangle(cornerRadius: style.help.rowCorner, style: .continuous)
        return Button { model.show(page) } label: {
            HStack(spacing: 10) {
                Image(systemName: page.symbol).font(.system(size: 13))
                    .foregroundStyle(selected && style.usesGlass ? AskTheme.accent : StudioTheme.textSecondary)
                    .frame(width: 18)
                Text(page.title).font(.system(size: 13.5)).foregroundStyle(StudioTheme.textPrimary)
                Spacer(minLength: 0)
                badge(page)
            }
            .padding(.horizontal, 10)
            .frame(height: style.help.navRowHeight)
            .background(shape.fill(selected ? HelpTheme.selection(style) : .clear))
            .overlay(shape.strokeBorder(selected ? HelpTheme.selectionEdge(style) : .clear))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private func badge(_ page: HelpPage) -> some View {
        switch page {
        case .keywords:
            Text("\(model.catalog.keywords.count)").font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
        case .faq where !model.missingPermissions.isEmpty:
            Text("\(model.missingPermissions.count)").font(.system(size: 12)).foregroundStyle(StudioTheme.warning)
        default:
            EmptyView()
        }
    }

    private func footerLinkLabel(_ title: String, symbol: String) -> some View {
        return HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11))
            Text(title).font(.system(size: 12)).lineLimit(1).minimumScaleFactor(0.85)
        }
        .foregroundStyle(StudioTheme.textSecondary)
        .frame(width: (HelpWindowView.sidebarWidth - 28) / 2, height: 32)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Shared content for the feedback choice menu.
struct HelpFeedbackOptions: View {
    @ObservedObject var model: HelpGuideModel

    var body: some View {
        ForEach(FeedbackDestination.allCases) { destination in
            Button(destination.title) { model.openFeedback(destination) }
        }
    }
}

/// Typeflux's own icon, shipped as a resource so it shows even where the running process has
/// no app icon (tests, previews); the app's icon is the fallback.
enum HelpAppIcon {
    @MainActor static let image: NSImage = {
        for subdirectory in ["Resources", nil] as [String?] {
            if let url = Bundle.appResources.url(forResource: "TypefluxIcon", withExtension: "png",
                                                 subdirectory: subdirectory),
               let image = NSImage(contentsOf: url) {
                return image
            }
        }
        return NSApplication.shared.applicationIconImage
    }()
}
