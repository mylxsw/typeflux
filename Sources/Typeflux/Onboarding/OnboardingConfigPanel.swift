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
        VStack(alignment: .leading, spacing: 16) {
            Text(eyebrow.uppercased()).font(.system(size: 9.5, weight: .semibold))
                .tracking(1.6).foregroundStyle(Color.accentColor)
            HStack(spacing: 12) {
                if let provider {
                    ModelProviderIcon(provider: provider, size: 24).environment(\.colorScheme, .light).frame(
                        width: 38,
                        height: 38
                    )
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.system(size: 18, weight: .bold))
                    if let detail {
                        Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            ScrollView { fields().frame(maxWidth: .infinity, alignment: .leading) }
                .scrollIndicators(.hidden)
            actions().frame(maxWidth: .infinity)
            result().font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(colorScheme == .dark ? Color.white.opacity(0.045) : .white,
                    in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.primary.opacity(0.08), lineWidth: 1))
    }
}
