import SwiftUI

struct OnboardingTryPage: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @ObservedObject var model: OnboardingTryModel

    var body: some View { OnboardingPageScaffold(step: .try) }
}
