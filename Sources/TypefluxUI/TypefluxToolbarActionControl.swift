import SwiftUI

/// The same native action control is used by toolbar groups and the independently hosted prominent item.
struct TypefluxToolbarActionControl: View {
    let action: TypefluxToolbarAction

    var body: some View {
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
}
