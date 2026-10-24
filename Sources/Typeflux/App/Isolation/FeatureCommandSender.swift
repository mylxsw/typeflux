import Foundation

/// State updates keep only the newest pending value while the receiver is busy.
/// User actions are never coalesced or automatically replayed.
@MainActor
final class FeatureCommandSender {
    private let route: (FeatureCommand) async throws -> Data
    private let log: (String) -> Void
    private let now: () -> TimeInterval
    private var latest: [String: FeatureCommand] = [:]
    private var running: Set<String> = []
    private var delivered: [String: (payload: Data, time: TimeInterval)] = [:]
    private var lastFailureLog: [String: TimeInterval] = [:]

    init(route: @escaping (FeatureCommand) async throws -> Data,
         log: @escaping (String) -> Void = { ErrorLogStore.shared.log($0) },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.route = route; self.log = log; self.now = now
    }

    static func isStateUpdate(_ command: FeatureCommand) -> Bool {
        ["status", "indexSnapshot", "focus", "preferences", "changed", "voiceState"].contains(command.action)
            || command.action.hasPrefix("semantic.busy")
    }

    func send(_ command: FeatureCommand) {
        guard Self.isStateUpdate(command) else {
            Task { await deliver(command) }
            return
        }
        // Different change notifications must all reach their observers.
        let suffix = command.action == "changed" ? String(decoding: command.payload, as: UTF8.self) : ""
        let key = command.destination.rawValue + "/" + command.action + "/" + suffix
        latest[key] = command
        guard running.insert(key).inserted else { return }
        Task {
            defer { running.remove(key) }
            while let next = latest.removeValue(forKey: key) {
                let snapshot = ["status", "indexSnapshot"].contains(next.action)
                // Periodic refresh also reaches newly opened presentation processes.
                if snapshot, let previous = delivered[key], previous.payload == next.payload,
                   now() - previous.time < 5 { continue }
                if await deliver(next), snapshot { delivered[key] = (next.payload, now()) }
            }
        }
    }

    @discardableResult
    private func deliver(_ command: FeatureCommand) async -> Bool {
        do { _ = try await route(command); return true }
        catch {
            guard !(error is CancellationError), (error as? FeatureRPC.Failure) != .cancelled else { return false }
            let key = command.destination.rawValue + "/" + command.action
            let instant = now()
            if lastFailureLog[key].map({ instant - $0 >= 10 }) ?? true {
                lastFailureLog[key] = instant
                log("Feature request did not complete: \(key) (\(error))")
            }
            return false
        }
    }
}
