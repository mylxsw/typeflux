import SwiftUI

/// The composer's tool permission chooser. It is a menu, not a switch, so its
/// label stays neutral: a borderless menu draws its label in the inherited tint,
/// and the launcher's accent tint made it read like a switch that is on. YOLO
/// alone is coloured, in the danger tint on a faint well.
struct AskPermissionModeMenu: View {
    var mode: AskPermissionMode
    /// The symbol alone; YOLO always spells itself out.
    var compact: Bool
    /// The launcher's bar: the symbol alone for every mode, YOLO included, and no chevron.
    var bare = false
    var onSelect: (AskPermissionMode) -> Void

    static func labelColor(_ mode: AskPermissionMode) -> Color {
        mode == .yolo ? StudioTheme.danger : StudioTheme.textSecondary
    }

    static func wellFill(_ mode: AskPermissionMode) -> Color {
        mode == .yolo ? StudioTheme.danger.opacity(0.11) : .clear
    }

    var body: some View {
        Menu {
            ForEach(AskPermissionMode.allCases, id: \.self) { option in
                Button { onSelect(option) } label: {
                    Label(option.title + " — " + option.detail,
                          systemImage: mode == option ? "checkmark" : option.symbol)
                }
            }
        } label: {
            Group {
                if bare || (compact && mode != .yolo) {
                    Image(systemName: mode.symbol)
                } else {
                    Label(mode == .yolo ? "YOLO" : mode.title, systemImage: mode.symbol)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Self.labelColor(mode))
            .fixedSize()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // Overrides the composer's accent so the label keeps this colour.
        .tint(Self.labelColor(mode))
        .fixedSize()
        // Drawn around the menu without taking layout space from its neighbours.
        .background(Capsule().fill(Self.wellFill(mode)).padding(.horizontal, -4).padding(.vertical, -3))
        .help(mode.detail + " /mode [yolo|strict|standard]")
        .accessibilityLabel(L("ask.mode.title") + ": " + mode.title)
        .accessibilityIdentifier("ask.composer.permissionMode")
    }
}
