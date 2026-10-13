import SwiftUI

public struct TypefluxToolbar: ToolbarContent {
    private let groups: [TypefluxToolbarGroup]
    private let prominent: TypefluxToolbarAction?
    private let accessories: AnyView?
    private let separatesGroups: Bool

    public init(groups: [TypefluxToolbarGroup] = [], prominent: TypefluxToolbarAction? = nil,
                accessories: AnyView? = nil, separatesGroups: Bool = false) {
        self.groups = groups.filter { !$0.actions.isEmpty }
        self.prominent = prominent
        self.accessories = accessories
        self.separatesGroups = separatesGroups
    }

    public var body: some ToolbarContent {
        ForEach(groups) { group in
            if group.id != groups.first?.id { groupSpacer }
            ToolbarItemGroup(placement: .primaryAction) {
                ForEach(group.actions) { action in TypefluxToolbarButton(action: action) }
            }
        }
        if let accessories {
            if !groups.isEmpty { groupSpacer }
            ToolbarItemGroup(placement: .primaryAction) { accessories }
        }
        if let prominent {
            if !groups.isEmpty || accessories != nil { groupSpacer }
            prominentItem(prominent)
        }
    }

    @ToolbarContentBuilder private var groupSpacer: some ToolbarContent {
        if separatesGroups {
            #if compiler(>=6.2)
                if #available(macOS 26, *) {
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                } else {
                    legacySpacer
                }
            #else
                legacySpacer
            #endif
        }
    }

    private var legacySpacer: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Spacer().frame(width: TypefluxSpacing.small.value(for: .classic))
        }
    }

    @ToolbarContentBuilder private func prominentItem(_ action: TypefluxToolbarAction) -> some ToolbarContent {
        #if compiler(>=6.2)
            if #available(macOS 26, *) {
                // The prominent button supplies its own material and accent, independently of the toolbar capsule.
                newItem(action).sharedBackgroundVisibility(.hidden)
            } else {
                newItem(action)
            }
        #else
            newItem(action)
        #endif
    }

    private func newItem(_ action: TypefluxToolbarAction) -> some ToolbarContent {
        ToolbarItem(id: action.accessibilityIdentifier, placement: .primaryAction) {
            TypefluxToolbarButton(action: action, prominent: true)
        }
    }
}
