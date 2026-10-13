import SwiftUI

/// Plain leading text keeps window titles outside Tahoe's shared control backgrounds.
public struct TypefluxToolbarTitle: ToolbarContent {
    private let title: String
    private let width: CGFloat

    public init(_ title: String, width: CGFloat) {
        self.title = title
        self.width = width
    }

    public var body: some ToolbarContent {
        #if compiler(>=6.2)
            if #available(macOS 26, *) {
                item.sharedBackgroundVisibility(.hidden)
            } else {
                item
            }
        #else
            item
        #endif
    }

    private var item: some ToolbarContent {
        ToolbarItem(id: "typeflux.window.title", placement: .navigation) {
            Text(title).font(.headline).lineLimit(1).truncationMode(.tail)
                .frame(width: width, alignment: .leading)
                .help(title)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("typeflux.window.title")
        }
    }
}
