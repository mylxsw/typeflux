import SwiftUI

struct OnboardingSelectableCard<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                content().frame(maxWidth: .infinity, alignment: .leading)
                ZStack {
                    Circle().stroke(selected ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: 1.5)
                    if selected {
                        Circle().fill(Color.accentColor).padding(4)
                    }
                }.frame(width: 18, height: 18).accessibilityHidden(true)
            }
            .padding(18)
            .background(
                selected ?
                    (colorScheme == .dark ? Color(red: 0.227, green: 0.227, blue: 0.251).opacity(0.96) : Color
                        .accentColor.opacity(0.07))
                    : colorScheme == .dark ? Color.white.opacity(0.045) : Color.white,
                in: RoundedRectangle(cornerRadius: 18)
            )
            .overlay(RoundedRectangle(cornerRadius: 18)
                .stroke(
                    selected ? (colorScheme == .dark ? Color.white.opacity(0.28) : Color.accentColor.opacity(0.28)) :
                        Color.primary.opacity(0.08),
                    lineWidth: 1
                ))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 21).stroke(Color.accentColor.opacity(0.85), lineWidth: 1.2)
                        .padding(-3)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
