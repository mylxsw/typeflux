import AppKit
import SwiftUI

/// The usage guide: a scrim over the whole screen and a centred panel with a sidebar and
/// one page at a time. Liquid Glass blurs the desktop and draws the panel and sidebar as
/// glass; classic dims the desktop and draws them opaque, the sidebar flush with a hairline.
struct HelpOverlayView: View {
    @ObservedObject var model: HelpOverlayModel
    @Environment(\.interfaceStyle) private var style
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    static let panelSize = CGSize(width: 1120, height: 728)
    static let minimumPanelSize = CGSize(width: 900, height: 600)
    static let sidebarWidth: CGFloat = 248

    /// The panel shrinks with small screens but never below what its two columns need.
    static func panelSize(in screen: CGSize) -> CGSize {
        CGSize(width: max(minimumPanelSize.width, min(panelSize.width, screen.width * 0.9)),
               height: max(minimumPanelSize.height, min(panelSize.height, screen.height * 0.86)))
    }

    var body: some View {
        GeometryReader { proxy in
            let size = Self.panelSize(in: proxy.size)
            let frame = CGRect(x: (proxy.size.width - size.width) / 2, y: (proxy.size.height - size.height) / 2,
                               width: size.width, height: size.height)
            ZStack {
                scrim
                    .contentShape(Rectangle())
                    // A click on the dimmed desktop closes the guide; one on the panel never does.
                    .gesture(SpatialTapGesture().onEnded { tap in
                        if !frame.contains(tap.location) { model.actions.close() }
                    })
                    .accessibilityHidden(true)
                panel.frame(width: size.width, height: size.height)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
    }

    private var material: AskGlassMaterial {
        AskGlassMaterial.resolve(reduceTransparency: reduceTransparency, style: style)
    }

    @ViewBuilder private var scrim: some View {
        if material == .opaque {
            Color.black.opacity(colorScheme == .dark ? 0.55 : 0.28)
        } else {
            ZStack {
                HelpBackdropBlur()
                Color.black.opacity(colorScheme == .dark ? 0.30 : 0.04)
            }
        }
    }

    private var panel: some View {
        let shape = RoundedRectangle(cornerRadius: style.help.panelCorner, style: .continuous)
        return HStack(spacing: 0) {
            HelpSidebar(model: model)
                .frame(width: Self.sidebarWidth)
                .askSidePanel(edge: .leading, glassFill: AskTheme.glassFill, glassInset: [.leading, .top, .bottom])
            VStack(spacing: 0) {
                header
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                footer
            }
        }
        .foregroundStyle(StudioTheme.textPrimary)
        .background(AskGlassBackground(material: material, corner: style.help.panelCorner,
                                       opaqueFill: style.usesGlass ? AskTheme.launcherSurface : AskClassic.canvas))
        .clipShape(shape)
        .overlay(shape.strokeBorder(style.usesGlass ? AskTheme.floatingBorder : AskClassic.launcherBorder,
                                    lineWidth: contrast == .increased ? 1 : 0.5))
        .shadow(color: .black.opacity(0.35), radius: 40, y: 20)
        .contentShape(shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("help.title"))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(model.isSearching ? L("help.search.title") : model.page.title)
                .font(.system(size: 20, weight: .semibold))
            Text(model.isSearching ? L("help.search.count", model.searchResults.count) : model.page.subtitle)
                .font(.system(size: 12.5))
                .foregroundStyle(StudioTheme.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button { model.actions.close() } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(style.controlShape(height: 28))
            }
            .buttonStyle(.plain)
            .foregroundStyle(StudioTheme.textSecondary)
            .help(L("help.close"))
            .accessibilityLabel(L("help.close"))
        }
        .padding(.leading, 28)
        .padding(.trailing, 18)
        .frame(height: 60)
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
    @ObservedObject var model: HelpOverlayModel
    @Environment(\.interfaceStyle) private var style
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 9) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 22, height: 22)
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
            Rectangle().fill(AskTheme.separator).frame(height: 1).padding(.bottom, 6)
            linkRow(L("help.link.website"), symbol: "arrow.up.right.square") {
                model.open(HelpOverlayModel.documentationURL)
            }
            linkRow(L("help.link.feedback"), symbol: "bubble.left") { model.open(HelpOverlayModel.feedbackURL) }
            Text(Self.version).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
                .padding(.horizontal, 10).padding(.top, 6)
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .onAppear { searchFocused = true }
        .onChange(of: model.focusRequest) { _ in searchFocused = true }
    }

    static var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version.map { "Typeflux \($0)" } ?? "Typeflux"
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

    private func linkRow(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 12)).frame(width: 18)
                Text(title).font(.system(size: 12.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(StudioTheme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The desktop behind the guide, blurred, for Liquid Glass.
struct HelpBackdropBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .fullScreenUI
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
