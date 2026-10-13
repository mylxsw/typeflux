import SwiftUI

public struct TypefluxToolbar: ToolbarContent {
    private let groups: [TypefluxToolbarGroup]
    private let prominent: TypefluxToolbarAction?

    public init(groups: [TypefluxToolbarGroup] = [], prominent: TypefluxToolbarAction? = nil) {
        self.groups = groups.filter { !$0.actions.isEmpty }
        self.prominent = prominent
    }

    public var body: some ToolbarContent {
        ForEach(groups) { group in
            ToolbarItemGroup(placement: .primaryAction) {
                ForEach(group.actions) { action in TypefluxToolbarButton(action: action) }
            }
        }
        if let prominent {
            ToolbarItem(placement: .primaryAction) { TypefluxToolbarButton(action: prominent, prominent: true) }
        }
    }

    #if compiler(>=6.2)
        /// Installed only by a view-level availability check in TypefluxWindow.
        @available(macOS 26, *)
        @ToolbarContentBuilder var glassContents: some ToolbarContent {
            ForEach(groups) { group in
                ToolbarItemGroup(placement: .primaryAction) {
                    ForEach(group.actions) { action in TypefluxToolbarButton(action: action) }
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            if let prominent {
                ToolbarItem(placement: .primaryAction) { TypefluxToolbarButton(action: prominent, prominent: true) }
            }
        }
    #endif
}
