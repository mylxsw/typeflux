import SwiftUI

struct OnboardingLLMPage: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @ObservedObject var model: OnboardingLLMModel

    var body: some View { OnboardingPageScaffold(step: .llm) }
}
