import SwiftUI

struct OnboardingPermissionsPage: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @ObservedObject var model: OnboardingPermissionsModel

    var body: some View { OnboardingPageScaffold(step: .permissions) }
}
