import AppKit
import SwiftUI

/// Shared metrics for single-line settings fields, menus and actions.
enum SettingsControlMetrics {
    static let height: CGFloat = 30
    static let menuHeight: CGFloat = 36
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
        override func draw(_: NSRect) {}
        override var focusRingMaskBounds: NSRect {
            bounds
        }

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

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context _: Context) -> NSPopUpButton {
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

/// Shared field appearance for native menus and status-rich popover selectors.
struct SettingsMenuField<Content: View>: View {
    @Environment(\.isEnabled) private var enabled
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 18)
            .overlay(alignment: .trailing) {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: StudioTheme.Typography.iconXSmall, weight: .semibold))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .allowsHitTesting(false)
            }
            .font(.studioBody(StudioTheme.Typography.body, weight: .semibold))
            .foregroundStyle(StudioTheme.textPrimary)
            .padding(.horizontal, StudioTheme.Insets.buttonHorizontal)
            .frame(height: SettingsControlMetrics.menuHeight)
            .background(
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous)
                    .fill(StudioTheme.controlSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.xLarge, style: .continuous)
                    .strokeBorder(StudioTheme.border, lineWidth: StudioTheme.BorderWidth.thin)
            )
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.45)
    }
}

/// The native menu covers the whole field, including padding and the custom arrow.
struct SettingsMenuPicker<Value: Hashable>: View {
    let title: String
    let options: [(label: String, value: Value)]
    @Binding var selection: Value
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        ZStack {
            SettingsMenuField {
                Text(options.first { $0.value == selection }?.label ?? title)
                    .lineLimit(1).truncationMode(.middle)
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            NativeSettingsMenuPicker(title: title, options: options, selection: $selection, enabled: enabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: SettingsControlMetrics.menuHeight)
    }
}

private struct NativeSettingsMenuPicker<Value: Hashable>: NSViewRepresentable {
    let title: String
    let options: [(label: String, value: Value)]
    @Binding var selection: Value
    let enabled: Bool

    /// SwiftUI draws the field; AppKit owns its full hit area and keyboard navigation.
    private final class MenuButton: NSPopUpButton {
        override func draw(_: NSRect) {}
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }
        override var alignmentRectInsets: NSEdgeInsets {
            NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        }
        override var focusRingMaskBounds: NSRect { bounds }
        override func drawFocusRingMask() {
            NSBezierPath(roundedRect: bounds, xRadius: StudioTheme.CornerRadius.xLarge,
                         yRadius: StudioTheme.CornerRadius.xLarge).fill()
        }
    }

    final class Coordinator: NSObject {
        var selection: Binding<Value>
        var values: [Value] = []

        init(selection: Binding<Value>) {
            self.selection = selection
        }

        @objc func choose(_ sender: NSMenuItem) {
            guard values.indices.contains(sender.tag) else { return }
            selection.wrappedValue = values[sender.tag]
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context _: Context) -> NSPopUpButton {
        let button = MenuButton(frame: .zero, pullsDown: false)
        button.isBordered = false
        button.focusRingType = .exterior
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.values = options.map(\.value)
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, option) in options.enumerated() {
            let item = NSMenuItem(title: option.label, action: #selector(Coordinator.choose(_:)), keyEquivalent: "")
            item.target = context.coordinator
            item.tag = index
            menu.addItem(item)
        }
        button.menu = menu
        button.selectItem(at: options.firstIndex { $0.value == selection } ?? -1)
        button.isEnabled = enabled
        button.setAccessibilityLabel(title)
        button.setAccessibilityValue(options.first { $0.value == selection }?.label ?? "")
    }
}

/// Search shared by the Models and Agent pages, including a named clear action.
struct SettingsSearchBox: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat? = 240
    var onFocus: () -> Void = {}
    var fieldIdentifier: String?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
            searchField
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
        .onChange(of: focused) { value in
            if value { onFocus() }
        }
        .onAppear {
            // macOS may focus the first field before the pane finishes appearing.
            DispatchQueue.main.async { focused = false }
        }
    }

    @ViewBuilder private var searchField: some View {
        let field = TextField(placeholder, text: $text).textFieldStyle(.plain)
            .font(.system(size: SettingsControlMetrics.fontSize)).focused($focused)
            .accessibilityLabel(placeholder)
            .onExitCommand { focused = false }
        if let fieldIdentifier {
            field.accessibilityIdentifier(fieldIdentifier)
        } else {
            field
        }
    }
}

/// A quiet caption above settings lists, with an optional nearby disclosure arrow.
struct SettingsListSectionLabel: View {
    let title: String
    let count: Int
    var expanded: Bool?

    var body: some View {
        HStack(spacing: 7) {
            if let expanded {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 12)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StudioTheme.textSecondary)
            Text(L("settings.list.itemCount", count))
                .font(.system(size: 11))
                .foregroundStyle(StudioTheme.textTertiary)
        }
        .foregroundStyle(StudioTheme.textSecondary)
        .padding(.horizontal, 4)
        .frame(minHeight: SettingsControlMetrics.height)
    }
}
