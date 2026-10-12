import Combine
import Foundation

/// Only confirmations without an in-place context belong in this HUD.
@MainActor
public final class TypefluxHUDState: ObservableObject {
    public static let dismissalDelay: Duration = .milliseconds(1500)
    @Published public private(set) var message: TypefluxHUDMessage?
    private var timer: Task<Void, Never>?
    private let sleep: @Sendable (Duration) async throws -> Void

    public convenience init() {
        self.init(sleep: { try await Task.sleep(for: $0) })
    }

    init(sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.sleep = sleep
    }

    public func present(_ message: TypefluxHUDMessage) {
        timer?.cancel()
        self.message = message
        let sleep = sleep
        timer = Task { [weak self] in
            do { try await sleep(Self.dismissalDelay) } catch { return }
            guard !Task.isCancelled, self?.message?.id == message.id else { return }
            self?.dismiss()
        }
    }

    public func dismiss() {
        timer?.cancel()
        timer = nil
        message = nil
    }

    deinit { timer?.cancel() }
}
