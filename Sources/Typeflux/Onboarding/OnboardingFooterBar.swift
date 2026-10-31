import SwiftUI

struct OnboardingFooterAction {
    let title: String
    var enabled = true
    let perform: () -> Void
}

struct OnboardingFooterBar<Leading: View>: View {
    var back: OnboardingFooterAction?
    var tertiary: OnboardingFooterAction?
    var primary: OnboardingFooterAction?
    var hint: String?
    @ViewBuilder var leading: () -> Leading
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 14) {
            if let back {
                action(back, symbol: "arrow.left", primary: false)
            }
            leading()
            Spacer(minLength: 8)
            if let hint, !hint.isEmpty {
                Text(hint).font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
            if let tertiary {
                Button(tertiary.title, action: tertiary.perform).buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.secondary)
                    .disabled(!tertiary.enabled)
            }
            if let primary {
                action(primary, symbol: "arrow.right", primary: true).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 10).frame(height: 58)
        .background(colorScheme == .dark ? Color(red: 0.118, green: 0.122, blue: 0.149)
            : Color(red: 0.965, green: 0.969, blue: 0.976), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.primary.opacity(0.07), lineWidth: 1))
    }

    private func action(_ action: OnboardingFooterAction, symbol: String, primary: Bool) -> some View {
        Button(action: action.perform) {
            HStack(spacing: 8) {
                if !primary {
                    Image(systemName: symbol)
                }
                Text(action.title)
                if primary {
                    Image(systemName: symbol)
                }
            }
            .font(.system(size: 12.5, weight: primary ? .bold : .semibold))
            .padding(.horizontal, primary ? 18 : 16).frame(height: 38)
            .foregroundStyle(primary ? Color.white : Color.primary)
            .background(primary ? Color.accentColor : Color.primary.opacity(0.04), in: Capsule())
            .overlay(Capsule().stroke(.primary.opacity(0.07), lineWidth: 1))
            .opacity(action.enabled ? 1 : 0.38)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).disabled(!action.enabled)
        .accessibilityLabel(action.title)
    }
}
