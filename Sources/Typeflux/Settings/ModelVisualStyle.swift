import SwiftUI

/// Model settings surfaces reuse the shared Studio palette so the page matches the rest of the app.
enum ModelVisualStyle {
    /// Opaque backdrop for sheets and popovers that do not sit on the window material.
    static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.13, alpha: 1)
            : NSColor(calibratedWhite: 0.965, alpha: 1)
    })
    static let accent = StudioTheme.accent
    static let surface = StudioTheme.cardSurface
    /// Opaque neutral fill for text fields, selectors and popover lists.
    static let input = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.15, alpha: 1)
            : NSColor(calibratedWhite: 0.975, alpha: 1)
    })
    /// Translucent fill for controls placed on cards.
    static let control = StudioTheme.controlSurface
    static let border = StudioTheme.border
    static let divider = StudioTheme.border.opacity(StudioTheme.Opacity.divider)
    static let cornerRadius = StudioTheme.CornerRadius.hero
    static let controlCornerRadius: CGFloat = 7
}

/// Card container matching `StudioCard` without imposing padding, for list-style content.
struct ModelSurface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ModelVisualStyle.surface,
                in: RoundedRectangle(cornerRadius: ModelVisualStyle.cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ModelVisualStyle.cornerRadius, style: .continuous)
                    .strokeBorder(ModelVisualStyle.border)
            )
            .clipShape(RoundedRectangle(cornerRadius: ModelVisualStyle.cornerRadius, style: .continuous))
    }
}

/// Small grey section caption shown above a card, e.g. "Configured 4".
struct ModelSectionLabel: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold))
            if let detail {
                Text(detail).font(.system(size: 12))
            }
        }
        .foregroundStyle(StudioTheme.textTertiary)
        .padding(.horizontal, 4)
    }
}

/// Inset divider between rows inside a model card.
struct ModelRowDivider: View {
    var leading: CGFloat = 18

    var body: some View {
        Rectangle().fill(ModelVisualStyle.divider).frame(height: 1)
            .padding(.leading, leading).padding(.trailing, 18)
    }
}

/// Dot plus label configuration state; hollow when the provider is not configured.
struct ModelConnectionStatus: View {
    let connected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if connected {
                    Circle().fill(StudioTheme.success)
                } else {
                    Circle().strokeBorder(StudioTheme.textTertiary, lineWidth: 1.5)
                }
            }.frame(width: 7, height: 7)
            Text(L(connected ? "models.configured" : "models.notConfigured"))
                .font(.system(size: 12))
                .foregroundStyle(connected ? StudioTheme.textSecondary : StudioTheme.textTertiary)
                .lineLimit(1)
        }
        .fixedSize()
    }
}

/// Rounded tile holding a provider logo or scene symbol.
struct ModelIconTile<Content: View>: View {
    var size: CGFloat = 34
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: size, height: size)
            .background(StudioTheme.iconTileSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Provider detail heading: back action, provider logo, title, subtitle and connection state.
struct ModelDetailHeader: View {
    let title: String
    let subtitle: String
    let icon: StudioModelProviderID
    let connected: Bool
    var onBack: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("models.back"))
                .help(L("models.back"))
            }
            ModelIconTile(size: 38) {
                ModelProviderIcon(provider: icon, size: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.studioDisplay(StudioTheme.Typography.pageTitle, weight: .bold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(subtitle).font(.system(size: 13)).foregroundStyle(StudioTheme.textTertiary)
            }
            Spacer(minLength: 12)
            ModelConnectionStatus(connected: connected)
        }
    }
}

struct ModelActionStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12).frame(height: SettingsControlMetrics.height)
            .foregroundStyle(primary ? .white : StudioTheme.textPrimary)
            .background(
                primary ? ModelVisualStyle.accent : ModelVisualStyle.control,
                in: RoundedRectangle(cornerRadius: ModelVisualStyle.controlCornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ModelVisualStyle.controlCornerRadius, style: .continuous)
                    .strokeBorder(primary ? Color.clear : ModelVisualStyle.border)
            )
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}

struct ModelFieldStyle: TextFieldStyle {
    /// Extra trailing room for an accessory drawn over the field, such as a reveal button.
    var trailingAccessoryWidth: CGFloat = 0
    /// Endpoints, keys and model IDs read best monospaced; free-form names do not.
    var monospaced = true
    @Environment(\.isFocused) private var focused

    // TextFieldStyle requires this underscored protocol method.
    // swiftlint:disable:next identifier_name
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain)
            .font(.system(size: SettingsControlMetrics.fontSize, design: monospaced ? .monospaced : .default))
            .padding(.leading, SettingsControlMetrics.horizontalPadding)
            .padding(.trailing, SettingsControlMetrics.horizontalPadding + trailingAccessoryWidth)
            .frame(height: SettingsControlMetrics.height)
            .modifier(SettingsControlChrome(focused: focused))
    }
}

struct ModelUsageBadge: View {
    let text: String
    /// Accent badges mark scene assignments; neutral ones carry secondary metadata.
    var accent = false
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium))
            .foregroundStyle(accent ? ModelVisualStyle.accent : StudioTheme.textSecondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(
                accent ? ModelVisualStyle.accent.opacity(0.14) : StudioTheme.textSecondary.opacity(0.09),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .lineLimit(1)
            .fixedSize()
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
