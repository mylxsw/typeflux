import AppKit
import AVFoundation
import Combine
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct OnboardingSpeechLLMTests {
    private typealias UI = SettingsBehaviorTestSupport

    private final class Catalog: ProviderModelCatalog {
        var ids = ["gpt-4.1-mini", "gpt-4.1"]
        var fails = false
        var pending: CheckedContinuation<[RegisteredModel], Error>?
        var suspend = false
        var calls = 0
        func models(provider _: RegisteredProvider, connection _: SettingsStore.TextLLMConfiguration) async throws
            -> [RegisteredModel] {
            calls += 1
            if suspend {
                return try await withCheckedThrowingContinuation { pending = $0 }
            }
            if fails {
                throw AskLocalError.message("Invalid API Key")
            }
            return ids.map { RegisteredModel(id: $0, name: $0) }
        }
    }

    private final class Recorder: AudioRecorder, @unchecked Sendable {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        var failsStart = false
        var failsStop = false
        var stopped = false
        func start(
            levelHandler _: @escaping (Float) -> Void,
            audioBufferHandler _: ((AVAudioPCMBuffer) -> Void)?
        ) throws {
            if failsStart {
                throw AskLocalError.message("Recorder unavailable")
            }
            try Data([1, 2, 3]).write(to: url)
        }

        func stop() throws -> AudioFile {
            stopped = true
            if failsStop {
                try? FileManager.default.removeItem(at: url); throw AskLocalError.message("Stop failed")
            }
            return AudioFile(fileURL: url, duration: 1)
        }
    }

    private struct Engine: Transcriber {
        var run: (AudioFile) async throws -> String = { _ in "Meeting tomorrow at three" }
        func transcribe(audioFile: AudioFile) async throws -> String {
            try await run(audioFile)
        }
    }

    private final class Manager: LocalSTTModelManaging, @unchecked Sendable {
        var available = true
        var fails = false
        var suspended = false
        var pending: CheckedContinuation<Void, Error>?
        var update: (@Sendable (LocalSTTPreparationUpdate) -> Void)?
        func prepareModel(
            settingsStore _: SettingsStore,
            onUpdate: (@Sendable (LocalSTTPreparationUpdate) -> Void)?
        ) async throws {
            try await prepareModel(
                configuration: .init(model: .senseVoiceSmall, modelIdentifier: "",
                                     downloadSource: LocalSTTModel.senseVoiceSmall.recommendedDownloadSource,
                                     autoSetup: true),
                onUpdate: onUpdate
            )
        }

        func prepareModel(
            configuration _: LocalSTTConfiguration,
            onUpdate: (@Sendable (LocalSTTPreparationUpdate) -> Void)?
        ) async throws {
            update = onUpdate
            if suspended {
                try await withCheckedThrowingContinuation { pending = $0 }
            }
            if fails {
                throw AskLocalError.message("Download failed")
            }
            available = true
        }

        func preparedModelInfo(settingsStore _: SettingsStore) -> LocalSTTPreparedModelInfo? {
            nil
        }

        func isModelAvailable(_: LocalSTTModel) -> Bool {
            available
        }

        func deleteModelFiles(_: LocalSTTModel) throws {}
        func storagePath(for _: LocalSTTConfiguration) -> String {
            "/tmp/onboarding-fixture"
        }
    }

    private struct Globe: GlobeKeyPreferenceReading {
        func currentUsage() -> GlobeKeyUsage? {
            .doNothing
        }
    }

    private func fixture(_ check: (SettingsStore, OnboardingViewModel, Manager, Catalog, Recorder) async throws
        -> Void) async throws {
        try await UI.withFixture { settings in
            LocalModelDownloadProgressCenter.shared.clear()
            let manager = Manager()
            let catalog = Catalog()
            let recorder = Recorder()
            let library = AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
            let session = OnboardingViewModel(settingsStore: settings, modelLibrary: library,
                                              globeKeyReader: Globe(), localModelManager: manager, onComplete: {})
            session.llmModel = OnboardingLLMModel(session: session, catalog: catalog)
            session.llmModel.objectWillChange.sink { [weak session] in
                session?.objectWillChange.send()
            }.store(in: &session.pageSubscriptions)
            session.llmModel.validationDelay = 0
            session.llmModel.connectionProbe = { _, _ in "Ready to help" }
            session.speechModel.makeRecorder = { recorder }
            session.speechModel.makeTranscriber = { _ in Engine() }
            session.speechModel.audioAuthorizationProvider = { .authorized }
            session.chooseRoute(.custom)
            session.currentStep = .speech
            defer {
                session.speechModel.cancelTest()
                session.speechModel.cancelDownload()
                session.llmModel.cancelPendingWork()
                try? FileManager.default.removeItem(at: recorder.url)
                LocalModelDownloadProgressCenter.shared.clear()
            }
            try await check(settings, session, manager, catalog, recorder)
        }
    }

    private func record(_ model: OnboardingSpeechModel) async throws {
        model.startHoldToTalk()
        try await UI.wait { model.testStatus == .recording }
        model.stopHoldToTalk()
    }

    @Test func `speech records the held audio and only success enables continuation`() async throws {
        try await fixture { settings, session, _, _, recorder in
            let model = session.speechModel
            settings.onboardingSpeechDeferred = true
            model.makeTranscriber = { _ in Engine(run: { audio in
                #expect(audio.fileURL == recorder.url)
                #expect(FileManager.default.fileExists(atPath: audio.fileURL.path))
                return "Actual audio reached the recognizer"
            }) }
            #expect(!session.canAdvance)
            try await record(model)
            try await UI.wait { model.canContinue == true }
            #expect(recorder.stopped)
            #expect(!FileManager.default.fileExists(atPath: recorder.url.path))
            #expect(!settings.onboardingSpeechDeferred)
            #expect(!model.isBusy)
            #expect(session.canAdvance)
            session.advance()
            #expect(session.currentStep == .llm)
        }
    }

    @Test func `permission release denial recorder failures and empty recognition stay inline`() async throws {
        try await fixture { _, session, _, _, recorder in
            let model = session.speechModel
            model.audioAuthorizationProvider = { .denied }
            model.startHoldToTalk()
            try await UI.wait { model.isMicrophoneDenied }
            #expect(!model.canTest)
            model.audioAuthorizationProvider = { .authorized }
            model.refreshMicrophoneStatus()
            model.audioAuthorizationProvider = { .notDetermined }
            var permission: CheckedContinuation<Bool, Never>?
            model.requestMicrophoneAccess = { await withCheckedContinuation { permission = $0 } }
            model.startHoldToTalk()
            try await UI.wait { permission != nil }
            model.stopHoldToTalk()
            permission?.resume(returning: true)
            try await UI.wait { !model.isBusy }
            #expect(model.testStatus == .idle)
            #expect(!FileManager.default.fileExists(atPath: recorder.url.path))
            model.audioAuthorizationProvider = { .authorized }
            recorder.failsStart = true
            model.startHoldToTalk()
            try await UI.wait {
                if case .failure = model.testStatus {
                    return true
                }; return false
            }
            #expect(model.canContinue == false)
            recorder.failsStart = false
            recorder.failsStop = true
            try await record(model)
            #expect(!model.isBusy)
            recorder.failsStop = false
            model.makeTranscriber = { _ in Engine(run: { _ in "" }) }
            try await record(model)
            try await UI.wait {
                if case .failure = model.testStatus {
                    return true
                }; return false
            }
            #expect(model.canContinue == false)
        }
    }

    @Test func `speech credentials use the right fields and invalidate successful tests`() async throws {
        try await fixture { settings, session, _, _, _ in
            let model = session.speechModel
            for provider in STTProvider.onboardingDisplayOrder {
                model.selectProvider(provider)
                model.apiKey = " key "
                if provider == .doubaoRealtime {
                    model.doubaoAppID = " app "
                    model.doubaoAccessToken = " token "
                }
                model.commitCredentials()
                if [.aliCloud, .groq, .soniox, .whisperAPI, .doubaoRealtime].contains(provider) {
                    #expect(model.apiKeyHelpURL != nil)
                    #expect(model.canTest)
                }
                if provider == .googleCloud {
                    model.isGoogleAuthorized = true
                }
                if model.canTest {
                    try await record(model)
                    try await UI.wait { model.canContinue == true }
                }
            }
            #expect(settings.aliCloudAPIKey == "key")
            #expect(settings.groqSTTAPIKey == "key")
            #expect(settings.sonioxAPIKey == "key")
            #expect(settings.whisperAPIKey == "key")
            #expect(settings.doubaoAppID == "app")
            #expect(settings.doubaoAccessToken == "token")
            model.selectProvider(.soniox)
            try await record(model)
            try await UI.wait { model.canContinue == true }
            model.apiKey = "changed"
            #expect(model.canContinue == false)
            #expect(model.testStatus == .idle)
            model.selectProvider(.whisperAPI)
            model.whisperBaseURL = "https://example.com/v1"
            #expect(settings.whisperBaseURL == "https://example.com/v1")
            model.selectLocalModel(.funASR)
            #expect(settings.localSTTModel == .funASR)
        }
    }

    @Test func `late speech results cannot verify changed credentials or navigate after skip`() async throws {
        try await fixture { settings, session, _, _, _ in
            let model = session.speechModel
            var pending: CheckedContinuation<String, Error>?
            model
                .makeTranscriber = { _ in Engine(run: { _ in
                    try await withCheckedThrowingContinuation { pending = $0 }
                }) }
            model.selectProvider(.soniox)
            model.apiKey = "first"
            try await record(model)
            try await UI.wait { pending != nil }
            model.apiKey = "second"
            pending?.resume(returning: "stale")
            await Task.yield()
            #expect(model.testStatus == .idle)
            #expect(model.canContinue == false)
            pending = nil
            try await record(model)
            try await UI.wait { pending != nil }
            session.confirmSkip(.speech)
            pending?.resume(returning: "stale")
            await Task.yield()
            #expect(session.currentStep == .llm)
            #expect(settings.onboardingSpeechDeferred)
            #expect(model.canContinue == false)
        }
    }

    @Test func `Google runs authorization and reports failures without faking a grant`() async throws {
        try await fixture { _, session, _, _, _ in
            let model = session.speechModel
            model.selectProvider(.googleCloud)
            model.isGoogleAuthorized = false
            model.authorizeGoogle = { throw AskLocalError.message("OAuth cancelled") }
            model.authorizeGoogleCloud()
            try await UI.wait { !model.isAuthorizingGoogle }
            #expect(!model.isGoogleAuthorized)
            model.authorizeGoogle = {}
            model.authorizeGoogleCloud()
            try await UI.wait { model.isGoogleAuthorized }
            #expect(model.canTest)
        }
    }

    @Test func `download success failure cancellation and model switches retain the selected model`() async throws {
        try await fixture { settings, session, manager, _, _ in
            let model = session.speechModel
            manager.available = false
            model.startDownload()
            try await UI.wait { !model.isDownloading }
            #expect(model.isLocalModelAvailable)
            manager.available = false
            manager.fails = true
            model.startDownload()
            try await UI.wait {
                if case .failure = model.testStatus {
                    return true
                }; return false
            }
            #expect(!model.isDownloading)
            manager.fails = false
            manager.suspended = true
            model.startDownload()
            try await UI.wait { manager.pending != nil }
            model.selectLocalModel(.funASR)
            manager.pending?.resume()
            try await UI.wait { !model.isDownloading }
            #expect(settings.localSTTModel == .funASR)
            manager.pending = nil
            model.startDownload()
            try await UI.wait { manager.pending != nil }
            model.cancelDownload()
            manager.pending?.resume()
            await Task.yield()
            #expect(!model.isDownloading)
            #expect(model.downloadProgress == 0)
        }
    }

    @Test func `engines preserve the selected provider without fallback`() async throws {
        try await fixture { settings, _, manager, _, _ in
            #expect(ModelProviderIcon.image(for: .googleCloud) != nil)
            #expect(ModelProviderIcon.image(for: .soniox) != nil)
            for provider in STTProvider.allCases {
                let engine = OnboardingSpeechTranscriber.make(provider, settings: settings, manager: manager)
                #expect(!(engine is STTRouter))
            }
        }
    }

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
            try await UI.wait { model.validationStatus == .valid }
            #expect(catalog.calls == 1)
            #expect(model.canContinue == true)
            #expect(settings.llmAPIKey(for: .openAI) == "key")
            #expect(session.modelLibrary.registry.resolve(session.modelLibrary.rewriteReference)?.1.id == model
                .selectedModel)
            model.selectModel("gpt-4.1")
            #expect(settings.llmModel(for: .openAI) == "gpt-4.1")
            model.testConnection()
            try await UI.wait {
                if case .success = model.testStatus {
                    return true
                }; return false
            }
            #expect(!model.isBusy)
            model.onKeyChange("")
            try await UI.wait { model.validationStatus == .idle }
            #expect(model.canContinue == false)
        }
    }

    @Test func `LLM validation errors empty catalogs and Ollama retry never invent models`() async throws {
        try await fixture { settings, session, _, catalog, _ in
            let model = session.llmModel
            session.currentStep = .llm
            catalog.fails = true
            model.selectProvider(.ollama)
            try await UI.wait { !model.isOllamaRunning }
            #expect(model.canContinue == false)
            catalog.fails = false
            catalog.ids = []
            model.checkOllama()
            try await UI.wait {
                if case .invalid = model.validationStatus {
                    return true
                }; return false
            }
            #expect(model.availableModels.isEmpty)
            catalog.ids = ["qwen2.5:7b"]
            model.checkOllama()
            try await UI.wait { model.validationStatus == .valid }
            #expect(settings.ollamaModel == "qwen2.5:7b")
            #expect(session.modelLibrary.registry.resolve(session.modelLibrary.rewriteReference)?.0.isOllama == true)
            model.connectionProbe = { _, _ in throw AskLocalError.message("Connection failed") }
            model.testConnection()
            try await UI.wait {
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
            try await UI.wait { catalog.pending != nil }
            let pending = catalog.pending
            catalog.pending = nil
            model.apiKey = "second"
            pending?.resume(returning: [.init(id: "stale", name: "stale")])
            try await UI.wait { catalog.pending != nil }
            catalog.pending?.resume(returning: [.init(id: "real", name: "real"), .init(id: "other", name: "other")])
            catalog.pending = nil
            try await UI.wait { model.validationStatus == .valid }
            #expect(!model.availableModels.contains("stale"))
            #expect(settings.llmBaseURL(for: .custom) == "https://example.com/v1")
            var probe: CheckedContinuation<String, Error>?
            model.connectionProbe = { _, _ in try await withCheckedThrowingContinuation { probe = $0 } }
            model.testConnection()
            try await UI.wait { probe != nil }
            model.selectModel("other")
            probe?.resume(returning: "stale")
            await Task.yield()
            #expect(model.testStatus == .idle)
            probe = nil
            model.testConnection()
            try await UI.wait { probe != nil }
            session.goBack()
            probe?.resume(returning: "stale")
            await Task.yield()
            #expect(model.testStatus == .idle)
            #expect(session.currentStep == .speech)
        }
    }

    @Test func `free LLM uses the injected connection probe and preserves a resolvable selection`() async throws {
        try await fixture { _, session, _, _, _ in
            let model = session.llmModel
            session.currentStep = .llm
            model.activate()
            #expect(model.canContinue == true)
            #expect(session.languageConfigured)
            model.testConnection()
            try await UI.wait {
                if case .success = model.testStatus {
                    return true
                }; return false
            }
            #expect(session.modelLibrary.registry.resolve(session.modelLibrary.defaultReference) != nil)
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
            try await UI.wait { model.validationStatus == .valid }
            #expect(library.rewriteReference == profile.reference)
            #expect(model.connectionConfiguration().0.id.hasPrefix("endpoint:"))
            model.selectProvider(.remote(.freeModel))
            model.selectProvider(.remote(.custom))
            try await UI.wait { model.validationStatus == .valid }
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
                try await UI.wait { model.validationStatus == .valid }
                #expect(session.modelLibrary.registry.resolve(session.modelLibrary.rewriteReference)?.0
                    .remote == provider)
                _ = model.apiKeyHelpURL
            }
            catalog.fails = true
            model.apiKey = "invalid"
            try await UI.wait {
                if case .invalid = model.validationStatus {
                    return true
                }; return false
            }
            #expect(model.canContinue == false)
            model.selectProvider(.remote(.freeModel))
            model.connectionProbe = { _, _ in "  " }
            model.testConnection()
            try await UI.wait {
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
            try await UI.wait { speechReply != nil }
            settings.sonioxAPIKey = "external-change"
            speechReply?.resume(returning: "outdated")
            try await UI.wait { !speech.isBusy }
            #expect(speech.canContinue == false)
            #expect(speech.testStatus == .idle)
            session.currentStep = .llm
            let llm = session.llmModel
            llm.selectProvider(.remote(.openAI))
            llm.apiKey = "first"
            try await UI.wait { llm.validationStatus == .valid }
            var llmReply: CheckedContinuation<String, Error>?
            llm.connectionProbe = { _, _ in try await withCheckedThrowingContinuation { llmReply = $0 } }
            llm.testConnection()
            try await UI.wait { llmReply != nil }
            settings.setLLMAPIKey("external-change", for: .openAI)
            llmReply?.resume(returning: "outdated")
            try await UI.wait { !llm.isBusy }
            #expect(llm.testStatus == .idle)
        }
    }

    @Test func `native pages cover provider configuration and result states in both languages and appearances`(
    ) async throws {
        for language in [AppLanguage.english, .simplifiedChinese] {
            for appearance in [AppearanceMode.light, .dark] {
                try await fixture { settings, session, manager, catalog, _ in
                    settings.appLanguage = language
                    AppLocalization.shared.setLanguage(language)
                    try await UI.withWindow(OnboardingView(viewModel: session, appearanceMode: appearance),
                                            width: 960, height: 664) { _, host in
                        func capture(_ name: String) async throws {
                            try await Task.sleep(for: .milliseconds(80))
                            try UI.snapshot(host, name: "\(name)-\(language.rawValue)-\(appearance.rawValue)")
                        }
                        let speech = session.speechModel
                        try await UI.wait { UI.contains(
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
                        speech.testStatus = .recording
                        try await capture("speech-recording")
                        speech.testStatus = .recognizing
                        try await capture("speech-recognizing")
                        speech.testStatus = .success(
                            preview: OnboardingStrings.text("status.samplePreview", table: "OnboardingSpeech"),
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
                                try await capture("speech-google-authorized")
                            }
                        }
                        session.currentStep = .llm
                        let llm = session.llmModel
                        try await UI.wait { UI.contains(
                            OnboardingStrings.text("title", table: "OnboardingLlm"),
                            in: host
                        ) }
                        try await capture("llm-free")
                        llm.selectProvider(.remote(.openAI))
                        try await UI.wait { llm.validationStatus == .idle }
                        try await capture("llm-key-empty")
                        llm.validationDelay = 0.2
                        llm.apiKey = "fixture"
                        try await capture("llm-validating")
                        try await UI.wait { llm.validationStatus == .valid }
                        try await capture("llm-connected")
                        llm.testStatus = .testing
                        try await capture("llm-testing")
                        llm.testStatus = .success(
                            preview: OnboardingStrings.text("status.sampleReply", table: "OnboardingLlm"),
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
                            try await capture("llm-\(provider.id)")
                        }
                        catalog.fails = true
                        llm.selectProvider(.ollama)
                        try await UI.wait { !llm.isOllamaRunning }
                        try await capture("llm-ollama-unavailable")
                    }
                }
            }
        }
    }
}
