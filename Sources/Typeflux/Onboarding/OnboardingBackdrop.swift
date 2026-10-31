import SwiftUI

struct OnboardingBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        let dark = colorScheme == .dark
        LinearGradient(colors: dark
            ? [Color(red: 0.09, green: 0.09, blue: 0.102), Color(red: 0.059, green: 0.059, blue: 0.071)]
            : [Color(red: 0.984, green: 0.98, blue: 0.976), Color(red: 0.937, green: 0.945, blue: 0.961)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                RadialGradient(colors: [Color.accentColor.opacity(dark ? 0.16 : 0.10), .clear],
                               center: .topTrailing, startRadius: 0, endRadius: 460)
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}
