import SwiftUI

struct OnboardingProviderCard: View {
    let provider: StudioModelProviderID
    let title: String
    var detail: String?
    var badge: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        OnboardingSelectableCard(selected: selected, action: action,
                                 insets: EdgeInsets(top: 11, leading: 12, bottom: 11, trailing: 12)) {
            HStack(spacing: 12) {
                OnboardingProviderIcon(provider: provider).environment(\.colorScheme, .light)
                    .frame(width: 38, height: 38).background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.black.opacity(0.1), lineWidth: 1))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13.5, weight: .semibold)).lineLimit(2)
                    if let detail {
                        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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

/// Match the onboarding marks while leaving the Studio's existing icon styling intact.
struct OnboardingProviderIcon: View {
    let provider: StudioModelProviderID

    var body: some View {
        Group {
            switch provider {
            case .localSTT:
                Image(systemName: "cpu").font(.system(size: 15)).foregroundStyle(Color.accentColor)
            case .freeSTT, .freeModel:
                Image(systemName: "infinity").font(.system(size: 22, weight: .semibold)).foregroundStyle(.black)
            default:
                ModelProviderIcon(provider: provider, size: 24)
            }
        }
        .frame(width: 24, height: 24).accessibilityHidden(true)
    }
}
