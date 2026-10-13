import AppKit
import SwiftUI

/// Native borderless pop-up with an inline search hosted inside its menu.
public struct TypefluxSearchablePopup<Selection: Hashable>: NSViewRepresentable {
    private let title: String
    private let selectedTitle: String
    private let searchPrompt: String
    private let options: [(label: String, value: Selection)]
    @Binding private var selection: Selection
    @Environment(\.isEnabled) private var enabled

    public init(_ title: String, selectedTitle: String, searchPrompt: String,
                options: [(label: String, value: Selection)], selection: Binding<Selection>) {
        self.title = title
        self.selectedTitle = selectedTitle
        self.searchPrompt = searchPrompt
        self.options = options
        _selection = selection
    }

    public final class Coordinator: NSObject, NSMenuDelegate, ObservableObject {
        var selection: Binding<Selection>
        var values: [Selection] = []
        var labels: [String] = []
        var installedValue: Selection?
        var installedTitle = ""
        var installedPrompt = ""
        var isTracking = false
        var pendingUpdate: (() -> Void)?
        weak var menu: NSMenu?
        @Published var query = "" {
            didSet {
                let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
                for item in menu?.items ?? [] where values.indices.contains(item.tag) {
                    item.isHidden = !query.isEmpty && !item.title.localizedCaseInsensitiveContains(query)
                }
            }
        }

        init(selection: Binding<Selection>) {
            self.selection = selection
        }

        @objc func choose(_ item: NSMenuItem) {
            guard values.indices.contains(item.tag) else { return }
            selection.wrappedValue = values[item.tag]
        }

        public func menuWillOpen(_: NSMenu) {
            isTracking = true
            query = ""
        }

        public func menuDidClose(_: NSMenu) {
            isTracking = false
            let update = pendingUpdate
            pendingUpdate = nil
            DispatchQueue.main.async { update?() }
        }

        func searchView(prompt: String) -> NSView {
            let view = NSHostingView(rootView: SearchField(coordinator: self, prompt: prompt))
            view.frame = NSRect(x: 0, y: 0, width: 300, height: 38)
            return view
        }
    }

    private struct SearchField: View {
        @ObservedObject var coordinator: Coordinator
        let prompt: String

        var body: some View {
            TypefluxInlineSearch(text: $coordinator.query, prompt: prompt).padding(8).frame(width: 300)
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    public func makeNSView(context _: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.isBordered = false
        button.controlSize = .small
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    public func updateNSView(_ button: NSPopUpButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.selection = $selection
        button.isEnabled = enabled
        button.setAccessibilityLabel(title)
        button.setAccessibilityValue(selectedTitle)
        guard !coordinator.isTracking else {
            coordinator.pendingUpdate = { [weak button, weak coordinator] in
                guard let button, let coordinator else { return }
                installMenu(on: button, coordinator: coordinator)
            }
            return
        }
        installMenu(on: button, coordinator: coordinator)
    }

    private func installMenu(on button: NSPopUpButton, coordinator: Coordinator) {
        let values = options.map(\.value)
        let labels = options.map(\.label)
        if button.menu != nil, coordinator.values == values, coordinator.labels == labels,
           coordinator.installedValue == selection, coordinator.installedTitle == selectedTitle,
           coordinator.installedPrompt == searchPrompt { return }
        coordinator.labels = labels
        coordinator.installedValue = selection
        coordinator.installedTitle = selectedTitle
        coordinator.installedPrompt = searchPrompt
        coordinator.values = values
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = coordinator
        coordinator.menu = menu
        let search = NSMenuItem(title: searchPrompt, action: nil, keyEquivalent: "")
        search.tag = -1
        search.view = coordinator.searchView(prompt: searchPrompt)
        menu.addItem(search)
        for (index, option) in options.enumerated() {
            let item = NSMenuItem(title: option.label, action: #selector(Coordinator.choose(_:)), keyEquivalent: "")
            item.tag = index
            item.target = coordinator
            menu.addItem(item)
        }
        if let index = options.firstIndex(where: { $0.value == selection }) {
            button.menu = menu
            button.selectItem(at: index + 1)
        } else {
            let unavailable = NSMenuItem(title: selectedTitle, action: nil, keyEquivalent: "")
            unavailable.tag = -1
            unavailable.isEnabled = false
            menu.addItem(unavailable)
            button.menu = menu
            button.selectItem(at: menu.items.count - 1)
        }
        // NSPopUpButton supplies a default action to items with no selector when installing a menu.
        // Search and unavailable values are presentation rows, never selection actions.
        for item in menu.items where item.tag < 0 { item.action = nil }
    }

    public static func dismantleNSView(_ button: NSPopUpButton, coordinator: Coordinator) {
        coordinator.pendingUpdate = nil
        button.menu?.cancelTracking()
        button.menu?.delegate = nil
        button.menu = nil
        coordinator.menu = nil
    }
}
