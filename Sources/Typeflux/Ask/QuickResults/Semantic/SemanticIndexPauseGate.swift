import Foundation

/// Pauses background discovery and embedding at file or directory boundaries.
final class SemanticIndexPauseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false

    var isPaused: Bool { lock.withLock { paused } }

    func setPaused(_ value: Bool) { lock.withLock { paused = value } }
}
