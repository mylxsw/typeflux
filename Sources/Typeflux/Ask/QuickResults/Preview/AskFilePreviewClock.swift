import Foundation

@MainActor
protocol AskFilePreviewClock {
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> AskFilePreviewTimer
}

@MainActor
final class AskFilePreviewTimer {
    private var cancellation: (() -> Void)?
    init(_ cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        cancellation?(); cancellation = nil
    }
}

struct AskFilePreviewSystemClock: AskFilePreviewClock {
    // Explicit isolation keeps this value usable in default arguments on Swift 5.9.
    // swiftlint:disable:next unneeded_synthesized_initializer
    nonisolated init() {}
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> AskFilePreviewTimer {
        let task = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard !Task.isCancelled else { return }
            action()
        }
        return AskFilePreviewTimer { task.cancel() }
    }
}
