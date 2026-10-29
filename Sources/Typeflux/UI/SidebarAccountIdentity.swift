import SwiftUI

/// Reusable signed-out identity. Chat supplies a direct sign-in action without a
/// subtitle; settings keeps a two-line status with its separate sign-in entry.
struct AskSignedOutIdentity: View {
    var subtitle: String? = L("ask.local.identity.storage")
    var detail: String
    let action: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        if let action {
            Button(action: action) { label }
                .buttonStyle(.plain)
                .padding(.leading, -4)
                .onHover { hovering = $0 }
                .help(detail)
                .accessibilityLabel(L("ask.local.identity"))
                .accessibilityHint(detail)
                .accessibilityIdentifier("sidebar.signedOutIdentity")
        } else {
            // Status only: both lines stay readable as static text.
            label
                .padding(.leading, -4)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("sidebar.signedOutIdentity")
        }
    }

    private var label: some View {
        HStack(spacing: 9) {
            Image(systemName: "desktopcomputer").font(.system(size: 13, weight: .medium))
                .foregroundStyle(StudioTheme.textPrimary)
                .frame(width: 30, height: 30)
                .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(L("ask.local.identity")).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .lineLimit(1).minimumScaleFactor(0.85)
                }
            }
        }
        .padding(.leading, 4).padding(.trailing, 8)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(hovering ? AskTheme.hoverFill : .clear))
        .contentShape(Rectangle())
    }
}
