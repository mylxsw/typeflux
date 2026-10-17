import AppKit
import SwiftUI

/// The composer's tool permission chooser. Each mode has its own colour so the
/// current level reads at a glance: strict green, standard blue, YOLO orange.
/// The label is always drawn in that colour, without a background.
/// In the menu only the current mode is coloured, in place of a checkmark.
struct AskPermissionModeMenu: View {
    var mode: AskPermissionMode
    /// The symbol alone; YOLO always spells itself out.
    var compact: Bool
    /// The launcher's bar: the symbol alone for every mode, YOLO included, and no chevron.
    var bare = false
    var onSelect: (AskPermissionMode) -> Void

    @Environment(\.colorScheme) private var colorScheme

    static func tint(_ mode: AskPermissionMode) -> Color {
        switch mode {
        case .strict: StudioTheme.success
        case .standard: StudioTheme.accent
        case .yolo: StudioTheme.warning
        }
    }

    static func labelColor(_ mode: AskPermissionMode) -> Color {
        tint(mode)
    }

    /// Borderless menus normalize SwiftUI's font on SF Symbols. Configure the
    /// image itself so the icon-only control can match its neighbors.
    static func toolbarImage(_ mode: AskPermissionMode) -> NSImage? {
        NSImage(systemSymbolName: mode.symbol, accessibilityDescription: L("ask.mode.title") + ": " + mode.title)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .semibold))
    }

    /// A menu redraws symbol images as templates in the text colour, so the
    /// current mode's symbol is drawn into a plain image, filled with its colour
    /// resolved for the menu's appearance. Filling the monochrome symbol keeps its
    /// cut-out glyph (lock, check, bolt). Other modes keep the template symbol.
    static func menuImage(_ option: AskPermissionMode, selected: Bool, dark: Bool) -> NSImage? {
        guard selected,
              let symbol = NSImage(systemSymbolName: option.symbol, accessibilityDescription: L("ask.mode.current")),
              let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        else { return nil }
        let dynamic = NSColor(tint(option))
        var color = dynamic
        appearance.performAsCurrentDrawingAppearance { color = dynamic.usingColorSpace(.sRGB) ?? dynamic }
        let fill = color
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            fill.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = symbol.accessibilityDescription
        return image
    }

    var body: some View {
        let iconOnly = bare || (compact && mode != .yolo)
        Menu {
            ForEach(AskPermissionMode.allCases, id: \.self) { option in
                Button { onSelect(option) } label: {
                    if let image = Self.menuImage(option, selected: mode == option, dark: colorScheme == .dark) {
                        Label {
                            Text(option.title + " · " + option.detail)
                        } icon: {
                            Image(nsImage: image).renderingMode(.original)
                        }
                    } else {
                        Label(option.title + " · " + option.detail, systemImage: option.symbol)
                    }
                }
            }
            // The menu's tint below colours the label; without this reset it also
            // tints every item's template symbol in the current mode's colour.
            .tint(.primary)
        } label: {
            Group {
                if iconOnly, let image = Self.toolbarImage(mode) {
                    Image(nsImage: image).renderingMode(.template).accessibilityHidden(true)
                } else {
                    Label(mode == .yolo ? "YOLO" : mode.title, systemImage: mode.symbol)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundStyle(Self.labelColor(mode))
            .fixedSize()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // Overrides the composer's accent so the label keeps this colour.
        .tint(Self.labelColor(mode))
        .fixedSize()
        .help(mode.detail + " /mode [yolo|strict|standard]")
        .accessibilityLabel(L("ask.mode.title") + ": " + mode.title)
        .accessibilityValue(mode.title)
        .accessibilityIdentifier("ask.composer.permissionMode")
    }
}
