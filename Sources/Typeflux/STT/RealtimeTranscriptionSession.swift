import AVFoundation
import Foundation

protocol RealtimeTranscriptionSession: AnyObject {
    func start() async
    func append(_ buffer: AVAudioPCMBuffer) async
    func finish() async throws -> String
    func cancel() async
}

/// Exposes the optimize value actually used to create a realtime ASR session.
/// A nil value means the provider does not support this request option.
protocol RealtimeASROptimizeProviding: AnyObject {
    var asrOptimize: Bool? { get }
}

protocol PCM16RealtimeTranscriptionSession: AnyObject {
    func start() async throws
    func appendPCM16(_ data: Data) async throws
    func finish() async throws -> String
    func cancel() async
}

actor DeferredPCM16RealtimeTranscriptionSession: PCM16RealtimeTranscriptionSession,
    RealtimeTransportDiagnosticsProviding {
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

    func transportDiagnosticsSnapshot() async -> NetworkTransportDiagnosticsSnapshot? {
        let resolved = upstream ?? startingUpstream
        guard let provider = resolved as? any RealtimeTransportDiagnosticsProviding else { return nil }
        return await provider.transportDiagnosticsSnapshot()
    }
}

enum RealtimeAudioBufferError: Error { case capacityExceeded, invalidBuffer }

/// Fixed queue capacity plus a per-buffer byte limit, including the buffer in flight.
final class RealtimeAudioBufferPump {
    static let maximumBufferBytes = 256 * 1024
    private final class Admission: @unchecked Sendable {
        let lock = NSLock()
        var failed = false
        var closed = false
        var cancelled = false
        var maySend: Bool {
            lock.lock(); defer { lock.unlock() }
            return !failed && !cancelled
        }
    }
    private let admission = Admission()
    private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    private let task: Task<Void, Never>

    init(session: any RealtimeTranscriptionSession, maximumQueuedBuffers: Int = 256) {
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .bufferingOldest(max(1, min(maximumQueuedBuffers, 256))))
        self.continuation = continuation
        let admission = self.admission
        task = Task { [session] in
            for await buffer in stream {
                guard !Task.isCancelled, admission.maySend else { break }
                await session.append(buffer)
            }
            if Task.isCancelled || !admission.maySend { await session.cancel() }
        }
    }

    deinit { continuation.finish(); task.cancel() }

    func append(_ buffer: AVAudioPCMBuffer) {
        admission.lock.lock(); defer { admission.lock.unlock() }
        guard !admission.closed else { return }
        guard let snapshot = AudioPCMBufferSnapshot.copy(buffer, maximumBytes: Self.maximumBufferBytes) else {
            admission.failed = true; admission.closed = true; continuation.finish(); return
        }
        if case .dropped = continuation.yield(snapshot) {
            admission.failed = true; admission.closed = true; continuation.finish()
        }
    }

    /// Reject a missing startup prefix through the existing realtime failure policy.
    func failInput() {
        admission.lock.lock(); defer { admission.lock.unlock() }
        admission.failed = true; admission.closed = true; continuation.finish()
    }

    /// Incomplete input must never be presented as a successful realtime transcript.
    func finishInput() async throws {
        close(cancelled: false)
        await task.value
        try result()
    }

    private func result() throws {
        admission.lock.lock(); defer { admission.lock.unlock() }
        if admission.cancelled { throw CancellationError() }
        if admission.failed { throw RealtimeAudioBufferError.capacityExceeded }
    }

    func cancel() { close(cancelled: true); task.cancel() }

    private func close(cancelled: Bool) {
        admission.lock.lock(); defer { admission.lock.unlock() }
        admission.closed = true
        admission.cancelled = admission.cancelled || cancelled
        continuation.finish()
    }
}

/// Carries an already-observed input failure through the existing transcription error policy.
final class FailedRealtimeAudioInput: RealtimeTranscriptionSession {
    private let error: Error
    init(_ error: Error) { self.error = error }
    func start() async {}
    func append(_ buffer: AVAudioPCMBuffer) async {}
    func finish() async throws -> String { throw error }
    func cancel() async {}
}

actor BufferedRealtimeTranscriptionSession: RealtimeTranscriptionSession,
    RealtimeTranscriptionConnectionAwaiting,
    RealtimeTransportDiagnosticsProviding {
    private enum State {
        case idle
        case active
        case finishing
        case cancelled
    }

    private let upstream: any PCM16RealtimeTranscriptionSession
    private let encoder = RealtimePCM16AudioEncoder()
    private let maximumQueuedChunks: Int
    private var chunker = PCM16FrameChunker(chunkSize: CloudASRAudioConverter.chunkSize)
    private var state: State = .idle
    private var continuation: AsyncStream<Data>.Continuation?
    private var startTask: Task<Void, Error>?
    private var writerTask: Task<String, Error>?
    private var failureTask: Task<Void, Never>?
    private var firstError: Error?

    init(upstream: any PCM16RealtimeTranscriptionSession, maximumQueuedChunks: Int = 512) {
        self.upstream = upstream
        self.maximumQueuedChunks = max(1, min(maximumQueuedChunks, 512))
    }

    deinit {
        continuation?.finish()
        writerTask?.cancel()
        startTask?.cancel()
    }

    func start() {
        guard state == .idle else { return }
        state = .active
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(maximumQueuedChunks))
        self.continuation = continuation
        let connecting = Task { [upstream] in try await upstream.start() }
        startTask = connecting
        // Exactly one task owns all writes, including the buffered prefix and stop.
        // Actor isolation alone does not preserve order across awaited network writes.
        let writer = Task { [upstream] in
            do {
                try await connecting.value
                for await chunk in stream {
                    try Task.checkCancellation()
                    try await upstream.appendPCM16(chunk)
                }
                try Task.checkCancellation()
                return try await upstream.finish()
            } catch {
                await upstream.cancel()
                throw error
            }
        }
        writerTask = writer
        failureTask = Task { [weak self] in
            do { _ = try await writer.value }
            catch { await self?.fail(error) }
        }
    }

    func waitUntilConnectionReady() async throws {
        try await startTask?.value
    }

    func append(_ buffer: AVAudioPCMBuffer) async {
        guard state != .cancelled, state != .finishing else { return }
        if state == .idle { start() }
        do {
            guard AudioPCMBufferSnapshot.byteCount(buffer, maximumBytes: RealtimeAudioBufferPump.maximumBufferBytes) != nil else {
                throw RealtimeAudioBufferError.invalidBuffer
            }
            let pcmData = try encoder.encode(buffer: buffer)
            await appendEncodedPCM16(pcmData)
        } catch {
            await fail(error)
        }
    }

    /// Bounded encoded input handoff shared by the encoder and transport; no native conversion here.
    func appendEncodedPCM16(_ data: Data) async {
        guard state != .cancelled, state != .finishing else { return }
        if state == .idle { start() }
        guard data.count <= RealtimePCM16AudioEncoder.maximumOutputBytes else {
            await fail(RealtimeAudioBufferError.capacityExceeded); return
        }
        for chunk in chunker.append(data) {
            guard await enqueue(chunk) else { return }
        }
    }

    private func enqueue(_ data: Data) async -> Bool {
        guard let continuation else { return false }
        if case .enqueued = continuation.yield(data) { return true }
        await fail(RealtimeAudioBufferError.capacityExceeded)
        return false
    }

    func finish() async throws -> String {
        if state == .cancelled {
            _ = try? await writerTask?.value
            await failureTask?.value
            throw firstError ?? CancellationError()
        }
        if state == .idle { start() }
        if state != .finishing {
            state = .finishing
            for chunk in chunker.flush() { guard await enqueue(chunk) else { break } }
            continuation?.finish()
        }
        guard let writerTask else { throw CancellationError() }
        let result: String
        do { result = try await writerTask.value }
        catch {
            await failureTask?.value
            throw firstError ?? error
        }
        await failureTask?.value
        guard state != .cancelled else { throw firstError ?? CancellationError() }
        return result
    }

    func cancel() async {
        state = .cancelled
        continuation?.finish()
        continuation = nil
        writerTask?.cancel()
        startTask?.cancel()
        chunker.reset()
        await upstream.cancel()
        // Cancellation is not collection: retain the writer until its entered I/O returns.
        _ = try? await writerTask?.value
    }

    func transportDiagnosticsSnapshot() async -> NetworkTransportDiagnosticsSnapshot? {
        guard let provider = upstream as? any RealtimeTransportDiagnosticsProviding else { return nil }
        return await provider.transportDiagnosticsSnapshot()
    }

    private func fail(_ error: Error) async {
        guard state != .cancelled else { return }
        firstError = firstError ?? error
        await cancel()
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
        // A consumed Data slice can have a nonzero start index. Replace its storage.
        buffer = Data()
    }

    private func ownedCopy(_ range: Range<Data.Index>) -> Data {
        var result = Data(count: range.count)
        result.withUnsafeMutableBytes { destination in
            _ = buffer.copyBytes(to: destination.bindMemory(to: UInt8.self), from: range)
        }
        return result
    }

    private mutating func drain(keepingRemainder: Bool) -> [Data] {
        guard chunkSize > 0 else {
            let chunks = buffer.isEmpty ? [] : [ownedCopy(buffer.startIndex..<buffer.endIndex)]
            buffer = Data()
            return chunks
        }
        var chunks: [Data] = [], consumed = 0
        while buffer.count - consumed >= chunkSize {
            let start = buffer.index(buffer.startIndex, offsetBy: consumed)
            let end = buffer.index(start, offsetBy: chunkSize)
            chunks.append(ownedCopy(start..<end))
            consumed += chunkSize
        }
        if !keepingRemainder, consumed < buffer.count {
            let start = buffer.index(buffer.startIndex, offsetBy: consumed)
            chunks.append(ownedCopy(start..<buffer.endIndex))
            consumed = buffer.count
        }
        // Keep only a zero-based owned remainder; never mutate a consumed InlineSlice.
        let start = buffer.index(buffer.startIndex, offsetBy: consumed)
        buffer = start == buffer.endIndex ? Data() : ownedCopy(start..<buffer.endIndex)
        return chunks
    }
}

final class RealtimePCM16AudioEncoder {
    static let maximumOutputBytes = 1024 * 1024

    static func targetCapacity(frames: AVAudioFrameCount, sampleRate: Double) throws -> AVAudioFrameCount {
        guard frames > 0, sampleRate.isFinite, sampleRate > 0 else { throw RealtimeAudioBufferError.invalidBuffer }
        let capacity = Double(frames) * CloudASRAudioConverter.targetSampleRate / sampleRate + 256
        guard capacity.isFinite, capacity <= Double(maximumOutputBytes / 2) else {
            throw RealtimeAudioBufferError.capacityExceeded
        }
        return AVAudioFrameCount(capacity)
    }

    private let targetSampleRate = CloudASRAudioConverter.targetSampleRate
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?

    func encode(buffer: AVAudioPCMBuffer) throws -> Data {
        guard buffer.frameLength > 0 else { return Data() }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw NSError(
                domain: "RealtimePCM16AudioEncoder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create realtime target audio format."]
            )
        }

        let sourceFormat = buffer.format
        guard sourceFormat.sampleRate > 0 else {
            throw NSError(
                domain: "RealtimePCM16AudioEncoder",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Source audio format has an invalid sample rate."]
            )
        }

        let targetCapacity = try Self.targetCapacity(frames: buffer.frameLength, sampleRate: sourceFormat.sampleRate)
        let converter = try converterFor(sourceFormat: sourceFormat, targetFormat: targetFormat)
        guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity) else {
            throw NSError(
                domain: "RealtimePCM16AudioEncoder",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to allocate realtime target audio buffer."]
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
                userInfo: [NSLocalizedDescriptionKey: "Realtime audio conversion failed."]
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
                userInfo: [NSLocalizedDescriptionKey: "Failed to create realtime audio converter."]
            )
        }
        converter = newConverter
        converterSourceFormat = sourceFormat
        return newConverter
    }
}
