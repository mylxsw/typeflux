import SwiftUI

struct ModelDetailHeader: View {
    let title: String
    let icon: StudioModelProviderID
    let connected: Bool
    var backTitle: String?
    var onBack: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let onBack {
                ModelProviderBackButton(title: backTitle ?? ModelPageTab.providers.title, action: onBack)
            }
            HStack(spacing: 12) {
                ModelIconTile(size: 38) {
                    ModelProviderIcon(provider: icon, size: 24)
                }
                .accessibilityElement(children: .ignore).accessibilityLabel(title)
                .accessibilityIdentifier("models.provider.title")
                Spacer(minLength: 12)
                ModelConnectionStatus(connected: connected)
            }
        }
    }
}
