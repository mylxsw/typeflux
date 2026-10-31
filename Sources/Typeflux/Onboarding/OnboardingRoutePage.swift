import SwiftUI

struct OnboardingRoutePage: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @ObservedObject var model: OnboardingRouteModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)
            OnboardingEditorialHeader(
                eyebrow: OnboardingStrings.text("eyebrow", table: "OnboardingRoute"),
                title: OnboardingStrings.text("title", table: "OnboardingRoute"),
                subtitle: OnboardingStrings.text("subtitle", table: "OnboardingRoute"),
                pill: OnboardingStep.route.pill, centered: true
            )
            HStack(spacing: 20) {
                route(.cloud, title: "Typeflux Cloud")
                route(.custom, title: OnboardingStrings.text("customTitle", table: "OnboardingRoute"))
            }.frame(maxWidth: 780)
            Spacer(minLength: 0)
        }.padding(.horizontal, 34)
    }

    private func route(_ route: OnboardingViewModel.ServiceRoute, title: String) -> some View {
        OnboardingSelectableCard(selected: viewModel.serviceRoute == route,
                                 action: { viewModel.chooseRoute(route) }) {
            Text(title).font(.system(size: 18, weight: .semibold)).frame(height: 100)
        }
    }
}
