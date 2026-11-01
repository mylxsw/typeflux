import SwiftUI

struct OnboardingConfigPanel<Fields: View, Actions: View, Result: View>: View {
    let eyebrow: String
    let name: String
    var provider: StudioModelProviderID?
    var detail: String?
    @ViewBuilder var fields: () -> Fields
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var result: () -> Result
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(eyebrow.uppercased()).font(.system(size: 9.5, weight: .semibold))
                .tracking(1.6).foregroundStyle(Color.accentColor)
            HStack(spacing: 12) {
                if let provider {
                    OnboardingProviderIcon(provider: provider).environment(\.colorScheme, .light).frame(
                        width: 38,
                        height: 38
                    )
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.black.opacity(0.1), lineWidth: 1))
                }
                Text(name).font(.system(size: 18, weight: .bold))
            }
            if let detail {
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, -6)
            }
            ScrollView { fields().frame(maxWidth: .infinity, alignment: .leading) }
                .scrollIndicators(.hidden)
            actions().frame(maxWidth: .infinity)
            result().font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 22).padding(.horizontal, 24).frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .background(colorScheme == .dark ? Color.white.opacity(0.045) : .white,
                    in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.primary.opacity(0.08), lineWidth: 1))
    }
}
