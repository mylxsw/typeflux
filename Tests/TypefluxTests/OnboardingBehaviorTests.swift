import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Onboarding rendered behavior", .serialized, .exclusiveUIState)
@MainActor
struct OnboardingBehaviorTests {
    private typealias RenderedUI = SettingsBehaviorTestSupport

    @Test func `language selection persists and back returns to the chosen language`() async throws {
        try await RenderedUI.withFixture { settings in
            let model = OnboardingViewModel(settingsStore: settings, onComplete: {})
            try await RenderedUI.withWindow(OnboardingView(viewModel: model, appearanceMode: .light)) { window, host in
                try await RenderedUI.wait { RenderedUI.contains(AppLanguage.traditionalChinese.displayName, in: host) }
                try RenderedUI.button(AppLanguage.traditionalChinese.displayName, in: host).press()
                try await RenderedUI.wait { model.appLanguage == .traditionalChinese }
                #expect(SettingsStore(defaults: settings.defaults).appLanguage == .traditionalChinese)
                #expect(AppLocalization.shared.language == .traditionalChinese)
                let next = try RenderedUI.button(L("onboarding.action.continue").uppercased(), in: host)
                #expect(window.frame.contains(next.frame))
                try next.press()
                try await RenderedUI.wait { model.currentStep == .account }
                try await RenderedUI.wait { RenderedUI.contains(L("onboarding.account.skip").uppercased(), in: host) }
                try RenderedUI.button(L("onboarding.action.back"), in: host).press()
                try await RenderedUI.wait { model.currentStep == .language }
                #expect(model.appLanguage == .traditionalChinese)
                try RenderedUI.snapshot(host, name: "onboarding-language")
            }
        }
    }

    @Test func `account skip enters manual setup without completing onboarding`() async throws {
        try await RenderedUI.withFixture { settings in
            var completions = 0
            let model = OnboardingViewModel(settingsStore: settings, onComplete: { completions += 1 })
            model.currentStep = .account
            try await RenderedUI.withWindow(OnboardingView(viewModel: model, appearanceMode: .dark)) { _, host in
                try await RenderedUI.wait { RenderedUI.contains(L("onboarding.account.skip").uppercased(), in: host) }
                try RenderedUI.button(L("onboarding.account.skip").uppercased(), in: host).press()
                try await RenderedUI.wait { model.currentStep == .stt }
                #expect(!model.useCloudAccountModels)
                #expect(model.visibleSteps == [.language, .account, .stt, .llm, .permissions, .shortcuts])
                #expect(!settings.isOnboardingCompleted)
                #expect(completions == 0)
            }
        }
    }

    @Test func `whisper form blocks missing credentials then saves A valid draft`() async throws {
        try await RenderedUI.withFixture { settings in
            let model = OnboardingViewModel(settingsStore: settings, onComplete: {})
            model.currentStep = .stt
            model.selectSTTProvider(.whisperAPI)
            model.whisperAPIKey = ""
            model.whisperBaseURL = "https://speech.example.test/v1"
            model.whisperModel = "fixture-transcriber"
            try await RenderedUI.withWindow(OnboardingView(viewModel: model, appearanceMode: .light)) { window, host in
                try await RenderedUI.wait { RenderedUI.contains(L("settings.models.whisper.endpoint"), in: host) }
                #expect(RenderedUI.contains(L("common.apiKey"), in: host))
                try RenderedUI.button(L("onboarding.action.continue").uppercased(), in: host).press()
                try await RenderedUI.wait { window.attachedSheet != nil }
                #expect(model.currentStep == .stt)
                #expect(model.showIncompleteSTTConfigurationAlert)
                let sheet = try #require(window.attachedSheet)
                try RenderedUI.button(L("common.ok"), in: sheet).press()
                try await RenderedUI.wait { window.attachedSheet == nil }
                model.whisperAPIKey = "fixture-key"
                try RenderedUI.button(L("onboarding.action.continue").uppercased(), in: host).press()
                try await RenderedUI.wait { model.currentStep == .llm }
                let reloaded = SettingsStore(defaults: settings.defaults)
                #expect(reloaded.sttProvider == .whisperAPI)
                #expect(reloaded.whisperBaseURL == "https://speech.example.test/v1")
                #expect(reloaded.whisperModel == "fixture-transcriber")
                #expect(reloaded.whisperAPIKey == "fixture-key")
            }
        }
    }

    @Test func `llm selection replaces the form and incomplete draft can be skipped`() async throws {
        try await RenderedUI.withFixture { settings in
            let model = OnboardingViewModel(settingsStore: settings, onComplete: {})
            model.currentStep = .llm
            model.selectLLMRemoteProvider(.openAI)
            model.llmAPIKey = ""
            try await RenderedUI
                .withWindow(OnboardingView(viewModel: model, appearanceMode: .dark), height: 1600) { window, host in
                    try await RenderedUI.wait { RenderedUI.contains(L("common.apiKey"), in: host) }
                    let ollama = try #require(RenderedUI.elements(in: host).first {
                        $0.role == NSAccessibility.Role.button.rawValue && $0.label
                            .hasPrefix(LLMProvider.ollama.displayName)
                    })
                    try ollama.press()
                    try await RenderedUI.wait { model.llmProvider == .ollama && RenderedUI.contains(
                        L("settings.models.ollama.baseURL"),
                        in: host
                    ) }
                    #expect(!RenderedUI.contains(L("common.apiKey"), in: host))
                    model.ollamaBaseURL = "http://127.0.0.1:11434"
                    model.ollamaModel = "fixture-local-model"
                    try RenderedUI.snapshot(host, name: "onboarding-local-llm")
                    model.selectLLMRemoteProvider(.openAI)
                    model.llmAPIKey = ""
                    try await RenderedUI.wait { RenderedUI.contains(L("common.apiKey"), in: host) }
                    try RenderedUI.button(L("onboarding.action.continue").uppercased(), in: host).press()
                    try await RenderedUI.wait { window.attachedSheet != nil }
                    #expect(model.currentStep == .llm)
                    #expect(model.showIncompleteLLMConfigurationAlert)
                    let sheet = try #require(window.attachedSheet)
                    try RenderedUI.button(L("onboarding.llmConfig.incompleteAlert.skip"), in: sheet).press()
                    try await RenderedUI.wait { model.currentStep == .permissions && window.attachedSheet == nil }
                    #expect(!model.showIncompleteLLMConfigurationAlert)
                    #expect(settings.llmRemoteProvider == .openAI)
                    #expect(!settings.isOnboardingCompleted)
                }
        }
    }

    @Test func `connection feedback shows loading failure notice and success without sending`() async throws {
        try await RenderedUI.withFixture { settings in
            let model = OnboardingViewModel(settingsStore: settings, onComplete: {})
            model.currentStep = .stt
            model.selectSTTProvider(.whisperAPI)
            try await RenderedUI.withWindow(OnboardingView(viewModel: model, appearanceMode: .dark)) { _, host in
                model.sttConnectionTestState = .testing
                try await RenderedUI.wait { RenderedUI.contains(L("settings.models.testingConnection"), in: host) }
                let loading = try #require(RenderedUI.elements(in: host).first {
                    $0.label == L("settings.models.testingConnection") && $0.role == "AXBusyIndicator"
                })
                #expect(loading.value("isAccessibilityEnabled") as? Bool == false)
                model.sttConnectionTestState = .failure(message: "Fixture connection failed")
                try await RenderedUI.wait { RenderedUI.contains("Fixture connection failed", in: host) }
                #expect(RenderedUI.contains(L("settings.models.testConnection"), in: host))
                model.sttConnectionTestState = .notice(message: "Fixture account required")
                try await RenderedUI.wait { RenderedUI.contains("Fixture account required", in: host) }
                #expect(!RenderedUI.contains("Fixture connection failed", in: host))
                model.sttConnectionTestState = .success(totalMs: 12, preview: "Fixture transcription")
                try await RenderedUI.wait { RenderedUI.contains("Fixture transcription", in: host) }
                #expect(!RenderedUI.contains("Fixture account required", in: host))
                #expect(!settings.isOnboardingCompleted)
                try RenderedUI.snapshot(host, name: "onboarding-connection-feedback")
            }
        }
    }

    @Test func `permission skip and finish use the rendered footer`() async throws {
        try await RenderedUI.withFixture { settings in
            var completions = 0
            let model = OnboardingViewModel(settingsStore: settings, globeKeyReader: ReadyGlobeKey(),
                                            onComplete: { completions += 1 })
            model.currentStep = .permissions
            model.permissions = [
                .init(id: .microphone, state: .needsAttention, detail: "Fixture missing microphone"),
                .init(id: .speechRecognition, state: .granted, detail: "Fixture speech ready"),
                .init(id: .accessibility, state: .granted, detail: "Fixture accessibility ready")
            ]
            try await RenderedUI.withWindow(OnboardingView(viewModel: model, appearanceMode: .light)) { window, host in
                try await RenderedUI.wait { RenderedUI.contains("Fixture missing microphone", in: host) }
                #expect(RenderedUI.contains("Fixture speech ready", in: host))
                try RenderedUI.snapshot(host, name: "onboarding-permissions")
                try RenderedUI.button(L("onboarding.action.skip").uppercased(), in: host).press()
                try await RenderedUI.wait { model.currentStep == .shortcuts }
                #expect(!settings.isOnboardingCompleted)
                #expect(completions == 0)
                try await RenderedUI
                    .wait { RenderedUI.contains(L("onboarding.action.getStarted").uppercased(), in: host) }
                let finish = try RenderedUI.button(L("onboarding.action.getStarted").uppercased(), in: host)
                #expect(window.frame.contains(finish.frame))
                try finish.press()
                try await RenderedUI.wait { settings.isOnboardingCompleted }
                #expect(SettingsStore(defaults: settings.defaults).isOnboardingCompleted)
                #expect(completions == 1)
            }
        }
    }
}

private struct ReadyGlobeKey: GlobeKeyPreferenceReading {
    func currentUsage() -> GlobeKeyUsage? {
        .doNothing
    }
}
