import AVFoundation
import Foundation
import Speech

protocol LivePreviewBackend: Actor {
    func start(onTextUpdate: @escaping @Sendable (String) -> Void) async throws
    func append(_ buffer: AVAudioPCMBuffer) async
    func finish() async -> String
    func cancel() async
}

actor LiveTranscriptionPreviewer {
    private enum State {
        case idle
        case starting
        case running
    }

    private let settingsStore: SettingsStore
    private let openAIBackendFactory: @Sendable () -> any LivePreviewBackend
    private let appleBackendFactory: @Sendable () -> any LivePreviewBackend
    private var backend: (any LivePreviewBackend)?
    private var state: State = .idle
    private var pendingBuffers: [AVAudioPCMBuffer] = []

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        self.openAIBackendFactory = { OpenAIRealtimePreviewBackend(settingsStore: settingsStore) }
        self.appleBackendFactory = { AppleSpeechPreviewBackend() }
    }

    init(
        settingsStore: SettingsStore,
        openAIBackendFactory: @escaping @Sendable () -> any LivePreviewBackend,
        appleBackendFactory: @escaping @Sendable () -> any LivePreviewBackend
    ) {
        self.settingsStore = settingsStore
        self.openAIBackendFactory = openAIBackendFactory
        self.appleBackendFactory = appleBackendFactory
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

        if OpenAIRealtimePreviewBackend.isSupported(settingsStore: settingsStore) {
            do {
                let realtime = openAIBackendFactory()
                try await realtime.start(onTextUpdate: onTextUpdate)
                backend = realtime
                state = .running
                await flushPendingBuffers()
                return
            } catch {
                NetworkDebugLogger.logError(context: "Realtime preview setup failed, falling back to Apple Speech", error: error)
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
            if let copy = clone(buffer: buffer) {
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

    private func clone(buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity) else {
            return nil
        }

        copy.frameLength = buffer.frameLength

        if let source = buffer.floatChannelData, let destination = copy.floatChannelData {
            let frameCount = Int(buffer.frameLength)
            for channel in 0..<Int(buffer.format.channelCount) {
                destination[channel].update(from: source[channel], count: frameCount)
            }
            return copy
        }

        if let source = buffer.int16ChannelData, let destination = copy.int16ChannelData {
            let frameCount = Int(buffer.frameLength)
            for channel in 0..<Int(buffer.format.channelCount) {
                destination[channel].update(from: source[channel], count: frameCount)
            }
            return copy
        }

        return nil
    }

    private func stopBackend(clearPendingBuffers: Bool) async {
        await backend?.cancel()
        backend = nil
        state = .idle
        if clearPendingBuffers {
            pendingBuffers = []
        }
    }
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

        let recognizer = await MainActor.run { SFSpeechRecognizer() }
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
        self.latestText = ""

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
