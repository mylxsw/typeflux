import AVFoundation
import Foundation
import Speech

protocol LiveTranscriptionPreviewing: AnyObject {
    func prepareForStart() async
    func start(onTextUpdate: @escaping @Sendable (String) -> Void) async throws
    func append(_ buffer: AVAudioPCMBuffer) async
    func finish() async -> String
    func cancel() async
}

protocol LivePreviewBackend: Actor {
    func start(onTextUpdate: @escaping @Sendable (String) -> Void) async throws
    func append(_ buffer: AVAudioPCMBuffer) async
    func finish() async -> String
    func cancel() async
}

actor LiveTranscriptionPreviewer: LiveTranscriptionPreviewing {
    private enum State {
        case idle
        case starting
        case running
    }

    private let settingsStore: SettingsStore
    private let localBackendFactory: () -> any LivePreviewBackend
    private let openAIBackendFactory: () -> any LivePreviewBackend
    private let appleBackendFactory: () -> any LivePreviewBackend
    private let canUseCloudASR: @Sendable () async -> Bool
    private var backend: (any LivePreviewBackend)?
    private var state: State = .idle
    private var pendingBuffers: [AVAudioPCMBuffer] = []

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        localBackendFactory = { UnavailableLivePreviewBackend(providerName: "Local model") }
        openAIBackendFactory = { OpenAIRealtimePreviewBackend(settingsStore: settingsStore) }
        appleBackendFactory = { AppleSpeechPreviewBackend() }
        canUseCloudASR = {
            await MainActor.run { AuthState.shared.canUseCloudASR }
        }
    }

    init(
        settingsStore: SettingsStore,
        localBackendFactory: @escaping () -> any LivePreviewBackend = {
            UnavailableLivePreviewBackend(providerName: "Local model")
        },
        openAIBackendFactory: @escaping () -> any LivePreviewBackend,
        appleBackendFactory: @escaping () -> any LivePreviewBackend,
        canUseCloudASR: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.settingsStore = settingsStore
        self.localBackendFactory = localBackendFactory
        self.openAIBackendFactory = openAIBackendFactory
        self.appleBackendFactory = appleBackendFactory
        self.canUseCloudASR = canUseCloudASR
    }

    func prepareForStart() {
        backend = nil
        state = .starting
        pendingBuffers = []
    }

    func start(onTextUpdate: @escaping @Sendable (String) -> Void) async throws {
        switch state {
        case .starting:
            await stopBackend(clearPendingBuffers: false)
        case .idle, .running:
            await stopBackend(clearPendingBuffers: true)
            state = .starting
        }

        var useLocalBackend = shouldUseLocalBackend
        if !useLocalBackend {
            useLocalBackend = !(await canUseCloudASR())
        }
        if useLocalBackend {
            let local = localBackendFactory()
            try await local.start(onTextUpdate: onTextUpdate)
            backend = local
            state = .running
            await flushPendingBuffers()
            return
        }

        if OpenAIRealtimePreviewBackend.isSupported(settingsStore: settingsStore) {
            do {
                let realtime = openAIBackendFactory()
                try await realtime.start(onTextUpdate: onTextUpdate)
                backend = realtime
                state = .running
                await flushPendingBuffers()
                return
            } catch {
                NetworkDebugLogger.logError(
                    context: "Realtime preview setup failed, falling back to Apple Speech",
                    error: error
                )
            }
        }

        let apple = appleBackendFactory()
        try await apple.start(onTextUpdate: onTextUpdate)
        backend = apple
        state = .running
        await flushPendingBuffers()
    }

    func append(_ buffer: AVAudioPCMBuffer) async {
        switch state {
        case .starting:
            if let copy = AudioPCMBufferSnapshot.copy(buffer) {
                pendingBuffers.append(copy)
            }
            return
        case .idle:
            return
        case .running:
            break
        }

        await backend?.append(buffer)
    }

    func finish() async -> String {
        defer {
            backend = nil
            state = .idle
            pendingBuffers = []
        }
        return await backend?.finish() ?? ""
    }

    func cancel() async {
        await stopBackend(clearPendingBuffers: true)
    }

    private func flushPendingBuffers() async {
        let buffers = pendingBuffers
        pendingBuffers = []
        for buffer in buffers {
            await append(buffer)
        }
    }

    private func stopBackend(clearPendingBuffers: Bool) async {
        await backend?.cancel()
        backend = nil
        state = .idle
        if clearPendingBuffers {
            pendingBuffers = []
        }
    }

    private var shouldUseLocalBackend: Bool {
        settingsStore.sttProvider == .localModel
    }
}

actor UnavailableLivePreviewBackend: LivePreviewBackend {
    private let providerName: String

    init(providerName: String) {
        self.providerName = providerName
    }

    func start(onTextUpdate _: @escaping @Sendable (String) -> Void) async throws {
        throw NSError(
            domain: "UnavailableLivePreviewBackend",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "\(providerName) live preview is not configured."]
        )
    }

    func append(_: AVAudioPCMBuffer) async {}

    func finish() async -> String {
        ""
    }

    func cancel() async {}
}

actor AppleSpeechPreviewBackend: LivePreviewBackend {
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latestText = ""
    private var onTextUpdate: (@Sendable (String) -> Void)?

    func start(onTextUpdate: @escaping @Sendable (String) -> Void) async throws {
        cancel()

        let authStatus = await MainActor.run { SFSpeechRecognizer.authorizationStatus() }
        guard authStatus == .authorized else {
            throw NSError(
                domain: "AppleSpeechPreviewBackend",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Speech recognition not authorized"]
            )
        }

        let recognizer = await MainActor.run {
            if let locale = TranscriptionLanguageHints.speechRecognizerLocale() {
                return SFSpeechRecognizer(locale: locale)
            }
            return SFSpeechRecognizer()
        }
        guard let recognizer else {
            throw NSError(
                domain: "AppleSpeechPreviewBackend",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Speech recognizer not available"]
            )
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }

        self.request = request
        self.onTextUpdate = onTextUpdate
        latestText = ""

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                Task {
                    await self.consume(result: result)
                }
            }

            if let error {
                NetworkDebugLogger.logError(context: "Apple Speech preview failed", error: error)
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    func finish() -> String {
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        onTextUpdate = nil
        return latestText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        task?.cancel()
        task = nil
        request = nil
        onTextUpdate = nil
        latestText = ""
    }

    private func consume(result: SFSpeechRecognitionResult) {
        let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != latestText else { return }
        latestText = text
        onTextUpdate?(text)
    }
}
