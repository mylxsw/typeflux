import AppKit
import SwiftUI

/// Shared metrics for single-line settings fields, menus and actions.
enum SettingsControlMetrics {
    static let height: CGFloat = 30
    static let fontSize: CGFloat = 13
    static let horizontalPadding: CGFloat = 10
}

/// Keep native menu behavior while drawing the same chrome as settings action buttons.
struct SettingsActionMenu: View {
    enum Item {
        case action(String, symbol: String? = nil, () -> Void)
        case separator
    }

    let title: String
    var symbol: String?
    var primary = false
    let identifier: String
    let items: [Item]
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        ZStack {
            visualLabel.accessibilityHidden(true)
            NativeSettingsActionMenu(title: title, identifier: identifier, items: items, enabled: enabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifier)
        }
        .opacity(enabled ? 1 : 0.45)
    }

    private var visualLabel: some View {
        HStack(spacing: 7) {
            if let symbol { Image(systemName: symbol) }
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
        }
        .font(.system(size: SettingsControlMetrics.fontSize, weight: .medium))
        .padding(.horizontal, 12)
        .frame(height: SettingsControlMetrics.height)
        .foregroundStyle(primary ? .white : StudioTheme.textPrimary)
        .background(primary ? ModelVisualStyle.accent : ModelVisualStyle.control,
                    in: RoundedRectangle(cornerRadius: ModelVisualStyle.controlCornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ModelVisualStyle.controlCornerRadius, style: .continuous)
            .strokeBorder(primary ? Color.clear : ModelVisualStyle.border))
    }
}

private struct NativeSettingsActionMenu: NSViewRepresentable {
    let title: String
    let identifier: String
    let items: [SettingsActionMenu.Item]
    let enabled: Bool

    /// SwiftUI draws the label; the native control still draws its keyboard focus ring.
    private final class MenuButton: NSPopUpButton {
        override func draw(_ dirtyRect: NSRect) {}
        override var focusRingMaskBounds: NSRect { bounds }
        override func drawFocusRingMask() {
            NSBezierPath(roundedRect: bounds, xRadius: ModelVisualStyle.controlCornerRadius,
                         yRadius: ModelVisualStyle.controlCornerRadius).fill()
        }
    }

    final class Coordinator: NSObject {
        var items: [SettingsActionMenu.Item] = []
        @objc func invoke(_ sender: NSMenuItem) {
            if case let .action(_, _, action) = items[sender.tag] { action() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = MenuButton(frame: .zero, pullsDown: true)
        button.isBordered = false
        button.focusRingType = .exterior
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.items = items
        let menu = NSMenu()
        // A pull-down button reserves its first item for the closed-state title.
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        for (index, item) in items.enumerated() {
            switch item {
            case .separator:
                menu.addItem(.separator())
            case let .action(title, symbol, _):
                let item = NSMenuItem(title: title, action: #selector(Coordinator.invoke(_:)), keyEquivalent: "")
                item.target = context.coordinator
                item.tag = index
                if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
                menu.addItem(item)
            }
        }
        button.menu = menu
        button.isEnabled = enabled
        button.setAccessibilityLabel(title)
        button.setAccessibilityIdentifier(identifier)
    }
}

struct SettingsControlChrome: ViewModifier {
    var focused = false
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        content
            .background(ModelVisualStyle.control,
                        in: RoundedRectangle(cornerRadius: ModelVisualStyle.controlCornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ModelVisualStyle.controlCornerRadius, style: .continuous)
                .strokeBorder(focused ? ModelVisualStyle.accent : ModelVisualStyle.border, lineWidth: focused ? 2 : 1))
            .opacity(enabled ? 1 : 0.45)
    }
}

/// A field-sized menu that preserves native keyboard navigation and selection marks.
struct SettingsMenuPicker<Value: Hashable>: View {
    let title: String
    let options: [(label: String, value: Value)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                Picker(title, selection: $selection) {
                    ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                        Text(option.label).tag(option.value)
                    }
                }
                // The automatic macOS style turns a picker inside a menu into a submenu.
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(options.first { $0.value == selection }?.label ?? title)
                    .lineLimit(1).truncationMode(.middle)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 18)
            .accessibilityLabel(title)
            .accessibilityValue(options.first { $0.value == selection }?.label ?? "")
        }
        .overlay(alignment: .trailing) {
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(StudioTheme.textSecondary)
                .allowsHitTesting(false)
        }
        .font(.system(size: SettingsControlMetrics.fontSize))
        .foregroundStyle(StudioTheme.textPrimary)
        .padding(.horizontal, SettingsControlMetrics.horizontalPadding)
        .frame(height: SettingsControlMetrics.height)
        .modifier(SettingsControlChrome())
    }
}

/// Search shared by the Models and Agent pages, including a named clear action.
struct SettingsSearchBox: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat? = 240
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
            TextField(placeholder, text: $text).textFieldStyle(.plain)
                .font(.system(size: SettingsControlMetrics.fontSize)).focused($focused)
                .accessibilityLabel(placeholder)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                        .foregroundStyle(StudioTheme.textTertiary)
                }
                .buttonStyle(.plain).accessibilityLabel(L("common.clear"))
            }
        }
        .padding(.horizontal, SettingsControlMetrics.horizontalPadding)
        .frame(width: width, height: SettingsControlMetrics.height)
        .modifier(SettingsControlChrome(focused: focused))
        .onAppear {
            // macOS may focus the first field before the pane finishes appearing.
            DispatchQueue.main.async { focused = false }
        }
    }
}
