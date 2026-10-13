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
            ToolbarItem(id: prominent.accessibilityIdentifier, placement: .primaryAction) {
                TypefluxToolbarButton(action: prominent, prominent: true)
            }
        }
    }
}
