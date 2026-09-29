import SwiftUI

/// Flat surfaces keep model configuration legible in both appearances.
enum ModelVisualStyle {
    static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.078, green: 0.082, blue: 0.09, alpha: 1)
            : NSColor(srgbRed: 0.965, green: 0.97, blue: 0.98, alpha: 1)
    })
    static let accent = Color(red: 0.15, green: 0.44, blue: 0.90)
    static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 1)
            : NSColor.white
    })
    static let input = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.10, green: 0.11, blue: 0.12, alpha: 1)
            : NSColor(srgbRed: 0.97, green: 0.975, blue: 0.98, alpha: 1)
    })
    static let border = Color.primary.opacity(0.09)
}

struct ModelSurface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ModelVisualStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ModelVisualStyle.border))
    }
}

struct ModelActionStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12).frame(height: 32)
            .foregroundStyle(primary ? .white : StudioTheme.textPrimary)
            .background(primary ? ModelVisualStyle.accent : StudioTheme.textSecondary.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 8))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}

struct ModelFieldStyle: TextFieldStyle {
    // TextFieldStyle requires this underscored protocol method.
    // swiftlint:disable:next identifier_name
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            .padding(.horizontal, 12).frame(height: 34)
            .background(ModelVisualStyle.input, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ModelVisualStyle.border))
    }
}

struct ModelUsageBadge: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium))
            .foregroundStyle(StudioTheme.textSecondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(StudioTheme.textSecondary.opacity(0.09), in: Capsule())
    }
}

struct ModelCheckboxStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 10) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 17))
                    .foregroundStyle(configuration.isOn
                        ? ModelVisualStyle.accent : StudioTheme.textSecondary.opacity(0.5))
                configuration.label.foregroundStyle(StudioTheme.textPrimary)
            }.opacity(enabled ? 1 : 0.5)
        }.buttonStyle(.plain)
    }
}
