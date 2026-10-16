import Darwin
import Foundation

/// Fixed, independent serial owners for metadata validation, discovery/content,
/// and priority documents. Scope changes revoke access; they never replace a
/// reader while its child or synchronous host work can still be alive.
final class SemanticFileReaders: @unchecked Sendable {
    let validation: SemanticFileReaderLane
    let indexing: SemanticFileReaderLane
    let priority: SemanticFileReaderLane

    init(makeReader: (@Sendable () -> any AskFileReading)? = nil, requiresLifecycle: Bool = false) {
        validation = SemanticFileReaderLane(makeReader: makeReader, requiresLifecycle: requiresLifecycle)
        indexing = SemanticFileReaderLane(makeReader: makeReader, requiresLifecycle: requiresLifecycle)
        priority = SemanticFileReaderLane(makeReader: makeReader, requiresLifecycle: requiresLifecycle)
    }

    struct Authorization: Sendable {
        let validation: UUID?
        let indexing: UUID?
        let priority: UUID?
        func allowsIndexing(in readers: SemanticFileReaders) -> Bool {
            readers.indexing.permits(indexing) && readers.priority.permits(priority)
        }
    }
    func authorization() -> Authorization {
        .init(validation: validation.generation, indexing: indexing.generation, priority: priority.generation)
    }

    func stop() { validation.stop(); indexing.stop(); priority.stop() }
    deinit { stop() }
}

final class SemanticFileReaderLane: @unchecked Sendable {
    private let state = NSLock()
    private let operation = NSLock()
    private let cleanup = DispatchQueue(label: "typeflux.semantic.reader-retirement", qos: .utility)
    private var cleanupScheduled = false
    private var cleanupRequested = false
    private var hostActive = false
    private var current: AskSearchCancellation?
    private var readerGeneration: AskSearchCancellation?
    private var reader: (any AskFileReading)?
    private let makeReader: @Sendable () -> any AskFileReading
    let ownership: AskFileReaderOwnership
    private let requiresLifecycle: Bool
    private var gate: ModuleWorkerGate?

    init(makeReader: (@Sendable () -> any AskFileReading)? = nil, requiresLifecycle: Bool = false,
         ownership: AskFileReaderOwnership? = nil) {
        // The native reader keeps this lineage across every scope and restart.
        let ownership = ownership ?? AskFileReaderOwnership(requiresLifecycle: requiresLifecycle)
        self.ownership = ownership; self.requiresLifecycle = requiresLifecycle
        self.makeReader = makeReader ?? { AskFileReader(ownership: ownership) }
    }

    func bind(_ gate: ModuleWorkerGate) -> Bool {
        guard operation.try() else { return false }
        defer { operation.unlock() }
        return state.withLock {
            guard self.gate == nil, !cleanupScheduled,
                  ownership.bind(gate, invalidate: { [weak self] in self?.stop() }) else { return false }
            self.gate = gate; return true
        }
    }

    fileprivate func permits(_ generation: UUID?) -> Bool {
        state.withLock { gate.map { $0.permits(generation) } ?? !requiresLifecycle }
    }
    private func changed() { state.withLock { gate }?.changed() }
    var isOccupied: Bool {
        // Observation must never compete with nonwaiting typed admission.
        state.withLock { hostActive || cleanupScheduled } || ownership.isOccupied
    }
    func retireManaged() async {
        // Only the process handle is signalled here. FD/consumer cleanup stays serial.
        ownership.stopOwned()
        stop()
        await withCheckedContinuation { continuation in
            cleanup.async { [self] in
                operation.lock(); reader?.stop(); operation.unlock()
                continuation.resume()
            }
        }
        await ownership.waitUntilRetired()
    }

    var generation: UUID? { state.withLock { try? gate?.admit() } }
    func scope() -> SemanticScopedFileReader { scope(generation: generation) }
    func scope(generation: UUID?) -> SemanticScopedFileReader {
        let token = state.withLock {
            current?.cancel()
            let token = AskSearchCancellation(); current = token; return token
        }
        return SemanticScopedFileReader(lane: self, token: token, generation: generation)
    }

    func stop() {
        state.withLock { current?.cancel(); current = nil }
        stopIfIdle()
    }

    fileprivate func stopIfIdle() {
        // Never close reader descriptors concurrently with a read/callback.
        // Coalesce cleanup off the caller/UI; a busy operation cleans itself up.
        let schedule = state.withLock {
            cleanupRequested = true
            guard !cleanupScheduled else { return false }
            cleanupScheduled = true; return true
        }
        guard schedule else { return }
        cleanup.async { [self] in
            while true {
                state.withLock { cleanupRequested = false }
                // One off-UI waiter retains the lane through uncooperative work.
                operation.lock()
                if readerGeneration?.isCancelled == true { reader?.stop() }
                operation.unlock()
                let again = state.withLock {
                    // A stop racing the check/unlock must not be lost merely
                    // because this cleanup block was already scheduled.
                    if cleanupRequested { return true }
                    cleanupScheduled = false; return false
                }
                changed()
                if !again { return }
            }
        }
    }

    fileprivate func perform<T>(_ token: AskSearchCancellation, generation: UUID?, cancelled: () -> Bool,
                                body: (any AskFileReading) throws -> T) throws -> T {
        func stopped() -> Bool { token.isCancelled || cancelled() || !permits(generation) }
        guard !stopped() else { throw AskFileReadError.cancelled }
        // No queued host work or new reader allocation behind an old consumer.
        guard operation.try() else { throw AskFileReadError.unavailable }
        state.withLock { hostActive = true }
        defer {
            if token.isCancelled { reader?.stop() }
            state.withLock { hostActive = false }
            operation.unlock()
            changed()
        }
        guard !stopped() else { throw AskFileReadError.cancelled }
        if readerGeneration?.isCancelled == true { reader?.stop() }
        if reader == nil { reader = makeReader() }
        readerGeneration = token
        do {
            guard !stopped(), let reader else { throw AskFileReadError.cancelled }
            let result = try body(reader)
            guard !stopped() else { throw AskFileReadError.cancelled }
            return result
        } catch {
            if !stopped() {
                let ns = error as NSError
                let configuration = ns.domain == NSPOSIXErrorDomain && [EACCES, EPERM, ENOENT, ENOEXEC].contains(Int32(ns.code))
                if let gate = state.withLock({ gate }),
                   configuration || error is DecodingError || (error as? AskFileReadError) == .protocolError || (error as? AskFileReadError) == .timeout {
                    gate.failed(generation, configuration: configuration)
                    stop()
                }
            }
            reader?.stop()
            throw error
        }
    }
}

/// A scope never acquires a later generation's permission, even if an old query
/// retains it after the service has changed roots or been released.
final class SemanticScopedFileReader: AskFileReading, @unchecked Sendable {
    private let lane: SemanticFileReaderLane
    private let token: AskSearchCancellation
    private let generation: UUID?

    fileprivate init(lane: SemanticFileReaderLane, token: AskSearchCancellation, generation: UUID?) {
        self.lane = lane; self.token = token; self.generation = generation
    }

    func read(_ request: AskFileReadRequest, isCancelled: () -> Bool) throws -> AskFileReadResponse {
        try lane.perform(token, generation: generation, cancelled: isCancelled) { reader in
            try reader.read(request, isCancelled: { token.isCancelled || isCancelled() || !lane.permits(generation) })
        }
    }

    func stream(_ request: AskFileReadRequest, isCancelled: () -> Bool,
                receive: (AskFileReadResponse) -> Bool) throws {
        try lane.perform(token, generation: generation, cancelled: isCancelled) { reader in
            func stopped() -> Bool { token.isCancelled || isCancelled() || !lane.permits(generation) }
            try reader.stream(request, isCancelled: stopped) { response in
                guard !stopped() else { return false }
                return receive(response) && !stopped()
            }
        }
    }

    func stop() { token.cancel(); lane.stopIfIdle() }
    deinit { stop() }
}
