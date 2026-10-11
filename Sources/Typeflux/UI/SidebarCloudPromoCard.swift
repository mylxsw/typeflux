import SwiftUI

/// Whether the sidebar's Typeflux Cloud card shows: until the user closes it,
/// then again after a quiet period.
enum AskCloudPromo {
    static let dismissedKey = "ask.cloudPromo.dismissedAt"
    static let quietPeriod: TimeInterval = 30 * 24 * 60 * 60

    struct Feature: Hashable {
        let symbol: String
        let key: String
    }

    /// What signing in adds, as scannable labels rather than a sentence.
    static let features = [
        Feature(symbol: "photo", key: "ask.cloudPromo.vision"),
        Feature(symbol: "globe", key: "ask.cloudPromo.search"),
        Feature(symbol: "arrow.triangle.2.circlepath", key: "ask.cloudPromo.sync"),
    ]

    /// "Images · Web Search · Sync": the sign-in pill's tooltip once the card is gone.
    static var summary: String {
        features.map { L($0.key) }.joined(separator: " · ")
    }

    static func isVisible(dismissedAt: TimeInterval, now: Date = Date()) -> Bool {
        dismissedAt <= 0 || now.timeIntervalSince1970 - dismissedAt >= quietPeriod
    }
}

/// What Typeflux Cloud adds, above the signed-out footer. While it shows it owns
/// the sign-in action; closing it keeps it away for `AskCloudPromo.quietPeriod`.
struct AskCloudPromoCard: View {
    @Environment(\.colorScheme) private var colorScheme

    var onSignIn: () -> Void
    var onDismiss: () -> Void

    private var iconColor: Color {
        colorScheme == .dark ? StudioTheme.textPrimary : StudioTheme.accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "cloud").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .accessibilityHidden(true)
                Text(verbatim: "Typeflux Cloud").font(.system(size: 12.5, weight: .semibold))
                Spacer(minLength: 4)
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(AskPressableStyle())
                .help(L("ask.cloudPromo.dismiss"))
                .accessibilityLabel(L("ask.cloudPromo.dismiss"))
            }
            .foregroundStyle(StudioTheme.textPrimary)
            .padding(.leading, 2)
            HStack(spacing: 4) {
                ForEach(AskCloudPromo.features, id: \.self) { feature in
                    VStack(spacing: 4) {
                        Image(systemName: feature.symbol).font(.system(size: 13, weight: .medium))
                            .foregroundStyle(iconColor)
                            .frame(height: 15)
                            .accessibilityHidden(true)
                        Text(L(feature.key)).font(.system(size: 11, weight: .medium))
                            .foregroundStyle(StudioTheme.textPrimary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .padding(.horizontal, 2).padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .background(StudioTheme.accentSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(.top, 7).padding(.bottom, 10)
            Button(L("ask.cloudPromo.signIn"), action: onSignIn)
                .buttonStyle(AskCapsuleButtonStyle(kind: .primary, expands: true))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioTheme.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(StudioTheme.cardStroke, lineWidth: 0.5))
    }
}
