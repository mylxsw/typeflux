import Foundation

@MainActor
enum AppLoginURLRouter {
    static func handle(_ urls: [URL], login: WebLoginCoordinator, isLoggedIn: () -> Bool,
                       showLogin: () -> Void, handleBilling: () async -> Void) async {
        for url in urls where login.configuration.enabled && login.configuration.matchesCallback(url) {
            await login.receive(url)
            if !isLoggedIn() {
                showLogin()
            }
        }
        if urls.contains(where: BillingReturnLink.matches) {
            await handleBilling()
        }
    }
}
