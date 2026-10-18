import SwiftUI

@MainActor enum AskAppContinueItem: Equatable {
    case tab(AskBrowserSearchEntry)
    case file(AskAppContinueHistory.Record)

    var id: String {
        switch self {
        case let .tab(tab): "tab:" + tab.id
        case let .file(file): "file:" + file.id
        }
    }

    var title: String {
        switch self {
        case let .tab(tab): tab.title.isEmpty ? tab.url : tab.title
        case let .file(file): file.url.lastPathComponent
        }
    }

    var detail: String {
        switch self {
        case let .tab(tab): tab.url
        case let .file(file): file.url.deletingLastPathComponent().path
        }
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return title.localizedStandardContains(query) || detail.localizedStandardContains(query)
    }
}

struct AskAppContinueView: View {
    var app: AskAppEntry
    var items: [AskAppContinueItem]
    var selected: Int
    var loading: Bool
    var permissionIssue: Bool
    var query: String
    var emptyMessage: String
    var viewportHeight: CGFloat
    var onBack: () -> Void
    var onOpenApp: () -> Void
    var onOpenItem: (AskAppContinueItem) -> Void
    var onSelect: (Int) -> Void

    static let rowHeight: CGFloat = 44
    static let headerHeight: CGFloat = 48

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(AskTheme.launcherSeparator).frame(height: 1).padding(.horizontal, 12)
            HStack(spacing: 9) {
                Button(action: onBack) {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text(L("ask.appContinue.back"))
                            .font(.system(size: 11.5))
                    }
                    .foregroundStyle(StudioTheme.textSecondary)
                    .frame(height: 26)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("ask.appContinue.back"))
                Rectangle().fill(AskTheme.launcherSeparator).frame(width: 1, height: 16)
                AskFileIconView(url: app.url, thumbnail: false).frame(width: 24, height: 24)
                Text(app.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(L("ask.appContinue.title")).font(.system(size: 11.5))
                    .foregroundStyle(StudioTheme.textSecondary)
                Spacer()
                Text("Esc / ⌫").font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(StudioTheme.textTertiary)
            }
            .padding(.horizontal, 13)
            .frame(height: Self.headerHeight)
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(spacing: 2) {
                        row(index: 0, title: L("ask.appContinue.openApp"), detail: "↩", item: nil, action: onOpenApp)
                        if loading { status(L("ask.appContinue.loading")) }
                        if items.contains(where: { if case .tab = $0 { true } else { false } }) {
                            section(L("ask.appContinue.tabs"))
                            itemRows { if case .tab = $0 { true } else { false } }
                        }
                        if items.contains(where: { if case .file = $0 { true } else { false } }) {
                            section(L("ask.appContinue.files"))
                            itemRows { if case .file = $0 { true } else { false } }
                        }
                        if !loading && items.isEmpty {
                            status(query.isEmpty ? emptyMessage : L("ask.appContinue.noMatch"))
                        }
                        if permissionIssue && !items.isEmpty { status(L("ask.appContinue.permission")) }
                    }
                    .padding(6)
                }
                .onChange(of: selected) { index in
                    withAnimation(.easeOut(duration: 0.12)) { scroll.scrollTo(index, anchor: .center) }
                }
            }
        }
        .frame(height: viewportHeight, alignment: .top)
        .accessibilityIdentifier("ask.appContinue")
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold))
            .foregroundStyle(StudioTheme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 3)
    }

    private func itemRows(_ include: (AskAppContinueItem) -> Bool) -> some View {
        ForEach(items.indices.filter { include(items[$0]) }, id: \.self) { index in
            let item = items[index]
            row(index: index + 1, title: item.title, detail: item.detail,
                item: item, action: { onOpenItem(item) })
        }
    }

    private func row(index: Int, title: String, detail: String, item: AskAppContinueItem?,
                     action: @escaping () -> Void) -> some View {
        Button { onSelect(index); action() } label: {
            HStack(spacing: 10) {
                icon(for: item).frame(width: 26, height: 26)
                Text(title).font(.system(size: 13.5)).foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1).layoutPriority(1)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .frame(height: Self.rowHeight)
            .background(index == selected ? AskTheme.launcherSelection : .clear,
                        in: RoundedRectangle(cornerRadius: 13))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(index == selected ? .isSelected : [])
        .id(index)
    }

    @ViewBuilder private func icon(for item: AskAppContinueItem?) -> some View {
        switch item {
        case let .tab(tab):
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 13)).foregroundStyle(AskTheme.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AskTheme.launcherTile, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
                .help(tab.browser.title)
        case let .file(file):
            AskFileIconView(url: file.url, thumbnail: false).accessibilityHidden(true)
        case nil:
            AskFileIconView(url: app.url, thumbnail: false).accessibilityHidden(true)
        }
    }

    private func status(_ title: String) -> some View {
        Text(title).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).frame(height: 38)
    }
}
