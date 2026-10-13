import AppKit
import SwiftUI

/// A dedicated native toolbar button keeps press actions and enabled state tied to this window's selection.
struct HistorySettingsBackButton: NSViewRepresentable {
    static let toolbarIdentifier = "typeflux.history.back"
    static let accessibilityIdentifier = "typeflux.toolbar.history.back"
    @Binding var selectedID: UUID?

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<UUID?>

        init(selection: Binding<UUID?>) {
            self.selection = selection
            super.init()
        }

        @objc func goBack(_ sender: NSButton) {
            guard sender.isEnabled else { return }
            selection.wrappedValue = nil
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selectedID)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.goBack(_:)))
        button.bezelStyle = .rounded
        button.imagePosition = .imageOnly
        button.setAccessibilityIdentifier(Self.accessibilityIdentifier)
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        let title = L("history.action.back")
        context.coordinator.selection = $selectedID
        button.title = title
        button.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: title)
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.isEnabled = selectedID != nil
    }

    static func dismantleNSView(_ button: NSButton, coordinator _: Coordinator) {
        button.target = nil
        button.action = nil
    }
}
