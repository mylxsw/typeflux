import Combine
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct OnboardingNavigationTests {
    @Test func `all routes keep four progress stages and always reach try`() {
        let cases: [(OnboardingViewModel.ServiceRoute, [OnboardingStep])] = [
            (.cloud, [.welcome, .route, .cloud, .permissions, .shortcuts, .try]),
            (.custom, [.welcome, .route, .speech, .llm, .permissions, .shortcuts, .try]),
            (.launcherOnly, [.welcome, .route, .permissions, .shortcuts, .try])
        ]
        for (route, expected) in cases {
            #expect(OnboardingStep.visibleSteps(for: route) == expected)
        }
        for step in OnboardingStep.allCases {
            #expect(step.analyticsName == step.rawValue)
            #expect(step.isCentered == [.route, .cloud].contains(step))
        }
        #expect(OnboardingStep.allCases.map(\.pill) == [nil, "01 / 04", "01 / 04", "01 / 04",
                                                        "01 / 04", "02 / 04", "03 / 04", "04 / 04"])
    }

    @Test func `recovery prioritizes speech then AI then permissions without erasing settings`() async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            let model = OnboardingViewModel(settingsStore: settings, onComplete: {})
            settings.activationHotkey = .rightCommandActivation
            for (speech, ai, expected) in [(true, true, OnboardingStep.speech), (false, true, .llm),
                                           (false, false, .permissions)] {
                settings.onboardingSpeechDeferred = speech
                settings.onboardingAIDeferred = ai
                model.resumeDeferredSetup()
                #expect(model.currentStep == expected)
                #expect(model.serviceRoute == .custom)
                #expect(model.speechSkipped == speech && model.aiSkipped == ai)
                #expect(settings.activationHotkey == .rightCommandActivation)
            }
        }
    }

    @Test func `route changes and invalid destinations never accidentally complete`() async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            let model = OnboardingViewModel(settingsStore: settings, onComplete: {})
            model.goBack()
            #expect(model.currentStep == .welcome)
            #expect(!model.canGoBack)
            model.currentStep = .speech // Invalid on the Cloud route.
            model.advanceToNextStepOrComplete()
            #expect(!settings.isOnboardingCompleted)
            model.chooseRoute(.cloud)
            #expect(model.currentStep == .route)
            model.currentStep = .cloud
            model.useCustomModels()
            #expect(model.currentStep == .speech && model.serviceRoute == .custom)
            model.skipConfirmation = .speech
            model.returnToRoute()
            #expect(model.currentStep == .route && model.skipConfirmation == nil)
            model.chooseRoute(.launcherOnly)
            model.advance()
            #expect(model.skipConfirmation == .allModels)
            #expect(model.currentStep == .route)
            model.confirmSkip()
            model.goBack()
            #expect(model.currentStep == .route)
            model.currentStep = .shortcuts
            model.advance()
            #expect(model.currentStep == .try)
            model.goBack()
            #expect(model.currentStep == .shortcuts)
        }
    }

    @Test func `page adapters forward readiness busy and inline actions to the shell`() async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            let model = OnboardingViewModel(settingsStore: settings, onComplete: {})
            var changes = 0
            let subscription = model.objectWillChange.sink { changes += 1 }
            defer { subscription.cancel() }
            var calls = 0
            let action = { calls += 1 }
            model.routeModel.canContinue = false; model.routeModel.primaryAction = action
            model.cloudModel.canContinue = false; model.cloudModel.primaryAction = action
            model.speechModel.canContinue = false; model.speechModel.primaryAction = action
            model.llmModel.canContinue = false; model.llmModel.primaryAction = action
            model.permissionsModel.canContinue = false; model.permissionsModel.primaryAction = action
            model.shortcutsModel.canContinue = false; model.shortcutsModel.primaryAction = action
            model.tryModel.canContinue = false; model.tryModel.primaryAction = action
            for step in OnboardingStep.allCases where step != .welcome {
                model.currentStep = step
                #expect(!model.canAdvance)
                #expect(!model.isPageBusy)
                model.performSetupAction()
            }
            #expect(calls == 7)
            model.cloudModel.isBusy = true
            model.currentStep = .cloud
            #expect(model.isSetupActionRunning)
            model.performSetupAction()
            #expect(calls == 7)
            model.cloudModel.canContinue = true
            #expect(!model.canAdvance)
            model.cloudModel.isBusy = false
            #expect(model.canAdvance)
            let count = changes
            model.tryModel.canContinue = true
            await Task.yield()
            try await SettingsBehaviorTestSupport.wait { changes > count }
            model.currentStep = .welcome
            #expect(model.pageReadiness == nil && model.pagePrimaryAction == nil && !model.isPageBusy)
        }
    }

    @Test func `missing page readiness never falls back to the removed editor flow`() async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            let model = OnboardingViewModel(settingsStore: settings, onComplete: {})
            model.cloudModel.canContinue = nil
            model.speechModel.canContinue = nil
            model.llmModel.canContinue = nil
            for step in [OnboardingStep.cloud, .speech, .llm] {
                model.currentStep = step
                #expect(!model.canAdvance)
                model.performSetupAction()
                #expect(model.currentStep == step)
            }
        }
    }

    @Test func `page tables resolve in all five languages and preserve format arguments`() {
        for language in AppLanguage.allCases {
            for step in OnboardingStep.allCases where step != .welcome {
                #expect(OnboardingStrings.text("title", table: step.table, language: language) != "title")
                #expect(OnboardingStrings.text("eyebrow", table: step.table, language: language) != "eyebrow")
                if step != .try {
                    #expect(OnboardingStrings.text("subtitle", table: step.table, language: language) != "subtitle")
                }
            }
            for key in ["back", "start", "finish", "continue", "later", "skip", "custom", "skipAll"] {
                #expect(OnboardingStrings.text(key, language: language) != key)
            }
        }
        #expect(OnboardingStrings.text("missing", table: "UnknownTable") == "missing")
        #expect(OnboardingStrings.text("%d", arguments: [42]) == "42")
    }
}
