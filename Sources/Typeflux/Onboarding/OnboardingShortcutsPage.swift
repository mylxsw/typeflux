import SwiftUI

struct OnboardingShortcutsPage: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @ObservedObject var model: OnboardingShortcutsModel

    var body: some View { OnboardingPageScaffold(step: .shortcuts) }
}
