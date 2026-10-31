import SwiftUI

/// A row of keycaps, e.g. ⌘ Space.
struct OnboardingKeycaps: View {
    let keys: [String]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.studioBody(11, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 22, minHeight: 21)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(colorScheme == .dark ? Color.white.opacity(0.1) : StudioTheme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(colorScheme == .dark ? Color.white.opacity(0.12) : StudioTheme.border, lineWidth: 1)
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys.joined(separator: " "))
    }
}
