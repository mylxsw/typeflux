import SwiftUI

/// Reusable signed-out identity; each window supplies its own account action.
struct AskSignedOutIdentity: View {
    var active = false
    var detail: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "desktopcomputer").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .frame(width: 30, height: 30)
                    .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("ask.local.identity")).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                    Text(L("ask.local.identity.storage"))
                        .font(.system(size: 11))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .lineLimit(1).minimumScaleFactor(0.85)
                }
            }
            .padding(.leading, 4).padding(.trailing, 8)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(hovering || active ? AskTheme.hoverFill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, -4)
        .onHover { hovering = $0 }
        .help(detail)
        .accessibilityLabel(L("ask.local.identity"))
        .accessibilityValue(detail)
        .accessibilityIdentifier("sidebar.signedOutIdentity")
    }
}
