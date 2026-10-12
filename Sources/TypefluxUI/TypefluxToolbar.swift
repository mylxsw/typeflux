import SwiftUI

public struct TypefluxToolbar: ToolbarContent {
    @Environment(\.interfaceStyle) private var style
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.typefluxAccessibilityOptions) private var accessibility
    private let groups: [TypefluxToolbarGroup]
    private let prominent: TypefluxToolbarAction?

    public init(groups: [TypefluxToolbarGroup] = [], prominent: TypefluxToolbarAction? = nil) {
        self.groups = groups.filter { !$0.actions.isEmpty }
        self.prominent = prominent
    }

    public var body: some ToolbarContent {
        ForEach(groups) { group in
            ToolbarItemGroup(placement: .primaryAction) {
                ForEach(group.actions) { action in button(action) }
            }
            #if compiler(>=6.2)
                if #available(macOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                }
            #endif
        }
        if let prominent {
            ToolbarItem(placement: .primaryAction) { prominentButton(prominent) }
        }
    }

    private func button(_ action: TypefluxToolbarAction) -> some View {
        Button(role: action.role, action: action.perform) {
            Label(action.title, systemImage: action.systemImage).labelStyle(.iconOnly)
        }
        .disabled(!action.isEnabled)
        .help(action.title)
        .accessibilityLabel(action.title)
        .accessibilityIdentifier("typeflux.toolbar." + action.id)
    }

    @ViewBuilder private func prominentButton(_ action: TypefluxToolbarAction) -> some View {
        #if compiler(>=6.2)
            if #available(macOS 26.0, *), style.usesGlass, !reduceTransparency, contrast != .increased,
               !accessibility.reduceTransparency, !accessibility.increasedContrast {
                button(action).buttonStyle(.glassProminent)
            } else {
                button(action).buttonStyle(.borderedProminent)
            }
        #else
            button(action).buttonStyle(.borderedProminent)
        #endif
    }
}
