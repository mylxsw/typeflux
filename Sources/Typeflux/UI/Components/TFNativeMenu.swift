import AppKit
import SwiftUI

/// One row of a native menu built by `TFNativeMenuControl`.
struct TFNativeMenuEntry: Equatable {
    enum Kind: Equatable {
        /// A selectable row; `tag` is reported back through `onSelect`.
        case item(tag: Int)
        case header
        case separator
    }

    var kind: Kind
    var title: String = ""
    var systemImage: String?
    /// A picture such as an app logo; used instead of `systemImage`.
    var image: NSImage?
    var count: Int?
    var destructive = false
    var isSelected = false
    var isEnabled = true

    static let separator = TFNativeMenuEntry(kind: .separator)

    static func header(_ title: String) -> TFNativeMenuEntry {
        TFNativeMenuEntry(kind: .header, title: title)
    }

    /// The menu title. A count is right-aligned with a tab stop, like system menus.
    func attributedTitle(countColumn: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: countColumn)]
        let text = count.map { "\(title)\t\($0)" } ?? title
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .paragraphStyle: paragraph
        ])
        if destructive {
            result.addAttribute(.foregroundColor, value: NSColor.systemRed,
                                range: NSRange(location: 0, length: (title as NSString).length))
        }
        if let count {
            let start = (title as NSString).length + 1
            result.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                                range: NSRange(location: start, length: ("\(count)" as NSString).length))
        }
        return result
    }

    /// The tab stop for counts: wide enough for the longest title plus a gap.
    static func countColumn(for entries: [TFNativeMenuEntry]) -> CGFloat {
        let font = NSFont.menuFont(ofSize: 0)
        let widest = entries.map { ($0.title as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return ceil(widest) + 36
    }

    /// Builds the menu. Pop-up menus mark the selected row with the system checkmark.
    static func makeMenu(_ entries: [TFNativeMenuEntry], target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let column = countColumn(for: entries)
        for entry in entries {
            switch entry.kind {
            case .separator:
                menu.addItem(.separator())
            case .header:
                if #available(macOS 14.0, *) {
                    menu.addItem(.sectionHeader(title: entry.title))
                } else {
                    let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    menu.addItem(item)
                }
            case let .item(tag):
                let item = NSMenuItem(title: entry.title, action: action, keyEquivalent: "")
                item.target = target
                item.tag = tag
                if entry.count != nil || entry.destructive {
                    item.attributedTitle = entry.attributedTitle(countColumn: column)
                }
                if let image = entry.image {
                    item.image = image
                } else if let symbol = entry.systemImage {
                    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                    if symbol == "sparkles" {
                        item.image = image?.withSymbolConfiguration(.init(paletteColors: [NSColor(StudioTheme.aiIcon)]))
                        item.image?.isTemplate = false
                    } else {
                        item.image = image
                    }
                }
                item.state = entry.isSelected ? .on : .off
                item.isEnabled = entry.isEnabled
                menu.addItem(item)
            }
        }
        return menu
    }
}

/// An invisible native pop-up or pull-down button. SwiftUI draws the capsule; AppKit keeps
/// the full hit area, keyboard navigation, VoiceOver and the native menu (which macOS 26
/// renders as Liquid Glass on its own).
struct TFNativeMenuControl: NSViewRepresentable {
    var entries: [TFNativeMenuEntry]
    /// Pull-down menus run actions; pop-up menus choose a value and open over the selected row.
    var pullsDown: Bool
    var accessibilityTitle: String
    var accessibilityValue: String?
    var identifier: String?
    var enabled: Bool
    var onSelect: (Int) -> Void

    final class MenuButton: NSPopUpButton {
        override func draw(_: NSRect) {}
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }
        /// No alignment insets, so the button covers exactly the capsule SwiftUI draws.
        override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
        override var focusRingMaskBounds: NSRect { bounds }
        override func drawFocusRingMask() {
            NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        }
    }

    final class Coordinator: NSObject {
        var onSelect: (Int) -> Void

        init(onSelect: @escaping (Int) -> Void) {
            self.onSelect = onSelect
        }

        @objc func choose(_ sender: NSMenuItem) {
            onSelect(sender.tag)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context _: Context) -> NSPopUpButton {
        let button = MenuButton(frame: .zero, pullsDown: pullsDown)
        button.isBordered = false
        button.focusRingType = .exterior
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.onSelect = onSelect
        button.pullsDown = pullsDown
        let menu = TFNativeMenuEntry.makeMenu(entries, target: context.coordinator,
                                              action: #selector(Coordinator.choose(_:)))
        if pullsDown {
            // A pull-down button shows its first item as the closed title.
            menu.insertItem(NSMenuItem(title: accessibilityTitle, action: nil, keyEquivalent: ""), at: 0)
        }
        button.menu = menu
        if !pullsDown {
            let selected = menu.items.firstIndex { $0.state == .on }
            button.selectItem(at: selected ?? -1)
        }
        button.isEnabled = enabled
        button.setAccessibilityLabel(accessibilityTitle)
        if let accessibilityValue { button.setAccessibilityValue(accessibilityValue) }
        if let identifier { button.setAccessibilityIdentifier(identifier) }
    }
}

extension View {
    /// Tags the SwiftUI container of a native menu control too: the SwiftUI accessibility tree
    /// does not always surface the identifier of the AppKit button inside it.
    @ViewBuilder func tfMenuContainer(_ identifier: String?) -> some View {
        if let identifier {
            accessibilityElement(children: .contain).accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}
