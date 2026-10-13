import AppKit
import SwiftUI

/// Use AppKit's prominent toolbar material, or an accent push bezel for the classic fallback.
/// The native button owns target/action, accessibility and its key equivalent.
struct TypefluxProminentToolbarButton: NSViewRepresentable {
    let action: TypefluxToolbarAction
    @Environment(\.interfaceStyle) private var style
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.typefluxAccessibilityOptions) private var accessibility

    private var usesGlass: Bool {
        #if compiler(>=6.2)
            if #available(macOS 26, *) {
                return style.usesGlass && !reduceTransparency && contrast != .increased
                    && !accessibility.reduceTransparency && !accessibility.increasedContrast
            }
        #endif
        return false
    }

    final class ToolbarView: NSView {
        let button = NSButton(title: "", target: nil, action: nil)
        var itemIdentifier = ""
        var usesGlass = false
        var itemSize = NSSize.zero
        private var synchronizing = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            button.setButtonType(.momentaryPushIn)
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

        required init?(coder _: NSCoder) { return nil }
        override var intrinsicContentSize: NSSize { itemSize }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            schedule()
        }

        override func layout() {
            super.layout()
            synchronizeToolbarItem()
        }

        func schedule() { DispatchQueue.main.async { [weak self] in self?.synchronizeToolbarItem() } }

        private func synchronizeToolbarItem() {
            guard !synchronizing, !itemIdentifier.isEmpty, let item = window?.toolbar?.items.first(where: {
                $0.itemIdentifier.rawValue.contains(itemIdentifier)
            }), let root = item.view, root === self || isDescendant(of: root) else { return }
            synchronizing = true
            defer { synchronizing = false }
            // SwiftUI's toolbar adapter defaults custom items to plain. Configure its actual material.
            if item.isBordered != usesGlass { item.isBordered = usesGlass }
            if item.isEnabled != button.isEnabled { item.isEnabled = button.isEnabled }
            if item.autovalidates { item.autovalidates = false }
            #if compiler(>=6.2)
                if #available(macOS 26, *) {
                    let itemStyle: NSToolbarItem.Style = usesGlass ? .prominent : .plain
                    if item.style != itemStyle { item.style = itemStyle }
                    let tint: NSColor? = usesGlass ? TypefluxColor.accent.nsColor : nil
                    if item.backgroundTintColor != tint { item.backgroundTintColor = tint }
                }
            #endif
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: TypefluxToolbarAction
        init(action: TypefluxToolbarAction) { self.action = action }

        @objc func perform(_ sender: NSButton) {
            guard sender.isEnabled else { return }
            action.perform()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> ToolbarView {
        let view = ToolbarView(frame: .zero)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ToolbarView, context: Context) {
        context.coordinator.action = action
        view.itemIdentifier = action.accessibilityIdentifier
        view.usesGlass = usesGlass
        view.itemSize = NSSize(width: TypefluxControlWidth.toolbarItem.value(for: style),
                               height: TypefluxControlHeight.toolbarItem.value(for: style))
        let button = view.button
        button.target = context.coordinator
        button.action = #selector(Coordinator.perform(_:))
        button.title = action.title
        button.image = NSImage(systemSymbolName: action.systemImage, accessibilityDescription: action.title)
        button.isEnabled = isEnabled && action.isEnabled
        button.isBordered = !usesGlass
        button.bezelColor = TypefluxColor.accent.nsColor
        button.contentTintColor = .white
        button.toolTip = action.title
        button.setAccessibilityLabel(action.title)
        button.setAccessibilityIdentifier(action.accessibilityIdentifier)
        button.keyEquivalent = action.shortcut.map { String($0.character) } ?? ""
        var modifiers: NSEvent.ModifierFlags = []
        if action.modifiers.contains(.command) { modifiers.insert(.command) }
        if action.modifiers.contains(.control) { modifiers.insert(.control) }
        if action.modifiers.contains(.option) { modifiers.insert(.option) }
        if action.modifiers.contains(.shift) { modifiers.insert(.shift) }
        button.keyEquivalentModifierMask = modifiers
        view.invalidateIntrinsicContentSize()
        view.schedule()
    }

    static func dismantleNSView(_ view: ToolbarView, coordinator _: Coordinator) {
        view.itemIdentifier = ""
        view.button.isEnabled = false
        view.button.target = nil
        view.button.action = nil
        view.button.keyEquivalent = ""
    }
}
