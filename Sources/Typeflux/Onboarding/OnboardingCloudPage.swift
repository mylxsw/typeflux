import SwiftUI

struct OnboardingCloudPage: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @ObservedObject var model: OnboardingCloudModel

    var body: some View { OnboardingPageScaffold(step: .cloud) }
}
