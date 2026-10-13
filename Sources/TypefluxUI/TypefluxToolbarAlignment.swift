import AppKit

/// SwiftUI may insert another flexible space before native searchable content.
/// App-owned trailing actions and search must share the space after the title.
@MainActor
enum TypefluxToolbarAlignment {
    static func alignTrailingItems(in toolbar: NSToolbar, identifiers: Set<String>) {
        guard !identifiers.isEmpty else { return }
        func matches(_ identifier: NSToolbarItem.Identifier) -> Bool {
            identifiers.contains { identifier.rawValue.contains($0) }
        }
        guard let first = toolbar.items.firstIndex(where: { matches($0.itemIdentifier) }) else { return }
        let centered = toolbar.centeredItemIdentifiers.filter { !matches($0) }
        if centered != toolbar.centeredItemIdentifiers { toolbar.centeredItemIdentifiers = centered }
        let flexible = toolbar.items.indices.filter { toolbar.items[$0].itemIdentifier == .flexibleSpace }
        guard flexible != [first - 1] else { return }
        for index in flexible.reversed() { toolbar.removeItem(at: index) }
        guard let insertion = toolbar.items.firstIndex(where: { matches($0.itemIdentifier) }) else { return }
        toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: insertion)
    }
}
