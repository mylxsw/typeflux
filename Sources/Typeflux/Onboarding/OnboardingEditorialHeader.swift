import SwiftUI

struct OnboardingEditorialHeader: View {
    let eyebrow: String
    let title: String
    var subtitle: String?
    var pill: String?
    var centered = false

    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 8) {
            Text(eyebrow.uppercased()).font(.system(size: 9.5, weight: .semibold))
                .tracking(1.6).foregroundStyle(Color.accentColor)
            Text(title).font(.system(size: 30, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(centered ? .center : .leading)
        .padding(.trailing, centered || pill == nil ? 0 : 84)
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
        .overlay(alignment: .topTrailing) {
            if let pill {
                Text(pill).font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.tertiary).padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.primary.opacity(0.04), in: Capsule())
                    .overlay(Capsule().stroke(.primary.opacity(0.07), lineWidth: 1))
            }
        }
    }
}
