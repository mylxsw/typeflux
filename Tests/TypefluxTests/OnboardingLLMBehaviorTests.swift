import AppKit
import AVFoundation
import Combine
import SwiftUI
import Testing
@testable import Typeflux

extension OnboardingSpeechLLMTests {
    @Test func `LLM has every remaining provider and validates before committing real registry references`(
    ) async throws {
        try await fixture { settings, session, _, catalog, _ in
            let model = session.llmModel
            #expect(Set(OnboardingLLMProvider.primaryOrder + OnboardingLLMProvider.moreProviders)
                ==
                Set(LLMRemoteProvider.allCases.filter { $0 != .typefluxCloud }
                    .map { OnboardingLLMProvider.remote($0) } + [.ollama]))
            #expect(settings.defaults.object(forKey: "llm.remote.provider") == nil)
            session.currentStep = .llm
            model.selectProvider(.remote(.openAI))
            model.onKeyChange(" key ")
            try await Controls.wait { model.validationStatus == .valid }
            #expect(catalog.calls == 1)
            #expect(model.canContinue == true)
            #expect(settings.llmAPIKey(for: .openAI) == "key")
            #expect(session.modelLibrary.registry.resolve(session.modelLibrary.rewriteReference)?.1.id == model
                .selectedModel)
            model.selectModel("gpt-4.1")
            #expect(settings.llmModel(for: .openAI) == "gpt-4.1")
            model.testConnection()
            try await Controls.wait {
                if case .success = model.testStatus {
                    return true
                }; return false
            }
            #expect(!model.isBusy)
            model.onKeyChange("")
            try await Controls.wait { model.validationStatus == .idle }
            #expect(model.canContinue == false)
        }
    }

    @Test func `LLM validation errors empty catalogs and Ollama retry never invent models`() async throws {
        try await fixture { settings, session, _, catalog, _ in
            let model = session.llmModel
            session.currentStep = .llm
            catalog.fails = true
            model.selectProvider(.ollama)
            try await Controls.wait { !model.isOllamaRunning }
            #expect(model.canContinue == false)
            catalog.fails = false
            catalog.ids = []
            model.checkOllama()
            try await Controls.wait {
                if case .invalid = model.validationStatus {
                    return true
                }; return false
            }
            #expect(model.availableModels.isEmpty)
            catalog.ids = ["qwen2.5:7b"]
            model.checkOllama()
            try await Controls.wait { model.validationStatus == .valid }
            #expect(settings.ollamaModel == "qwen2.5:7b")
            #expect(session.modelLibrary.registry.resolve(session.modelLibrary.rewriteReference)?.0.isOllama == true)
            model.connectionProbe = { _, _ in throw AskLocalError.message("Connection failed") }
            model.testConnection()
            try await Controls.wait {
                if case .failure = model.testStatus {
                    return true
                }; return false
            }
            #expect(!model.isBusy)
        }
    }

    @Test func `LLM rejects stale catalogs and probes after key endpoint model and route changes`() async throws {
        try await fixture { settings, session, _, catalog, _ in
            let model = session.llmModel
            session.currentStep = .llm
            catalog.suspend = true
            model.selectProvider(.remote(.custom))
            model.customBaseURL = "https://example.com/v1"
            model.apiKey = "first"
            try await Controls.wait { catalog.pending != nil }
            let pending = catalog.pending
            catalog.pending = nil
            model.apiKey = "second"
            pending?.resume(returning: [.init(id: "stale", name: "stale")])
            try await Controls.wait { catalog.pending != nil }
            catalog.pending?.resume(returning: [.init(id: "real", name: "real"), .init(id: "other", name: "other")])
            catalog.pending = nil
            try await Controls.wait { model.validationStatus == .valid }
            #expect(!model.availableModels.contains("stale"))
            #expect(settings.llmBaseURL(for: .custom) == "https://example.com/v1")
            var probe: CheckedContinuation<String, Error>?
            model.connectionProbe = { _, _ in try await withCheckedThrowingContinuation { probe = $0 } }
            model.testConnection()
            try await Controls.wait { probe != nil }
            model.selectModel("other")
            probe?.resume(returning: "stale")
            await Task.yield()
            #expect(model.testStatus == .idle)
            probe = nil
            model.testConnection()
            try await Controls.wait { probe != nil }
            session.goBack()
            probe?.resume(returning: "stale")
            await Task.yield()
            #expect(model.testStatus == .idle)
            #expect(session.currentStep == .speech)
        }
    }

    @Test func `empty free LLM catalog falls back to a visible provider without committing or probing`() async throws {
        try await fixture { _, session, _, _, _ in
            let model = session.llmModel
            let previousDefault = session.modelLibrary.defaultReference
            session.currentStep = .llm
            #expect(!model.availablePrimaryProviders.contains(.remote(.freeModel)))
            #expect(model.selectedProvider == .remote(.openAI))
            model.selectProvider(.remote(.freeModel))
            #expect(model.selectedProvider == .remote(.openAI))
            model.activate()
            try await Controls.wait { !model.isBusy }
            #expect(model.availableModels.isEmpty)
            #expect(model.canContinue == false)
            #expect(!session.languageConfigured)
            #expect(model.validationStatus == .idle)
            var probes = 0
            model.connectionProbe = { _, _ in probes += 1; return "Unexpected" }
            model.testConnection()
            await Task.yield()
            #expect(probes == 0 && model.testStatus == .idle)
            #expect(session.modelLibrary.defaultReference == previousDefault)
        }
    }

    @Test func `saved empty free providers fall back without overwriting stored settings`() async throws {
        try await fixture { settings, session, _, catalog, _ in
            settings.sttProvider = .freeModel
            settings.llmRemoteProvider = .freeModel
            let speech = OnboardingSpeechModel(session: session)
            #expect(!speech.availableProviders.contains(.freeModel))
            #expect(speech.selectedProvider == .localModel)
            speech.selectProvider(.freeModel)
            #expect(speech.selectedProvider == .localModel)
            #expect(settings.sttProvider == .freeModel)
            let llm = OnboardingLLMModel(session: session, catalog: catalog)
            #expect(llm.selectedProvider == .remote(.openAI))
            #expect(llm.availablePrimaryProviders.contains(llm.selectedProvider))
            #expect(settings.llmRemoteProvider == .freeModel)
            llm.cancelPendingWork()
        }
    }

    @Test func `existing endpoint and Ollama selections survive initialization and provider changes`() async throws {
        try await fixture { settings, session, _, catalog, _ in
            let library = session.modelLibrary
            let profile = AskModelProfile(
                id: "existing",
                name: "Existing",
                baseURL: "http://localhost:1234/v1",
                model: "gpt-4.1"
            )
            try library.save(profile, key: "")
            library.rewriteReference = profile.reference
            let model = OnboardingLLMModel(session: session, catalog: catalog)
            model.validationDelay = 0
            #expect(model.customBaseURL == profile.baseURL)
            model.activate()
            try await Controls.wait { model.validationStatus == .valid }
            #expect(library.rewriteReference == profile.reference)
            #expect(model.connectionConfiguration().0.id.hasPrefix("endpoint:"))
            model.selectProvider(.remote(.anthropic))
            model.selectProvider(.remote(.custom))
            try await Controls.wait { model.validationStatus == .valid }
            #expect(model.customBaseURL == profile.baseURL)
            model.cancelPendingWork()
            settings.llmProvider = .ollama
            library.rewriteReference = ""
            let ollama = OnboardingLLMModel(session: session, catalog: catalog)
            #expect(ollama.selectedProvider == .ollama)
            ollama.cancelPendingWork()
        }
    }

    @Test func `every remote provider can commit a fetched model and errors block verification`() async throws {
        try await fixture { _, session, _, catalog, _ in
            session.currentStep = .llm
            let model = session.llmModel
            for provider in LLMRemoteProvider.allCases where provider != .typefluxCloud && provider != .freeModel {
                model.selectProvider(.remote(provider))
                model.customBaseURL = provider.defaultBaseURL.isEmpty ? "https://example.com/v1" : provider
                    .defaultBaseURL
                model.apiKey = "fixture"
                try await Controls.wait { model.validationStatus == .valid }
                #expect(session.modelLibrary.registry.resolve(session.modelLibrary.rewriteReference)?.0
                    .remote == provider)
                _ = model.apiKeyHelpURL
            }
            catalog.fails = true
            model.apiKey = "invalid"
            try await Controls.wait {
                if case .invalid = model.validationStatus {
                    return true
                }; return false
            }
            #expect(model.canContinue == false)
            catalog.fails = false
            model.selectProvider(.remote(.openAI))
            model.apiKey = "fixture"
            try await Controls.wait { model.validationStatus == .valid }
            model.connectionProbe = { _, _ in "  " }
            model.testConnection()
            try await Controls.wait {
                if case .failure = model.testStatus {
                    return true
                }; return false
            }
            #expect(!model.isBusy)
        }
    }

    @Test func `external configuration changes invalidate in flight speech and LLM signatures`() async throws {
        try await fixture { settings, session, _, _, _ in
            let speech = session.speechModel
            speech.selectProvider(.soniox)
            speech.apiKey = "first"
            var speechReply: CheckedContinuation<String, Error>?
            speech
                .makeTranscriber = { _ in Engine(run: { _ in
                    try await withCheckedThrowingContinuation { speechReply = $0 }
                }) }
            try await record(speech)
            try await Controls.wait { speechReply != nil }
            settings.sonioxAPIKey = "external-change"
            speechReply?.resume(returning: "outdated")
            try await Controls.wait { !speech.isBusy }
            #expect(speech.canContinue == false)
            #expect(speech.testStatus == .idle)
            session.currentStep = .llm
            let llm = session.llmModel
            llm.selectProvider(.remote(.openAI))
            llm.apiKey = "first"
            try await Controls.wait { llm.validationStatus == .valid }
            var llmReply: CheckedContinuation<String, Error>?
            llm.connectionProbe = { _, _ in try await withCheckedThrowingContinuation { llmReply = $0 } }
            llm.testConnection()
            try await Controls.wait { llmReply != nil }
            settings.setLLMAPIKey("external-change", for: .openAI)
            llmReply?.resume(returning: "outdated")
            try await Controls.wait { !llm.isBusy }
            #expect(llm.testStatus == .idle)
        }
    }

    @Test func `multimodal speech follows the next step model and becomes testable on return`() async throws {
        try await fixture { settings, session, _, _, _ in
            let speech = session.speechModel
            speech.selectProvider(.multimodalLLM)
            #expect(!speech.canTest)
            session.confirmSkip(.speech)
            let llm = session.llmModel
            llm.selectProvider(.remote(.openAI))
            llm.apiKey = "fixture"
            try await Controls.wait { llm.validationStatus == .valid }
            #expect(settings.multimodalLLMModel == llm.selectedModel)
            #expect(settings.multimodalLLMBaseURL == settings.llmBaseURL(for: .openAI))
            #expect(settings.multimodalLLMAPIKey == "fixture")
            session.goBack()
            #expect(speech.canTest)
            try await record(speech)
            try await Controls.wait { speech.canContinue == true }
            #expect(!settings.onboardingSpeechDeferred)
            session.advance()
            llm.selectProvider(.ollama)
            try await Controls.wait { llm.validationStatus == .valid }
            #expect(settings.multimodalLLMBaseURL.hasSuffix("/v1"))
            #expect(settings.multimodalLLMAPIKey.isEmpty)
        }
    }
}
