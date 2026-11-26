import Foundation

@MainActor
protocol AccountOnboardingProvider {
    static var hasActiveSession: Bool { get }
    static var activeLogin: WebLoginCoordinator? { get }
    static func presentInlineLogin() -> Bool
}

@MainActor
enum AccountOnboarding {
    static var provider: (any AccountOnboardingProvider.Type)?
    static var hasActiveSession: Bool { provider?.hasActiveSession == true }
}
