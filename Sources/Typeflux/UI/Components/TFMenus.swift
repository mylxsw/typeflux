import SwiftUI

/// A group of pop-up options with an optional header.
struct TFPopUpSection<Value: Hashable> {
    var title: String?
    var options: [TFOption<Value>]

    init(title: String? = nil, options: [TFOption<Value>]) {
        self.title = title
        self.options = options
    }

    /// Flattens sections into native menu entries; tags index into the flattened options.
    static func entries(_ sections: [TFPopUpSection], selection: Value?) -> [TFNativeMenuEntry] {
        var entries: [TFNativeMenuEntry] = []
        var tag = 0
        for (index, section) in sections.enumerated() {
            if index > 0 { entries.append(.separator) }
            if let title = section.title { entries.append(.header(title)) }
            for option in section.options {
                entries.append(TFNativeMenuEntry(kind: .item(tag: tag), title: option.title,
                                                 systemImage: option.systemImage, count: option.count,
                                                 isSelected: option.value == selection))
                tag += 1
            }
        }
        return entries
    }
}

/// Spec §5.1: choose one value. Shows the current value and a ⌃⌄ indicator; the native menu
/// opens over the selected row. 30pt (down from the old 36pt) so it lines up with buttons.
struct TFPopUpButton<Value: Hashable>: View {
    /// The accessibility label, e.g. "Language".
    let title: String
    let sections: [TFPopUpSection<Value>]
    @Binding var selection: Value
    var size: TFControlSize?
    /// Forms use `TFMetrics.formControlWidth`; nil hugs the content (at least 100pt).
    var width: CGFloat?
    /// A leading view for the current value, such as a status dot or provider icon.
    var leading: ((Value) -> AnyView)?
    var identifier: String?
    @Environment(\.tfControlSize) private var environmentSize
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    init(title: String, options: [TFOption<Value>], selection: Binding<Value>, size: TFControlSize? = nil,
         width: CGFloat? = nil, leading: ((Value) -> AnyView)? = nil, identifier: String? = nil) {
        self.init(title: title, sections: [TFPopUpSection(options: options)], selection: selection, size: size,
                  width: width, leading: leading, identifier: identifier)
    }

    init(title: String, sections: [TFPopUpSection<Value>], selection: Binding<Value>, size: TFControlSize? = nil,
         width: CGFloat? = nil, leading: ((Value) -> AnyView)? = nil, identifier: String? = nil) {
        self.title = title
        self.sections = sections
        _selection = selection
        self.size = size
        self.width = width
        self.leading = leading
        self.identifier = identifier
    }

    private var options: [TFOption<Value>] { sections.flatMap(\.options) }

    var body: some View {
        let size = size ?? environmentSize
        let current = options.first { $0.value == selection }
        ZStack {
            TFButtonChrome(kind: .secondary, destructive: false, size: size, iconOnly: false, isPressed: false,
                           hoverOverride: hovering) {
                HStack(spacing: size.spacing) {
                    if let leading { leading(selection) }
                    if let symbol = current?.systemImage, leading == nil {
                        Image(systemName: symbol).aiSymbolTint(symbol).font(.system(size: size.iconSize))
                    }
                    Text(current?.title ?? title)
                        .fontWeight(.regular)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(TFColors.textTertiary)
                }
                .padding(.trailing, -4)
            }
            .frame(minWidth: width == nil ? 100 : nil)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            TFNativeMenuControl(
                entries: TFPopUpSection.entries(sections, selection: selection),
                pullsDown: false,
                accessibilityTitle: title,
                accessibilityValue: current?.title,
                identifier: identifier,
                enabled: isEnabled
            ) { tag in
                let options = options
                guard options.indices.contains(tag) else { return }
                selection = options[tag].value
            }
        }
        .frame(width: width, height: size.height)
        .fixedSize(horizontal: width == nil, vertical: true)
        .onHover { hovering = $0 }
        .tfMenuContainer(identifier)
    }
}

/// One entry of an action menu.
enum TFMenuAction {
    case action(String, systemImage: String? = nil, destructive: Bool = false, isEnabled: Bool = true, () -> Void)
    /// An action with a picture, e.g. the logo of the app it imports from.
    case imageAction(String, image: NSImage?, () -> Void)
    /// A checkable option; the handler receives the new state.
    case toggle(String, isOn: Bool, isEnabled: Bool = true, (Bool) -> Void)
    /// A greyed-out line explaining the options around it.
    case note(String)
    case separator

    /// Native entries and the closures they run, by tag.
    static func entries(_ actions: [TFMenuAction]) -> (entries: [TFNativeMenuEntry], handlers: [() -> Void]) {
        var entries: [TFNativeMenuEntry] = []
        var handlers: [() -> Void] = []
        for action in actions {
            switch action {
            case .separator:
                entries.append(.separator)
            case let .action(title, symbol, destructive, isEnabled, handler):
                entries.append(TFNativeMenuEntry(kind: .item(tag: handlers.count), title: title, systemImage: symbol,
                                                 destructive: destructive, isEnabled: isEnabled))
                handlers.append(handler)
            case let .imageAction(title, image, handler):
                entries.append(TFNativeMenuEntry(kind: .item(tag: handlers.count), title: title, image: image))
                handlers.append(handler)
            case let .toggle(title, isOn, isEnabled, handler):
                entries.append(TFNativeMenuEntry(kind: .item(tag: handlers.count), title: title, isSelected: isOn,
                                                 isEnabled: isEnabled))
                handlers.append { handler(!isOn) }
            case let .note(title):
                entries.append(TFNativeMenuEntry(kind: .item(tag: handlers.count), title: title, isEnabled: false))
                handlers.append {}
            }
        }
        return (entries, handlers)
    }
}

/// Spec §5.2: a button that opens a list of related actions. Put destructive actions last,
/// after a separator. `iconOnly` gives the "⋯" circle used in rows and toolbars.
struct TFMenuButton: View {
    let title: String
    var systemImage: String?
    var kind: TFButtonKind = .secondary
    var size: TFControlSize?
    var iconOnly = false
    let actions: [TFMenuAction]
    var identifier: String?
    @Environment(\.tfControlSize) private var environmentSize
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let size = size ?? environmentSize
        let menu = TFMenuAction.entries(actions)
        ZStack {
            TFButtonChrome(kind: kind, destructive: false, size: size, iconOnly: iconOnly, isPressed: false,
                           hoverOverride: hovering) {
                HStack(spacing: size.spacing) {
                    if let systemImage {
                        Image(systemName: systemImage).aiSymbolTint(systemImage).font(.system(size: size.iconSize, weight: .semibold))
                    }
                    if !iconOnly {
                        Text(title)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).opacity(0.75)
                    }
                }
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            TFNativeMenuControl(entries: menu.entries, pullsDown: true, accessibilityTitle: title,
                                identifier: identifier, enabled: isEnabled) { tag in
                guard menu.handlers.indices.contains(tag) else { return }
                menu.handlers[tag]()
            }
        }
        .fixedSize()
        .help(iconOnly ? title : "")
        .onHover { hovering = $0 }
        .tfMenuContainer(identifier)
    }
}

/// Spec §5.3: "Option · count ⌄". Tinted with the accent while a non-default option is chosen,
/// so it is obvious the list is filtered.
struct TFFilterMenu<Value: Hashable>: View {
    let title: String
    let options: [TFOption<Value>]
    @Binding var selection: Value
    var defaultValue: Value
    var size: TFControlSize?
    var identifier: String?
    @Environment(\.tfControlSize) private var environmentSize
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    static func isActive(selection: Value, defaultValue: Value) -> Bool { selection != defaultValue }

    var body: some View {
        let size = size ?? environmentSize
        let current = options.first { $0.value == selection } ?? options.first
        let active = Self.isActive(selection: selection, defaultValue: defaultValue)
        ZStack {
            HStack(spacing: size.spacing) {
                Text(current?.title ?? title)
                if let count = current?.count {
                    Text(verbatim: "· \(count)").monospacedDigit()
                        .foregroundStyle(active ? TFColors.accent : TFColors.textTertiary)
                }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).opacity(0.75)
            }
            .font(.system(size: size.fontSize, weight: size.fontWeight))
            .foregroundStyle(active ? TFColors.accent : TFColors.textPrimary)
            .padding(.horizontal, size.horizontalPadding)
            .frame(height: size.height)
            .background(Capsule(style: .circular).fill(active ? TFColors.selection : TFColors.control))
            .overlay { Capsule(style: .circular).fill(hovering ? TFColors.hoverOverlay : .clear) }
            .overlay {
                if !active { Capsule(style: .circular).strokeBorder(TFColors.border, lineWidth: TFMetrics.borderWidth) }
            }
            .opacity(isEnabled ? 1 : TFMetrics.disabledOpacity)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            TFNativeMenuControl(
                entries: TFPopUpSection.entries([TFPopUpSection(options: options)], selection: selection),
                pullsDown: false, accessibilityTitle: title, accessibilityValue: current?.title,
                identifier: identifier, enabled: isEnabled
            ) { tag in
                guard options.indices.contains(tag) else { return }
                selection = options[tag].value
            }
        }
        .fixedSize()
        .onHover { hovering = $0 }
        .tfMenuContainer(identifier)
    }
}

/// A filter that is a segmented control when it fits (≤4 options, regular layout) and a
/// filter menu otherwise. Place it right after the search field.
struct TFFilterControl<Value: Hashable>: View {
    let title: String
    let options: [TFOption<Value>]
    @Binding var selection: Value
    var defaultValue: Value
    @Environment(\.tfCompactLayout) private var compact

    var body: some View {
        let menu = TFFilterMenu(title: title, options: options, selection: $selection, defaultValue: defaultValue)
        switch TFLayout.filterPresentation(optionCount: options.count, compact: compact) {
        case .segmented:
            ViewThatFits(in: .horizontal) {
                TFSegmentedControl(options: options, selection: $selection)
                menu
            }
        case .menu:
            menu
        }
    }
}
