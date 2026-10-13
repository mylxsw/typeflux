import SwiftUI

/// Read appearance from the installed view, including the version-specific toolbar path.
struct TypefluxToolbarButton: View {
    let action: TypefluxToolbarAction
    var prominent = false
    @Environment(\.interfaceStyle) private var style
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.typefluxAccessibilityOptions) private var accessibility

    init(action: TypefluxToolbarAction, prominent: Bool = false) {
        self.action = action
        self.prominent = prominent
    }

    @ViewBuilder var body: some View {
        Group {
            if prominent {
                TypefluxProminentToolbarButton(action: action, style: style, usesGlass: usesGlass)
            } else {
                TypefluxToolbarActionControl(action: action)
            }
        }
        .tint(TypefluxColor.accent.color)
        .frame(width: TypefluxControlWidth.toolbarItem.value(for: style),
               height: TypefluxControlHeight.toolbarItem.value(for: style))
    }

    private var usesGlass: Bool {
        style.usesGlass && !reduceTransparency && contrast != .increased
            && !accessibility.reduceTransparency && !accessibility.increasedContrast
    }
}
