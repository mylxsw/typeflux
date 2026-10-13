import AppKit
import SwiftUI

/// Host a native control as custom toolbar content, with a target owned by this window's selection.
struct HistorySettingsBackButton: NSViewRepresentable {
    static let toolbarIdentifier = "typeflux.history.back"
    static let accessibilityIdentifier = "typeflux.toolbar.history.back"
    @Binding var selectedID: UUID?

    final class ToolbarView: NSView {
        let button = NSButton(title: "", target: nil, action: nil)

        override init(frame: NSRect) {
            super.init(frame: frame)
            button.bezelStyle = .rounded
            button.imagePosition = .imageOnly
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: leadingAnchor),
                button.trailingAnchor.constraint(equalTo: trailingAnchor),
                button.topAnchor.constraint(equalTo: topAnchor),
                button.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }

        required init?(coder _: NSCoder) {
            return nil
        }

        override var intrinsicContentSize: NSSize {
            button.intrinsicContentSize
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<UUID?>

        init(selection: Binding<UUID?>) {
            self.selection = selection
            super.init()
        }

        @objc func goBack(_ sender: NSButton) {
            guard sender.isEnabled, selection.wrappedValue != nil else { return }
            selection.wrappedValue = nil
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selectedID)
    }

    func makeNSView(context: Context) -> ToolbarView {
        // Keep the control and its target/action inside the hosted custom view.
        let view = ToolbarView(frame: .zero)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ToolbarView, context: Context) {
        let button = view.button
        let title = L("history.action.back")
        context.coordinator.selection = $selectedID
        button.target = context.coordinator
        button.action = #selector(Coordinator.goBack(_:))
        // An image-only toolbar item must have no visual title; AppKit can otherwise lay
        // the localized title over the chevron inside SwiftUI's toolbar hosting view.
        button.title = ""
        button.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: title)
        // Assigning an image can change the cell's image position after initial construction.
        button.imagePosition = .imageOnly
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.setAccessibilityIdentifier(Self.accessibilityIdentifier)
        button.isEnabled = context.environment.isEnabled && selectedID != nil
        view.invalidateIntrinsicContentSize()
    }

    static func dismantleNSView(_ view: ToolbarView, coordinator _: Coordinator) {
        view.button.isEnabled = false
        view.button.target = nil
        view.button.action = nil
    }
}
