import SwiftUI

/// The same native action control is used by toolbar groups and the independently hosted prominent item.
struct TypefluxToolbarActionControl: View {
    let action: TypefluxToolbarAction

    var body: some View {
        Group {
            if !action.menuActions.isEmpty {
                menu
            } else if let text = action.sharingText {
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

    private var menu: some View {
        Menu {
            ForEach(action.menuActions) { item in
                Button(item.title, role: item.role, action: item.perform)
                    .disabled(!item.isEnabled)
                    .accessibilityIdentifier(item.accessibilityIdentifier)
                    .keyboardShortcut(item.keyboardShortcut)
            }
        } label: { label }
            .menuIndicator(.hidden)
    }

    private var label: some View {
        Label(action.title, systemImage: action.systemImage).labelStyle(.iconOnly)
    }
}
