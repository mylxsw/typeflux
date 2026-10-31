import SwiftUI

/// Intentionally empty content slot; stage-two owners replace each page independently.
struct OnboardingPageScaffold: View {
    let step: OnboardingStep
    var body: some View {
        VStack(spacing: 20) {
            if step.isCentered {
                Spacer(minLength: 0)
            }
            OnboardingEditorialHeader(
                eyebrow: OnboardingStrings.text("eyebrow", table: step.table),
                title: OnboardingStrings.text("title", table: step.table),
                subtitle: step == .try ? nil : OnboardingStrings.text("subtitle", table: step.table),
                pill: step.pill, centered: step.isCentered
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 34).padding(.top, 6)
    }
}
