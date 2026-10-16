import Foundation

/// Fixed, independent serial owners for metadata validation, discovery/content,
/// and priority documents. Scope changes revoke access; they never replace a
/// reader while its child or synchronous host work can still be alive.
final class SemanticFileReaders: @unchecked Sendable {
    let validation: SemanticFileReaderLane
    let indexing: SemanticFileReaderLane
    let priority: SemanticFileReaderLane

    init(makeReader: (@Sendable () -> any AskFileReading)? = nil) {
        validation = SemanticFileReaderLane(makeReader: makeReader)
        indexing = SemanticFileReaderLane(makeReader: makeReader)
        priority = SemanticFileReaderLane(makeReader: makeReader)
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
    private var current: AskSearchCancellation?
    private var readerGeneration: AskSearchCancellation?
    private var reader: (any AskFileReading)?
    private let makeReader: @Sendable () -> any AskFileReading

    init(makeReader: (@Sendable () -> any AskFileReading)? = nil) {
        // The native reader keeps this lineage across every scope and restart.
        let ownership = AskFileReaderOwnership()
        self.makeReader = makeReader ?? { AskFileReader(ownership: ownership) }
    }

    func scope() -> SemanticScopedFileReader {
        let token = state.withLock {
            current?.cancel()
            let token = AskSearchCancellation(); current = token; return token
        }
        return SemanticScopedFileReader(lane: self, token: token)
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
                if !again { return }
            }
        }
    }

    fileprivate func perform<T>(_ token: AskSearchCancellation, cancelled: () -> Bool,
                                body: (any AskFileReading) throws -> T) throws -> T {
        func stopped() -> Bool { token.isCancelled || cancelled() }
        guard !stopped() else { throw AskFileReadError.cancelled }
        // No queued host work or new reader allocation behind an old consumer.
        guard operation.try() else { throw AskFileReadError.unavailable }
        defer {
            if token.isCancelled { reader?.stop() }
            operation.unlock()
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

    fileprivate init(lane: SemanticFileReaderLane, token: AskSearchCancellation) {
        self.lane = lane; self.token = token
    }

    func read(_ request: AskFileReadRequest, isCancelled: () -> Bool) throws -> AskFileReadResponse {
        try lane.perform(token, cancelled: isCancelled) { reader in
            try reader.read(request, isCancelled: { token.isCancelled || isCancelled() })
        }
    }

    func stream(_ request: AskFileReadRequest, isCancelled: () -> Bool,
                receive: (AskFileReadResponse) -> Bool) throws {
        try lane.perform(token, cancelled: isCancelled) { reader in
            func stopped() -> Bool { token.isCancelled || isCancelled() }
            try reader.stream(request, isCancelled: stopped) { response in
                guard !stopped() else { return false }
                return receive(response) && !stopped()
            }
        }
    }

    func stop() { token.cancel(); lane.stopIfIdle() }
    deinit { stop() }
}
