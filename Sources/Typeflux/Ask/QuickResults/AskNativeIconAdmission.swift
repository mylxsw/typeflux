import Foundation

/// Keeps native icon work bounded without treating a busy decoder as a missing icon.
actor AskNativeIconAdmission {
    final class Permit: @unchecked Sendable {
        private let admission: AskNativeIconAdmission
        init(_ admission: AskNativeIconAdmission) { self.admission = admission }
        deinit {
            let admission = admission
            Task { await admission.release() }
        }
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Permit, Error>
    }

    private let limit: Int
    private var active = 0
    private var waiting: [Waiter] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async throws -> Permit {
        try Task.checkCancellation()
        if active < limit, waiting.isEmpty {
            active += 1
            return Permit(self)
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiting.append(Waiter(id: id, continuation: continuation)) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiting.isEmpty { active -= 1 }
        else { waiting.removeFirst().continuation.resume(returning: Permit(self)) }
    }
}
