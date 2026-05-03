import AVFoundation
import Foundation

protocol RealtimeTranscriptionSession: AnyObject {
    func start() async
    func append(_ buffer: AVAudioPCMBuffer) async
    func finish() async throws -> String
    func cancel() async
}

protocol PCM16RealtimeTranscriptionSession: AnyObject {
    func start() async throws
    func appendPCM16(_ data: Data) async throws
    func finish() async throws -> String
    func cancel() async
}

actor DeferredPCM16RealtimeTranscriptionSession: PCM16RealtimeTranscriptionSession {
    private let makeUpstream: @Sendable () async throws -> any PCM16RealtimeTranscriptionSession
    private var startingUpstream: (any PCM16RealtimeTranscriptionSession)?
    private var upstream: (any PCM16RealtimeTranscriptionSession)?
    private var isCancelled = false

    init(makeUpstream: @escaping @Sendable () async throws -> any PCM16RealtimeTranscriptionSession) {
        self.makeUpstream = makeUpstream
    }

    func start() async throws {
        guard upstream == nil else { return }
        guard !isCancelled else { throw CancellationError() }
        let resolved = try await makeUpstream()
        guard !isCancelled else {
            await resolved.cancel()
            throw CancellationError()
        }
        startingUpstream = resolved
        defer { startingUpstream = nil }
        try await resolved.start()
        guard !isCancelled else {
            await resolved.cancel()
            throw CancellationError()
        }
        upstream = resolved
    }

    func appendPCM16(_ data: Data) async throws {
        guard let upstream else { throw CancellationError() }
        try await upstream.appendPCM16(data)
    }

    func finish() async throws -> String {
        guard let upstream else { throw CancellationError() }
        return try await upstream.finish()
    }

    func cancel() async {
        isCancelled = true
        await startingUpstream?.cancel()
        startingUpstream = nil
        await upstream?.cancel()
        upstream = nil
    }
}

final class RealtimeAudioBufferPump {
    private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    private let task: Task<Void, Never>

    init(session: any RealtimeTranscriptionSession) {
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        self.continuation = continuation
        task = Task { [session] in
            for await buffer in stream {
                await session.append(buffer)
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        continuation.yield(buffer)
    }

    func finishInput() async {
        continuation.finish()
        await task.value
    }

    func cancel() {
        continuation.finish()
        task.cancel()
    }
}

actor BufferedRealtimeTranscriptionSession: RealtimeTranscriptionSession {
    private enum State {
        case idle
        case starting
        case running
        case finishing
        case cancelled
    }

    private let upstream: any PCM16RealtimeTranscriptionSession
    private let encoder = RealtimePCM16AudioEncoder()
    private var chunker = PCM16FrameChunker(chunkSize: CloudASRAudioConverter.chunkSize)
    private var pendingChunks: [Data] = []
    private var state: State = .idle
    private var startTask: Task<Void, Error>?
    private var firstError: Error?

    init(upstream: any PCM16RealtimeTranscriptionSession) {
        self.upstream = upstream
    }

    func start() {
        guard state == .idle else { return }
        state = .starting
        startTask = Task { [upstream] in
            try await upstream.start()
        }
        Task { await completeStart() }
    }

    func append(_ buffer: AVAudioPCMBuffer) async {
        guard state != .cancelled, state != .finishing else { return }
        do {
            let pcmData = try encoder.encode(buffer: buffer)
            let chunks = chunker.append(pcmData)
            try await enqueueOrSend(chunks)
        } catch {
            await fail(error)
        }
    }

    func finish() async throws -> String {
        if state == .idle {
            start()
        }
        state = .finishing

        do {
            try await startTask?.value
        } catch {
            firstError = firstError ?? error
        }

        if let firstError {
            await upstream.cancel()
            throw firstError
        }

        do {
            let finalChunks = chunker.flush()
            try await sendPendingAnd(finalChunks)
            return try await upstream.finish()
        } catch {
            await upstream.cancel()
            throw error
        }
    }

    func cancel() async {
        state = .cancelled
        startTask?.cancel()
        pendingChunks.removeAll()
        chunker.reset()
        await upstream.cancel()
    }

    private func completeStart() async {
        do {
            try await startTask?.value
            guard state == .starting else { return }
            state = .running
            try await sendPendingAnd([])
        } catch {
            await fail(error)
        }
    }

    private func enqueueOrSend(_ chunks: [Data]) async throws {
        guard !chunks.isEmpty else { return }
        switch state {
        case .idle, .starting:
            pendingChunks.append(contentsOf: chunks)
        case .running:
            try await send(chunks)
        case .finishing, .cancelled:
            break
        }
    }

    private func sendPendingAnd(_ chunks: [Data]) async throws {
        let allChunks = pendingChunks + chunks
        pendingChunks.removeAll(keepingCapacity: true)
        try await send(allChunks)
    }

    private func send(_ chunks: [Data]) async throws {
        for chunk in chunks where !chunk.isEmpty {
            try await upstream.appendPCM16(chunk)
        }
    }

    private func fail(_ error: Error) async {
        firstError = firstError ?? error
        state = .cancelled
        startTask?.cancel()
        pendingChunks.removeAll()
        chunker.reset()
        await upstream.cancel()
        NetworkDebugLogger.logError(context: "Realtime transcription session failed", error: error)
    }
}

struct PCM16FrameChunker {
    private let chunkSize: Int
    private var buffer = Data()

    init(chunkSize: Int) {
        self.chunkSize = chunkSize
    }

    mutating func append(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        buffer.append(data)
        return drain(keepingRemainder: true)
    }

    mutating func flush() -> [Data] {
        drain(keepingRemainder: false)
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    private mutating func drain(keepingRemainder: Bool) -> [Data] {
        guard chunkSize > 0 else {
            defer { buffer.removeAll(keepingCapacity: true) }
            return buffer.isEmpty ? [] : [buffer]
        }

        var chunks: [Data] = []
        while buffer.count >= chunkSize {
            chunks.append(Data(buffer.prefix(chunkSize)))
            buffer.removeFirst(chunkSize)
        }

        if !keepingRemainder, !buffer.isEmpty {
            chunks.append(Data(buffer))
            buffer.removeAll(keepingCapacity: true)
        }
        return chunks
    }
}

final class RealtimePCM16AudioEncoder {
    private let targetSampleRate = CloudASRAudioConverter.targetSampleRate
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?

    func encode(buffer: AVAudioPCMBuffer) throws -> Data {
        guard buffer.frameLength > 0 else { return Data() }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true,
        ) else {
            throw NSError(
                domain: "RealtimePCM16AudioEncoder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create realtime target audio format."],
            )
        }

        let sourceFormat = buffer.format
        guard sourceFormat.sampleRate > 0 else {
            throw NSError(
                domain: "RealtimePCM16AudioEncoder",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Source audio format has an invalid sample rate."],
            )
        }

        let converter = try converterFor(sourceFormat: sourceFormat, targetFormat: targetFormat)
        let ratio = targetSampleRate / sourceFormat.sampleRate
        let targetCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 256
        guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity) else {
            throw NSError(
                domain: "RealtimePCM16AudioEncoder",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to allocate realtime target audio buffer."],
            )
        }

        var hasProvidedInput = false
        var convertError: NSError?
        let status = converter.convert(to: targetBuffer, error: &convertError) { _, outStatus in
            if hasProvidedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            hasProvidedInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let convertError { throw convertError }
        guard status != .error else {
            throw NSError(
                domain: "RealtimePCM16AudioEncoder",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Realtime audio conversion failed."],
            )
        }

        let bytesPerFrame = Int(targetFormat.streamDescription.pointee.mBytesPerFrame)
        let byteCount = Int(targetBuffer.frameLength) * bytesPerFrame
        guard let channelData = targetBuffer.int16ChannelData else { return Data() }
        return Data(bytes: channelData[0], count: byteCount)
    }

    private func converterFor(sourceFormat: AVAudioFormat, targetFormat: AVAudioFormat) throws -> AVAudioConverter {
        if let converter, converterSourceFormat == sourceFormat {
            return converter
        }
        guard let newConverter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw NSError(
                domain: "RealtimePCM16AudioEncoder",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create realtime audio converter."],
            )
        }
        converter = newConverter
        converterSourceFormat = sourceFormat
        return newConverter
    }
}
