import SwiftUI

struct OnboardingSelectableCard<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    var insets = EdgeInsets(top: 18, leading: 18, bottom: 18, trailing: 18)
    @ViewBuilder var content: () -> Content

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                content().frame(maxWidth: .infinity, alignment: .leading)
                OnboardingSelectionIndicator(selected: selected)
            }
            .padding(insets)
            .modifier(OnboardingSelectionSurface(selected: selected))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Keep provider lists and route choices on the same quiet selection treatment.
struct OnboardingSelectionSurface: ViewModifier {
    let selected: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color.primary.opacity(borderOpacity), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 18))
    }

    private var fill: Color {
        if colorScheme == .dark {
            return .white.opacity(selected ? 0.1 : 0.045)
        }
        return selected ? Color.accentColor.opacity(0.055) : .white
    }

    private var borderOpacity: Double {
        if contrast == .increased { return selected ? 0.5 : 0.25 }
        return selected ? 0.2 : 0.08
    }
}

struct OnboardingSelectionIndicator: View {
    let selected: Bool

    var body: some View {
        ZStack {
            if selected {
                Circle().fill(Color.accentColor)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Circle().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1.5)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}
