import SwiftUI

struct OnboardingSystemSettingsGuide: View {
    let title: String
    let steps: [String]
    let dismissTitle: String
    let dismiss: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.system(size: 12.5, weight: .bold))
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel(dismissTitle)
            }
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)").foregroundStyle(Color.accentColor)
                    Text(step).fixedSize(horizontal: false, vertical: true)
                }.font(.system(size: 12))
            }
        }
        .padding(14).frame(width: 270, alignment: .leading)
        .background(colorScheme == .dark ? Color(white: 0.17) : .white,
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
    }
}
