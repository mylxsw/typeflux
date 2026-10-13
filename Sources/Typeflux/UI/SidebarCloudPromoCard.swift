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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Typeflux Cloud", systemImage: "cloud").font(.headline)
                Spacer()
                TypefluxIconButton(L("ask.cloudPromo.dismiss"), systemImage: "xmark", size: .small, action: onDismiss)
            }
            Text(AskCloudPromo.summary).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TypefluxButton(L("ask.cloudPromo.signIn"), kind: .primary, action: onSignIn)
        }
        .padding(12)
        .background(TypefluxColor.contentBackground.color)
    }
}
