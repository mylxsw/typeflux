import AppKit
import SwiftUI
import Testing
@testable import Typeflux

extension OnboardingSpeechLLMTests {
    @Test func `native provider and test buttons drive the same persisted setup`() async throws {
        try await fixture { settings, session, manager, _, _ in
            try await Controls.withWindow(OnboardingView(viewModel: session, appearanceMode: .light),
                                          width: 960, height: 664) { _, host in
                let free = OnboardingStrings.text("provider.free.title", table: "OnboardingSpeech")
                try await Controls.wait { Controls.contains(free, in: host) }
                try Controls.button(free, in: host).press()
                #expect(session.speechModel.selectedProvider == .freeModel)
                #expect(settings.sttProvider == .freeModel)
                let local = OnboardingStrings.text("provider.local.title", table: "OnboardingSpeech")
                try Controls.button(local, in: host).press()
                manager.available = false
                session.speechModel.objectWillChange.send()
                let download = OnboardingStrings.text("local.download", table: "OnboardingSpeech")
                try await Controls.wait { Controls.contains(download, in: host) }
                try Controls.button(download, in: host).press()
                try await Controls.wait { manager.available }
                #expect(session.speechModel.canContinue == false)
                session.currentStep = .llm
                try await Controls.wait {
                    Controls.contains(OnboardingStrings.text("title", table: "OnboardingLlm"), in: host)
                        && !Controls.contains(OnboardingStrings.text("title", table: "OnboardingSpeech"), in: host)
                }
                let openAI = OnboardingStrings.text("provider.openai.title", table: "OnboardingLlm")
                try await Controls.wait { Controls.contains(openAI, in: host) }
                try Controls.button(openAI, in: host).press()
                #expect(session.llmModel.selectedProvider == .remote(.openAI))
                session.llmModel.apiKey = "fixture"
                try await Controls.wait { session.llmModel.validationStatus == .valid }
                let test = OnboardingStrings.text("action.testConnection", table: "OnboardingLlm")
                try await Controls.wait { Controls.contains(test, in: host) }
                try Controls.button(test, in: host).press()
                try await Controls.wait {
                    if case .success = session.llmModel.testStatus { return true }
                    return false
                }
                #expect(session.modelLibrary.registry.resolve(session.modelLibrary.rewriteReference) != nil)
            }
        }
    }
}

extension OnboardingSpeechLLMTests {
    private func nativeButtons(_ view: NSView) -> [NSPopUpButton] {
        (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(nativeButtons)
    }

    @Test func `native speech model menu persists the selected model`() async throws {
        try await fixture { settings, session, _, _, _ in
            session.speechModel.selectProvider(.localModel)
            try await Controls.withWindow(OnboardingView(viewModel: session, appearanceMode: .light),
                                          width: 960, height: 664) { _, host in
                try await Controls.wait { nativeButtons(host).contains {
                    $0.accessibilityIdentifier() == "onboarding.speech.model"
                } }
                let button = try #require(nativeButtons(host).first {
                    $0.accessibilityIdentifier() == "onboarding.speech.model"
                })
                let next = try #require(LocalSTTModel.displayOrder.first { $0 != session.speechModel.selectedLocalModel })
                let item = try #require(button.itemArray.first { $0.representedObject as? String == next.rawValue })
                button.select(item)
                #expect(NSApp.sendAction(try #require(button.action), to: button.target, from: button))
                #expect(settings.localSTTModel == next && session.speechModel.selectedLocalModel == next)
                #expect(button.bounds.width > 200, "The native hit target fills the editorial field")
            }
        }
    }

    @Test func `native LLM menu updates the registry and disables an empty catalog`() async throws {
        try await fixture { _, session, _, _, _ in
            session.currentStep = .llm
            let model = session.llmModel
            model.selectProvider(.remote(.openAI))
            model.apiKey = "fixture"
            try await Controls.wait { model.validationStatus == .valid }
            try await Controls.withWindow(OnboardingView(viewModel: session, appearanceMode: .light),
                                          width: 960, height: 664) { _, host in
                try await Controls.wait { nativeButtons(host).contains {
                    $0.accessibilityIdentifier() == "onboarding.llm.model"
                } }
                let button = try #require(nativeButtons(host).first {
                    $0.accessibilityIdentifier() == "onboarding.llm.model"
                })
                let next = try #require(model.availableModels.first { $0 != model.selectedModel })
                button.select(try #require(button.itemArray.first { $0.representedObject as? String == next }))
                #expect(NSApp.sendAction(try #require(button.action), to: button.target, from: button))
                #expect(model.selectedModel == next)
                #expect(session.modelLibrary.registry.resolve(session.modelLibrary.rewriteReference)?.1.id == next)
                model.selectProvider(.remote(.freeModel))
                try await Controls.wait { nativeButtons(host).contains {
                    $0.accessibilityIdentifier() == "onboarding.llm.model"
                        && !$0.isEnabled && $0.numberOfItems == 0
                } }
                let empty = try #require(nativeButtons(host).first {
                    $0.accessibilityIdentifier() == "onboarding.llm.model"
                })
                #expect(empty.selectedItem == nil && model.canContinue == false)
                let reference = session.modelLibrary.rewriteReference
                _ = NSApp.sendAction(try #require(empty.action), to: empty.target, from: empty)
                #expect(session.modelLibrary.rewriteReference == reference)
            }
        }
    }
}

extension OnboardingSpeechLLMTests {
    func captureMenus(_ session: OnboardingViewModel, host: NSView, suffix: String) async throws {
        session.currentStep = .speech
        session.speechModel.selectProvider(.localModel)
        try await Controls.wait {
            Controls.contains(OnboardingStrings.text("title", table: "OnboardingSpeech"), in: host)
                && !Controls.contains(OnboardingStrings.text("title", table: "OnboardingLlm"), in: host)
        }
        try await captureNativeMenu(in: host, identifier: "onboarding.speech.model", name: "speech-model-menu-\(suffix)")
        session.currentStep = .llm
        session.llmModel.selectProvider(.remote(.openAI))
        session.llmModel.apiKey = "fixture"
        try await Controls.wait { session.llmModel.validationStatus == .valid }
        try await Controls.wait {
            nativeButtons(host).contains { $0.accessibilityIdentifier() == "onboarding.llm.model" }
                && !nativeButtons(host).contains { $0.accessibilityIdentifier() == "onboarding.speech.model" }
        }
        try await captureNativeMenu(in: host, identifier: "onboarding.llm.model", name: "llm-model-menu-\(suffix)")
        try await captureNativeMenu(in: host, identifier: "onboarding.llm.moreProviders", name: "llm-more-menu-\(suffix)")
    }

    private func captureNativeMenu(in host: NSView, identifier: String, name: String) async throws {
        try await Controls.captureMenu(in: host, identifier: identifier, name: name)
    }

}
