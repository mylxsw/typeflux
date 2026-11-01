import AppKit
import SwiftUI

struct OnboardingModelPickerItem: Equatable {
    let id: String
    let title: String
    var detail: String?
}

/// Keep the editorial field intact: macOS Menu styles reduce a custom label to text.
/// The transparent native control supplies menu tracking, keyboard and accessibility.
struct OnboardingModelPicker<Label: View>: View {
    let items: [OnboardingModelPickerItem]
    let selection: String
    let identifier: String
    var enabled = true
    var height: CGFloat = 34
    let onSelect: (String) -> Void
    @ViewBuilder var label: () -> Label
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        ZStack {
            label().accessibilityHidden(true)
            OnboardingModelPickerControl(items: items, selection: selection, identifier: identifier,
                                         enabled: enabled && isEnabled && !items.isEmpty, onSelect: onSelect)
        }
        .frame(height: height)
    }
}

private struct OnboardingModelPickerControl: NSViewRepresentable {
    let items: [OnboardingModelPickerItem]
    let selection: String
    let identifier: String
    let enabled: Bool
    let onSelect: (String) -> Void

    final class Button: NSPopUpButton {
        override var intrinsicContentSize: NSSize { .init(width: NSView.noIntrinsicMetric, height: 34) }
        override func draw(_ dirtyRect: NSRect) {} // SwiftUI draws the field beneath this hit target.
    }

    final class Coordinator: NSObject, NSMenuDelegate {
        var items: [OnboardingModelPickerItem] = []
        var onSelect: (String) -> Void
        var isTracking = false
        func menuWillOpen(_ menu: NSMenu) { isTracking = true }
        func menuDidClose(_ menu: NSMenu) { isTracking = false }
        init(onSelect: @escaping (String) -> Void) { self.onSelect = onSelect }
        @objc func choose(_ sender: NSPopUpButton) {
            guard sender.isEnabled, let id = sender.selectedItem?.representedObject as? String,
                  items.contains(where: { $0.id == id }) else { return }
            onSelect(id)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context: Context) -> Button {
        let button = Button(frame: .zero, pullsDown: false)
        button.isBordered = false
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: Button, context: Context) {
        context.coordinator.onSelect = onSelect
        if context.coordinator.items != items {
            if context.coordinator.isTracking { button.menu?.cancelTracking() }
            button.removeAllItems()
            button.menu?.autoenablesItems = false
            for item in items {
                button.addItem(withTitle: item.title)
                let native = button.lastItem
                native?.representedObject = item.id
                if let detail = item.detail {
                    let title = NSMutableAttributedString(string: item.title,
                                                          attributes: [.font: NSFont.menuFont(ofSize: 0)])
                    title.append(NSAttributedString(string: "  ·  " + detail,
                                                    attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                                                                     .font: NSFont.menuFont(ofSize: 0)]))
                    native?.attributedTitle = title
                }
            }
            button.menu?.delegate = context.coordinator
            context.coordinator.items = items
        }
        if let index = items.firstIndex(where: { $0.id == selection }) {
            button.selectItem(at: index)
        } else {
            button.select(nil)
        }
        button.isEnabled = enabled
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(items.first { $0.id == selection }?.title ?? "")
    }

    static func dismantleNSView(_ button: Button, coordinator: Coordinator) {
        if coordinator.isTracking { button.menu?.cancelTracking() }
        button.isEnabled = false
        button.target = nil
        button.action = nil
        coordinator.onSelect = { _ in }
    }
}
