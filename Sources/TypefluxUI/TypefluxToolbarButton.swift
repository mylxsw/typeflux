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
            if prominent { prominentButton } else { button }
        }
        .tint(TypefluxColor.accent.color)
        .frame(width: TypefluxControlWidth.toolbarItem.value(for: style),
               height: TypefluxControlHeight.toolbarItem.value(for: style))
    }

    private var button: some View {
        Group {
            if let text = action.sharingText {
                ShareLink(item: text) { label }
            } else {
                Button(role: action.role, action: action.perform) { label }
            }
        }
        .disabled(!action.isEnabled)
        .help(action.title)
        .accessibilityLabel(action.title)
        .accessibilityIdentifier(action.accessibilityIdentifier)
        .keyboardShortcut(action.keyboardShortcut)
    }

    private var label: some View {
        Label(action.title, systemImage: action.systemImage).labelStyle(.iconOnly)
    }

    @ViewBuilder private var prominentButton: some View {
        #if compiler(>=6.2)
            if #available(macOS 26, *), style.usesGlass, !reduceTransparency, contrast != .increased,
               !accessibility.reduceTransparency, !accessibility.increasedContrast {
                button.buttonStyle(.glassProminent)
            } else {
                button.buttonStyle(.borderedProminent)
            }
        #else
            button.buttonStyle(.borderedProminent)
        #endif
    }
}
