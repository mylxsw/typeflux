import Foundation

/// Pages and progress stages are intentionally separate: model setup shares stage one.
enum OnboardingStep: String, CaseIterable {
    case welcome, route, cloud, speech, llm, permissions, fileSearch, shortcuts, `try`, recall

    var analyticsName: String {
        rawValue
    }

    var stage: Int? {
        switch self {
        case .welcome: nil
        case .route, .cloud, .speech, .llm: 1
        case .permissions: 2
        case .fileSearch: 3
        case .shortcuts: 4
        case .try: 5
        case .recall: 6
        }
    }

    var pill: String? {
        stage.map { String(format: "%02d / 06", $0) }
    }

    var isCentered: Bool {
        self == .route || self == .cloud
    }

    var table: String {
        "Onboarding" + rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

    static func visibleSteps(for route: OnboardingViewModel.ServiceRoute) -> [Self] {
        let models: [Self] = switch route {
        case .cloud: [.cloud]
        case .custom: [.speech, .llm]
        case .launcherOnly: []
        }
        return [.welcome, .route] + models + [.permissions, .fileSearch, .shortcuts, .try, .recall]
    }
}
