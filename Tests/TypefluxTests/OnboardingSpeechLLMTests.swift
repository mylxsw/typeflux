import AppKit
import AVFoundation
import Combine
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct OnboardingSpeechLLMTests {
    typealias Controls = SettingsBehaviorTestSupport

    @MainActor
    final class Catalog: ProviderModelCatalog {
        var ids = ["gpt-4.1-mini", "gpt-4.1"]
        var fails = false
        var ollamaIDs: [String]?
        var pending: CheckedContinuation<[RegisteredModel], Error>?
        var suspend = false
        var calls = 0
        func models(provider: RegisteredProvider, connection _: SettingsStore.TextLLMConfiguration) async throws
            -> [RegisteredModel] {
            calls += 1
            if suspend {
                return try await withCheckedThrowingContinuation { pending = $0 }
            }
            if fails {
                throw AskLocalError.message("Invalid API Key")
            }
            return (provider.isOllama ? ollamaIDs ?? ids : ids).map { RegisteredModel(id: $0, name: $0) }
        }
    }

    final class Recorder: AudioRecorder, @unchecked Sendable {
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

    struct Engine: Transcriber {
        var run: (AudioFile) async throws -> String = { _ in "Meeting tomorrow at three" }
        @MainActor
        func transcribe(audioFile: AudioFile) async throws -> String {
            try await run(audioFile)
        }
    }

    final class Manager: LocalSTTModelManaging, @unchecked Sendable {
        var available = true
        var fails = false
        var suspended = false
        var pending: CheckedContinuation<Void, Error>?
        var update: (@Sendable (LocalSTTPreparationUpdate) -> Void)?
        @MainActor
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

        @MainActor
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

    struct Globe: GlobeKeyPreferenceReading {
        func currentUsage() -> GlobeKeyUsage? {
            .doNothing
        }
    }

    func fixture(_ check: (SettingsStore, OnboardingViewModel, Manager, Catalog, Recorder) async throws
        -> Void) async throws {
        try await Controls.withFixture { settings in
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
            session.speechModel.refreshMicrophoneStatus()
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

    func record(_ model: OnboardingSpeechModel) async throws {
        model.startHoldToTalk()
        try await Controls.wait { model.testStatus == .recording }
        model.stopHoldToTalk()
    }

}
