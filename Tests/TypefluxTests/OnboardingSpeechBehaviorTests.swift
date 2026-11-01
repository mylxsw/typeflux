import AppKit
import AVFoundation
import Combine
import SwiftUI
import Testing
@testable import Typeflux

extension OnboardingSpeechLLMTests {
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
            try await Controls.wait { model.canContinue == true }
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
            try await Controls.wait { model.isMicrophoneDenied }
            #expect(!model.canTest)
            model.audioAuthorizationProvider = { .authorized }
            model.refreshMicrophoneStatus()
            model.audioAuthorizationProvider = { .notDetermined }
            var permission: CheckedContinuation<Bool, Never>?
            model.requestMicrophoneAccess = { await withCheckedContinuation { permission = $0 } }
            model.startHoldToTalk()
            try await Controls.wait { permission != nil }
            model.stopHoldToTalk()
            permission?.resume(returning: true)
            try await Controls.wait { !model.isBusy }
            #expect(model.testStatus == .idle)
            #expect(!FileManager.default.fileExists(atPath: recorder.url.path))
            model.audioAuthorizationProvider = { .authorized }
            recorder.failsStart = true
            model.startHoldToTalk()
            try await Controls.wait {
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
            try await Controls.wait {
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
                    model.googleProjectID = "fixture-project"
                    model.isGoogleAuthorized = true
                }
                if model.canTest {
                    try await record(model)
                    try await Controls.wait { model.canContinue == true }
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
            try await Controls.wait { model.canContinue == true }
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
            try await Controls.wait { pending != nil }
            model.apiKey = "second"
            pending?.resume(returning: "stale")
            await Task.yield()
            #expect(model.testStatus == .idle)
            #expect(model.canContinue == false)
            pending = nil
            try await record(model)
            try await Controls.wait { pending != nil }
            session.confirmSkip(.speech)
            pending?.resume(returning: "stale")
            await Task.yield()
            #expect(session.currentStep == .llm)
            #expect(settings.onboardingSpeechDeferred)
            #expect(model.canContinue == false)
        }
    }

    @Test func `google runs authorization and reports failures without faking a grant`() async throws {
        try await fixture { _, session, _, _, _ in
            let model = session.speechModel
            model.selectProvider(.googleCloud)
            model.isGoogleAuthorized = false
            model.authorizeGoogle = { throw AskLocalError.message("OAuth cancelled") }
            model.authorizeGoogleCloud()
            try await Controls.wait { !model.isAuthorizingGoogle }
            #expect(!model.isGoogleAuthorized)
            model.authorizeGoogle = {}
            model.authorizeGoogleCloud()
            try await Controls.wait { model.isGoogleAuthorized }
            #expect(model.testStatus == .idle)
            #expect(!model.canTest)
            model.googleProjectID = " fixture-project "
            #expect(model.canTest)
            #expect(session.settingsStore.googleCloudProjectID == "fixture-project")
            model.googleProjectID = "  "
            #expect(!model.canTest)
        }
    }

    @Test func `download success failure cancellation and model switches retain the selected model`() async throws {
        try await fixture { settings, session, manager, _, _ in
            let model = session.speechModel
            manager.available = false
            model.startDownload()
            try await Controls.wait { !model.isDownloading }
            #expect(model.isLocalModelAvailable)
            let late = LocalSTTPreparationUpdate(message: "late", progress: 0.8, storagePath: "", source: nil)
            manager.update?(late)
            try await Task.sleep(for: .milliseconds(10))
            #expect(!model.isDownloading)
            manager.available = false
            manager.fails = true
            model.startDownload()
            try await Controls.wait {
                if case .failure = model.testStatus {
                    return true
                }; return false
            }
            #expect(!model.isDownloading)
            manager.update?(late)
            try await Task.sleep(for: .milliseconds(10))
            #expect(!model.isDownloading)
            manager.fails = false
            manager.suspended = true
            model.startDownload()
            try await Controls.wait { manager.pending != nil }
            manager.update?(.init(message: "progress", progress: 0.5, storagePath: "", source: nil))
            try await Controls.wait { model.downloadProgress == 0.5 }
            model.selectLocalModel(.funASR)
            manager.pending?.resume()
            try await Controls.wait { !model.isDownloading }
            #expect(settings.localSTTModel == .funASR)
            manager.pending = nil
            model.startDownload()
            try await Controls.wait { manager.pending != nil }
            model.cancelDownload()
            manager.pending?.resume()
            await Task.yield()
            #expect(!model.isDownloading)
            #expect(model.downloadProgress == 0)
        }
    }

    @Test func `Doubao resource edits persist restore defaults and invalidate recognition`() async throws {
        try await fixture { settings, session, _, _, _ in
            let model = session.speechModel
            #expect(Array(model.availableProviders.prefix(2)) == [.doubaoRealtime, .localModel])
            model.selectProvider(.doubaoRealtime)
            #expect(model.doubaoResourceID == DoubaoASRDefaults.resourceID)
            #expect(!model.canTest)
            model.doubaoAppID = " app "
            model.doubaoAccessToken = " token "
            model.doubaoResourceID = " volc.seedasr.sauc.concurrent "
            model.makeTranscriber = { provider in
                #expect(provider == .doubaoRealtime)
                #expect(settings.doubaoResourceID == "volc.seedasr.sauc.concurrent")
                return Engine()
            }
            try await record(model)
            try await Controls.wait { model.canContinue == true }
            model.doubaoResourceID = "volc.bigasr.sauc.duration"
            #expect(model.testStatus == .idle && model.canContinue == false)
            #expect(settings.doubaoResourceID == "volc.bigasr.sauc.duration")
            model.selectProvider(.localModel)
            model.selectProvider(.doubaoRealtime)
            #expect(model.doubaoResourceID == "volc.bigasr.sauc.duration")
            model.doubaoResourceID = "  "
            #expect(settings.doubaoResourceID == DoubaoASRDefaults.resourceID)
            let restored = OnboardingSpeechModel(session: session)
            #expect(restored.selectedProvider == .doubaoRealtime)
            #expect(restored.doubaoResourceID == DoubaoASRDefaults.resourceID)
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

    @Test func `first permission grant waits for a new hold and focus loss releases capture`() async throws {
        try await fixture { _, session, _, _, recorder in
            let model = session.speechModel
            model.audioAuthorizationProvider = { .notDetermined }
            model.requestMicrophoneAccess = { true }
            model.startHoldToTalk()
            try await Controls.wait { !model.isBusy }
            #expect(model.testStatus == .idle)
            #expect(!FileManager.default.fileExists(atPath: recorder.url.path))
            model.audioAuthorizationProvider = { .authorized }
            model.startHoldToTalk()
            try await Controls.wait { model.testStatus == .recording }
            model.cancelRecordingIfActive()
            #expect(recorder.stopped)
            #expect(model.testStatus == .idle)
            #expect(!FileManager.default.fileExists(atPath: recorder.url.path))
            #expect(!model.isBusy)
        }
    }

    @Test func `editing a Google project preserves authorization but leaving the page cancels it`() async throws {
        try await fixture { _, session, _, _, _ in
            let model = session.speechModel
            model.selectProvider(.googleCloud)
            model.isGoogleAuthorized = false
            var pending: CheckedContinuation<Void, Error>?
            model.authorizeGoogle = { try await withCheckedThrowingContinuation { pending = $0 } }
            model.authorizeGoogleCloud()
            try await Controls.wait { pending != nil }
            model.googleProjectID = "my-project-id"
            #expect(model.isAuthorizingGoogle)
            pending?.resume()
            pending = nil
            try await Controls.wait { model.isGoogleAuthorized }
            #expect(model.canTest)
            model.isGoogleAuthorized = false
            model.authorizeGoogleCloud()
            try await Controls.wait { pending != nil }
            session.goBack()
            pending?.resume()
            await Task.yield()
            #expect(!model.isGoogleAuthorized)
            #expect(!model.isAuthorizingGoogle)
        }
    }

    @Test func `cancelled scheduled work never opens a microphone or authorization prompt`() async throws {
        try await fixture { _, session, _, _, _ in
            let model = session.speechModel
            var microphonePrompts = 0
            model.audioAuthorizationProvider = { .notDetermined }
            model.requestMicrophoneAccess = { microphonePrompts += 1; return true }
            model.startHoldToTalk()
            model.cancelTest()
            model.selectProvider(.googleCloud)
            var authorizations = 0
            model.authorizeGoogle = { authorizations += 1 }
            model.authorizeGoogleCloud()
            session.goBack()
            try await Task.sleep(for: .milliseconds(10))
            #expect(microphonePrompts == 0)
            #expect(authorizations == 0)
        }
    }
}
