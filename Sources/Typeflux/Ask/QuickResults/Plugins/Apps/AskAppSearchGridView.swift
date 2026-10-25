import SwiftUI

/// The dedicated application keyword shares the home grid, including filtered results.
struct AskAppSearchGridView: View {
    var output: AskPluginOutput
    var viewportHeight: CGFloat?
    var pending: Bool
    var onSelect: (String) -> Bool
    var onMain: () -> Void
    @State private var pointer = AskSearchPointer(position: NSEvent.mouseLocation)

    static func application(_ item: AskPluginItem) -> AskAppEntry? {
        guard item.valid, let action = item.actions.first(where: { $0.shortcut == .enter }),
              case let .openApplication(app) = action.kind else { return nil }
        return app
    }

    static func height(count: Int, viewportHeight: CGFloat? = nil) -> CGFloat {
        let chrome = 1 + AskPluginResultsView.listPadding * 2
            + AskPluginResultsView.sectionHeight + AskPluginResultsView.rowSpacing
        return max(min(AskApplicationGrid.height(count: count), AskQuickResultsView.maximumHeight),
                   (viewportHeight ?? 0) - chrome)
    }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.vertical) {
                LazyVGrid(columns: AskApplicationGrid.tracks, spacing: AskApplicationGrid.spacing) {
                    ForEach(Array(output.items.enumerated()), id: \.element.id) { index, item in
                        if let app = Self.application(item) {
                            AskApplicationTile(app: app, title: Text(item.title), selected: index == output.selectedItem) {
                                guard !pending, onSelect(item.id) else { return }
                                onMain()
                            }
                            .modifier(AskLauncherNumberBadge(number: pending ? nil : AskLauncherNumberShortcuts.number(at: index)))
                            .id(item.id)
                            .onContinuousHover { phase in
                                if case .active = phase, !pending, pointer.moved(to: NSEvent.mouseLocation) {
                                    _ = onSelect(item.id)
                                }
                            }
                        }
                    }
                }
            }
            .onChange(of: output.selected?.id) { id in
                if let id { reader.scrollTo(id) }
            }
            .onChange(of: output.items.map(\.id)) { _ in
                if let id = output.selected?.id { reader.scrollTo(id, anchor: .top) }
            }
        }
        .frame(height: Self.height(count: output.items.count, viewportHeight: viewportHeight))
        .allowsHitTesting(!pending)
        .onAppear { pointer.position = NSEvent.mouseLocation }
        .accessibilityIdentifier("ask.plugin.applicationGrid")
    }
}
