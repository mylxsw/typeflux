import AppKit
import AVFoundation
import Combine
import SwiftUI
import Testing
@testable import Typeflux

extension OnboardingSpeechLLMTests {
    @Test func `native pages cover provider configuration and result states in both languages and appearances`(
    ) async throws {
        for language in [AppLanguage.english, .simplifiedChinese] {
            for appearance in [AppearanceMode.light, .dark] {
                try await fixture { settings, session, manager, catalog, _ in
                    catalog.ollamaIDs = ["qwen2.5:7b", "llama3.1:8b"]
                    settings.appLanguage = language
                    AppLocalization.shared.setLanguage(language)
                    try await Controls.withWindow(OnboardingView(viewModel: session, appearanceMode: appearance),
                                            width: 960, height: 664, nativeWindow: true) { window, host in
                        window.appearance = AppAppearance.nsAppearance(for: appearance)
                        @MainActor func capture(_ name: String) async throws {
                            try await Task.sleep(for: .milliseconds(80))
                            try Controls.snapshot(host, name: "\(name)-\(language.rawValue)-\(appearance.rawValue)")
                        }
                        try await captureSpeech(session, manager: manager, host: host, capture: capture)
                        try await captureLLM(session, catalog: catalog, host: host, capture: capture)
                        catalog.fails = false
                        try await captureMenus(session, host: host,
                                               suffix: "\(language.rawValue)-\(appearance.rawValue)")
                    }
                }
            }
        }
    }
    private func captureSpeech(_ session: OnboardingViewModel, manager: Manager, host: NSView,
                               capture: @MainActor (String) async throws -> Void) async throws {
        let speech = session.speechModel
        try await Controls.wait { Controls.contains(
            OnboardingStrings.text("title", table: "OnboardingSpeech"),
            in: host
        ) }
        manager.available = false
        speech.objectWillChange.send()
        try await capture("speech-local")
        speech.isDownloading = true
        speech.downloadProgress = 0.42
        try await capture("speech-downloading")
        speech.isDownloading = false
        manager.available = true
        speech.isBusy = true
        speech.testStatus = .recording
        try await capture("speech-recording")
        speech.testStatus = .recognizing
        try await capture("speech-recognizing")
        speech.isBusy = false
        speech.testStatus = .success(
            preview: "Meeting tomorrow at 3 PM",
            latencyMs: 640
        )
        speech.canContinue = true
        try await capture("speech-success")
        speech.isMicrophoneDenied = true
        try await capture("speech-microphone-denied")
        speech.isMicrophoneDenied = false
        for provider in STTProvider.onboardingDisplayOrder {
            speech.selectProvider(provider)
            try await capture("speech-\(provider.rawValue)")
            if provider == .soniox {
                speech.apiKey = "fixture"
                speech.testStatus = .failure(message: OnboardingStrings.text(
                    "error.invalidKey",
                    table: "OnboardingSpeech"
                ))
                try await capture("speech-invalid-key")
            }
            if provider == .googleCloud {
                speech.isGoogleAuthorized = true
                speech.googleProjectID = ""
                try await capture("speech-google-missing-project")
                speech.googleProjectID = "my-project-id"
                try await capture("speech-google-authorized")
            }
        }
    }

    private func captureLLM(_ session: OnboardingViewModel, catalog: Catalog, host: NSView,
                            capture: @MainActor (String) async throws -> Void) async throws {
        session.currentStep = .llm
        let llm = session.llmModel
        try await Controls.wait { Controls.contains(
            OnboardingStrings.text("title", table: "OnboardingLlm"),
            in: host
        ) }
        try await capture("llm-free")
        llm.selectProvider(.remote(.openAI))
        try await Controls.wait { llm.validationStatus == .idle }
        try await capture("llm-key-empty")
        llm.validationDelay = 0.2
        llm.apiKey = "fixture"
        try await capture("llm-validating")
        try await Controls.wait { llm.validationStatus == .valid }
        try await capture("llm-connected")
        llm.isBusy = true
        llm.testStatus = .testing
        try await capture("llm-testing")
        llm.isBusy = false
        llm.testStatus = .success(
            preview: "Hello! I am ready to help.",
            latencyMs: 820
        )
        try await capture("llm-success")
        llm.validationStatus = .invalid(message: OnboardingStrings.text(
            "error.invalidKey",
            table: "OnboardingLlm"
        ))
        try await capture("llm-invalid-key")
        llm.validationStatus = .valid
        llm.testStatus = .failure(message: "Connection failed")
        try await capture("llm-failure")
        for provider in OnboardingLLMProvider.primaryOrder + OnboardingLLMProvider.moreProviders {
            llm.selectProvider(provider)
            try await Controls.wait { llm.validationStatus != .validating }
            try await capture("llm-\(provider.id)")
        }
        catalog.fails = true
        llm.selectProvider(.ollama)
        try await Controls.wait { !llm.isOllamaRunning }
        try await capture("llm-ollama-unavailable")
    }
}
