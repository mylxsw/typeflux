import AVFoundation
import Foundation

struct UnavailableTranscriber: Transcriber {
    let providerName: String

    func transcribe(audioFile _: AudioFile) async throws -> String {
        throw NSError(
            domain: "UnavailableTranscriber",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "\(providerName) is not ready."]
        )
    }
}

actor LocalModelLivePreviewBackend: LivePreviewBackend {
    private static let minimumChunkDuration: TimeInterval = 2.4

    private let transcriberFactory: () -> any Transcriber
    private var transcriber: (any Transcriber)?
    private var pendingBuffers: [AVAudioPCMBuffer] = []
    private var pendingDuration: TimeInterval = 0
    private var latestText = ""
    private var isDecoding = false
    private var sessionID = UUID()
    private var onTextUpdate: (@Sendable (String) -> Void)?

    init(
        settingsStore: SettingsStore,
        modelManager: LocalSTTModelManaging,
        transcriberFactory: (() -> any Transcriber)? = nil
    ) {
        self.transcriberFactory = transcriberFactory ?? {
            LocalModelTranscriber(settingsStore: settingsStore, modelManager: modelManager)
        }
    }

    init(transcriberFactory: @escaping () -> any Transcriber) {
        self.transcriberFactory = transcriberFactory
    }

    func start(onTextUpdate: @escaping @Sendable (String) -> Void) async throws {
        sessionID = UUID()
        pendingBuffers = []
        pendingDuration = 0
        latestText = ""
        isDecoding = false
        transcriber = nil
        self.onTextUpdate = onTextUpdate
    }

    func append(_ buffer: AVAudioPCMBuffer) async {
        guard let copy = AudioPCMBufferSnapshot.copy(buffer) else { return }
        pendingBuffers.append(copy)
        pendingDuration += duration(of: copy)
        startDecodeIfNeeded(force: false)
    }

    func finish() async -> String {
        let text = latestText
        reset()
        return text
    }

    func cancel() async {
        reset()
    }

    private func startDecodeIfNeeded(force: Bool) {
        guard !isDecoding, !pendingBuffers.isEmpty else { return }
        guard force || pendingDuration >= Self.minimumChunkDuration else { return }

        let buffers = pendingBuffers
        let activeSessionID = sessionID
        pendingBuffers = []
        pendingDuration = 0
        isDecoding = true

        Task {
            await self.decode(buffers: buffers, sessionID: activeSessionID)
        }
    }

    private func decode(buffers: [AVAudioPCMBuffer], sessionID activeSessionID: UUID) async {
        let text: String?
        do {
            let audioFile = try writeTemporaryAudioFile(buffers: buffers)
            defer { try? FileManager.default.removeItem(at: audioFile.fileURL) }
            let transcriber = transcriberForSession()
            text = try await transcriber.transcribe(audioFile: audioFile)
        } catch {
            NetworkDebugLogger.logError(context: "Local live transcription preview failed", error: error)
            text = nil
        }

        completeDecode(text: text, sessionID: activeSessionID)
    }

    private func completeDecode(text: String?, sessionID activeSessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        isDecoding = false

        if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            latestText = merge(committed: latestText, chunk: text)
            onTextUpdate?(latestText)
        }

        startDecodeIfNeeded(force: false)
    }

    private func transcriberForSession() -> any Transcriber {
        if let transcriber {
            return transcriber
        }
        let newTranscriber = transcriberFactory()
        transcriber = newTranscriber
        return newTranscriber
    }

    private func reset() {
        sessionID = UUID()
        pendingBuffers = []
        pendingDuration = 0
        latestText = ""
        isDecoding = false
        transcriber = nil
        onTextUpdate = nil
    }

    private func writeTemporaryAudioFile(buffers: [AVAudioPCMBuffer]) throws -> AudioFile {
        guard let first = buffers.first else {
            throw NSError(
                domain: "LocalModelLivePreviewBackend",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No audio buffers are available for live preview."]
            )
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TypefluxLivePreview", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        let file = try AVAudioFile(forWriting: fileURL, settings: first.format.settings)

        var duration: TimeInterval = 0
        for buffer in buffers {
            try file.write(from: buffer)
            duration += self.duration(of: buffer)
        }

        return AudioFile(fileURL: fileURL, duration: duration)
    }

    private func duration(of buffer: AVAudioPCMBuffer) -> TimeInterval {
        guard buffer.format.sampleRate > 0 else { return 0 }
        return TimeInterval(buffer.frameLength) / buffer.format.sampleRate
    }

    private func merge(committed: String, chunk: String) -> String {
        guard !committed.isEmpty else { return chunk }

        let maxOverlap = min(committed.count, chunk.count, 24)
        if maxOverlap > 0 {
            for length in stride(from: maxOverlap, through: 1, by: -1) {
                let suffix = String(committed.suffix(length))
                let prefix = String(chunk.prefix(length))
                if suffix == prefix {
                    return committed + String(chunk.dropFirst(length))
                }
            }
        }

        return committed + separator(between: committed, and: chunk) + chunk
    }

    private func separator(between lhs: String, and rhs: String) -> String {
        guard let left = lhs.last, let right = rhs.first else { return "" }
        if left.isWhitespace || right.isWhitespace {
            return ""
        }
        if isASCIIAlphanumeric(left), isASCIIAlphanumeric(right) {
            return " "
        }
        return ""
    }

    private func isASCIIAlphanumeric(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first
        else {
            return false
        }

        return (65 ... 90).contains(scalar.value)
            || (97 ... 122).contains(scalar.value)
            || (48 ... 57).contains(scalar.value)
    }
}
