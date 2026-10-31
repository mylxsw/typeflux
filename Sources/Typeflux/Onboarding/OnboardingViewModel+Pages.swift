import Combine
import Foundation

extension OnboardingViewModel {
    func observePageModels() {
        let publishers = [
            routeModel.objectWillChange.eraseToAnyPublisher(),
            cloudModel.objectWillChange.eraseToAnyPublisher(),
            speechModel.objectWillChange.eraseToAnyPublisher(),
            llmModel.objectWillChange.eraseToAnyPublisher(),
            permissionsModel.objectWillChange.eraseToAnyPublisher(),
            shortcutsModel.objectWillChange.eraseToAnyPublisher(),
            tryModel.objectWillChange.eraseToAnyPublisher()
        ]
        for publisher in publishers {
            publisher.sink { [weak self] in
                Task { @MainActor in self?.objectWillChange.send() }
            }.store(in: &pageSubscriptions)
        }
    }

    var pageReadiness: Bool? {
        switch currentStep {
        case .welcome: nil
        case .route: routeModel.canContinue
        case .cloud: cloudModel.canContinue
        case .speech: speechModel.canContinue
        case .llm: llmModel.canContinue
        case .permissions: permissionsModel.canContinue
        case .shortcuts: shortcutsModel.canContinue
        case .try: tryModel.canContinue
        }
    }

    var isPageBusy: Bool {
        switch currentStep {
        case .welcome: false
        case .route: routeModel.isBusy
        case .cloud: cloudModel.isBusy
        case .speech: speechModel.isBusy
        case .llm: llmModel.isBusy
        case .permissions: permissionsModel.isBusy
        case .shortcuts: shortcutsModel.isBusy
        case .try: tryModel.isBusy
        }
    }

    var pagePrimaryAction: (() -> Void)? {
        switch currentStep {
        case .welcome: nil
        case .route: routeModel.primaryAction
        case .cloud: cloudModel.primaryAction
        case .speech: speechModel.primaryAction
        case .llm: llmModel.primaryAction
        case .permissions: permissionsModel.primaryAction
        case .shortcuts: shortcutsModel.primaryAction
        case .try: tryModel.primaryAction
        }
    }
}
