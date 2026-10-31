import SwiftUI

struct OnboardingProviderCard: View {
    let provider: StudioModelProviderID
    let title: String
    var detail: String?
    var badge: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        OnboardingSelectableCard(selected: selected, action: action) {
            HStack(spacing: 12) {
                ModelProviderIcon(provider: provider, size: 24).environment(\.colorScheme, .light)
                    .frame(width: 38, height: 38).background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.black.opacity(0.1), lineWidth: 1))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    if let detail {
                        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let badge {
                    Text(badge.uppercased()).font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.primary.opacity(0.05), in: Capsule())
                }
            }
        }
        .accessibilityLabel(title)
    }
}
