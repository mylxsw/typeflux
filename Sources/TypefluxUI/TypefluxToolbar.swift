import SwiftUI

public struct TypefluxToolbar: ToolbarContent {
    private let groups: [TypefluxToolbarGroup]
    private let prominent: TypefluxToolbarAction?
    private let separatesProminent: Bool

    public init(groups: [TypefluxToolbarGroup] = [], prominent: TypefluxToolbarAction? = nil,
                separatesProminent: Bool = false) {
        self.groups = groups.filter { !$0.actions.isEmpty }
        self.prominent = prominent
        self.separatesProminent = separatesProminent
    }

    public var body: some ToolbarContent {
        ForEach(groups) { group in
            if separatesProminent {
                ToolbarItem(id: group.id, placement: .primaryAction) {
                    HStack(spacing: 0) {
                        ForEach(group.actions) { action in TypefluxToolbarButton(action: action) }
                    }
                    .buttonStyle(.borderless)
                }
            } else {
                ToolbarItemGroup(placement: .primaryAction) {
                    ForEach(group.actions) { action in TypefluxToolbarButton(action: action) }
                }
            }
        }
        if let prominent {
            #if compiler(>=6.2)
                if #available(macOS 26, *), separatesProminent {
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                    prominentItem(prominent)
                } else {
                    prominentItem(prominent)
                }
            #else
                prominentItem(prominent)
            #endif
        }
    }

    private func prominentItem(_ action: TypefluxToolbarAction) -> some ToolbarContent {
        ToolbarItem(id: action.accessibilityIdentifier, placement: .primaryAction) {
            if separatesProminent {
                TypefluxProminentToolbarButton(action: action)
            } else {
                TypefluxToolbarButton(action: action, prominent: true)
            }
        }
    }
}
