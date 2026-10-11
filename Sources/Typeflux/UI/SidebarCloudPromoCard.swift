import SwiftUI

/// Whether the sidebar's Typeflux Cloud card shows: until the user closes it,
/// then again after a quiet period.
enum AskCloudPromo {
    static let dismissedKey = "ask.cloudPromo.dismissedAt"
    static let quietPeriod: TimeInterval = 30 * 24 * 60 * 60

    static func isVisible(dismissedAt: TimeInterval, now: Date = Date()) -> Bool {
        dismissedAt <= 0 || now.timeIntervalSince1970 - dismissedAt >= quietPeriod
    }
}

/// What Typeflux Cloud adds, above the signed-out footer. Closing it keeps it
/// away for `AskCloudPromo.quietPeriod`.
struct AskCloudPromoCard: View {
    @Environment(\.colorScheme) private var colorScheme

    var onSignIn: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "cloud").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(colorScheme == .dark ? StudioTheme.textPrimary : StudioTheme.accent)
                    .accessibilityHidden(true)
                Text(verbatim: "Typeflux Cloud").font(.system(size: 12.5, weight: .semibold))
                Spacer(minLength: 4)
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("ask.cloudPromo.dismiss"))
                .accessibilityLabel(L("ask.cloudPromo.dismiss"))
            }
            .foregroundStyle(StudioTheme.textPrimary)
            Text(L("ask.cloudPromo.body"))
                .font(.system(size: 11.5))
                .foregroundStyle(StudioTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L("ask.cloudPromo.signIn"), action: onSignIn)
                .buttonStyle(AskCapsuleButtonStyle(kind: .primary))
                .padding(.top, 2)
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            if colorScheme == .dark {
                shape.fill(LinearGradient(colors: [AskTheme.accent.opacity(0.16), Color.purple.opacity(0.1)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
            } else {
                shape.fill(Color.white.opacity(0.70))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(colorScheme == .dark ? AskTheme.separator : StudioTheme.sidePanelStroke, lineWidth: 0.5))
    }
}
