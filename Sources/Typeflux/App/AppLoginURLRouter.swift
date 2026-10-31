import Foundation

@MainActor
enum AppLoginURLRouter {
    static func handle(_ urls: [URL], login: WebLoginCoordinator, isLoggedIn: () -> Bool,
                       showLogin: () -> Void, handleBilling: () async -> Void) async {
        let inlineLogin = OnboardingCloudModel.activeLogin
        let receiver = inlineLogin ?? login
        for url in urls where receiver.configuration.enabled && receiver.configuration.matchesCallback(url) {
            await receiver.receive(url)
            if inlineLogin == nil, OnboardingCloudModel.activeSession == nil, !isLoggedIn() {
                showLogin()
            }
        }
        if urls.contains(where: BillingReturnLink.matches) {
            await handleBilling()
        }
    }
}
