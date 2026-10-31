import SwiftUI

struct OnboardingSpeechPage: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @ObservedObject var model: OnboardingSpeechModel

    var body: some View { OnboardingPageScaffold(step: .speech) }
}
