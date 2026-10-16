import Foundation

/// At most one pending main-queue delivery; a fast scan cannot enqueue thousands of UI tasks.
final class SemanticProgressRelay<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: Value?
    private var scheduled = false
    private var closed = false
    private let deliver: @MainActor @Sendable (Value) -> Void

    init(deliver: @escaping @MainActor @Sendable (Value) -> Void) {
        self.deliver = deliver
    }

    func send(_ summary: Value) {
        let schedule = lock.withLock {
            guard !closed else { return false }
            latest = summary
            guard !scheduled else { return false }
            scheduled = true; return true
        }
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self] in
            guard let self else { return }
            let value = lock.withLock { () -> Value? in
                self.scheduled = false
                defer { self.latest = nil }
                return self.closed ? nil : self.latest
            }
            if let value {
                MainActor.assumeIsolated { self.deliver(value) }
            }
        }
    }

    func close() {
        lock.withLock { closed = true; latest = nil }
    }
}

typealias SemanticIndexProgressRelay = SemanticProgressRelay<SemanticFileIndexer.Summary>
