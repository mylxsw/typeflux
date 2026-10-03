import Foundation

enum AskObservationError: Error, LocalizedError, Equatable {
    case needsObservation
    case disabled
    case invalid

    var errorDescription: String? {
        switch self {
        case .needsObservation:
            "needs-observation: Observe the target again; " +
                "the previous observation is missing, expired, consumed or changed."
        case .disabled:
            "Desktop/browser writes are disabled pending integration acceptance. " +
                "Read-only observation remains available."
        case .invalid: "Invalid desktop/browser action arguments."
        }
    }
}

/// Trusted, ephemeral evidence. A model-supplied ID only looks up a local record;
/// it never supplies identity. Observations are not grants and are never restored.
@MainActor
final class AskObservationStore {
    struct Scope: Hashable {
        let owner: String
        let conversation: String
        let tool: String
    }

    private struct Entry {
        let reference: AskObservationRef
        let deadline: TimeInterval
    }

    private var entries: [Scope: Entry] = [:]
    private let now: () -> TimeInterval
    private let date: () -> Date
    private let lifetime: TimeInterval

    init(lifetime: TimeInterval = 120, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         date: @escaping () -> Date = Date.init) {
        self.lifetime = lifetime; self.now = now; self.date = date
    }

    func record(_ evidence: AskObservationRef, scope: Scope, id: String = UUID().uuidString) -> AskObservationRef {
        entries = entries.filter { $0.value.deadline > now() }
        // Bound memory even if callers abandon conversations without unbinding.
        if entries.count >= 256 {
            entries.removeAll()
        }
        var reference = evidence
        reference.id = id; reference.capturedAt = date()
        entries[scope] = Entry(reference: reference, deadline: now() + lifetime)
        return reference
    }

    func validate(id: String?, scope: Scope, target: AskExecutionTarget) throws -> AskObservationRef {
        guard let id, let entry = entries[scope], entry.reference.id == id,
              now() < entry.deadline, entry.reference.target == target else {
            throw AskObservationError.needsObservation
        }
        return entry.reference
    }

    /// Consume before dispatch, including attempts whose external result is unknown.
    /// A fresh observation is required for every further write or retry.
    func consume(id: String?, scope: Scope, target: AskExecutionTarget) throws -> AskObservationRef {
        let reference = try validate(id: id, scope: scope, target: target)
        entries.removeValue(forKey: scope)
        return reference
    }

    func invalidate(scope: Scope) {
        entries.removeValue(forKey: scope)
    }

    static func boundTarget(_ reference: AskObservationRef) -> AskExecutionTarget {
        var target = reference.target
        target.version = AskToolPolicy.digest((target.version ?? "") + ":" + reference.id)
        return target
    }
}

/// Legacy text projection retains evidence even when typed results are not negotiated.
/// `ok` means executor completion; a posted event does not prove a business effect.
struct AskActionReceipt {
    var outcome: AskExecutionOutcome
    var message: String
    var observation: AskObservationRef?

    func output(image: String? = nil) -> AskLocalToolOutput {
        do { return try encodedOutput(image: image) } catch {
            return .init(content: "Result unknown: receipt encoding failed. Observe and reconcile before retrying.",
                         isError: true)
        }
    }

    private func encodedOutput(image: String?) throws -> AskLocalToolOutput {
        struct Projection: Encodable {
            let message: String
            let outcome: AskExecutionOutcome
            let observation: AskObservationRef?
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var message = message, outcome = outcome
        func encode() throws -> String {
            let data = try encoder.encode(Projection(message: message, outcome: outcome, observation: observation))
            guard let text = String(data: data, encoding: .utf8) else { throw AskObservationError.invalid }
            return text
        }
        var content = try encode()
        while content.count > 60000 {
            guard message.count > 100 else { throw AskObservationError.invalid }
            outcome.truncated = true
            message = String(message.prefix(message.count / 2)) + "\n[Observation text truncated]"
            content = try encode()
        }
        return .init(content: content, image: image, isError: outcome.safeStatus != .ok)
    }

    static func observed(_ message: String, reference: AskObservationRef?) -> Self {
        .init(
            outcome: .init(status: "ok", eventDispatched: false, effectVerified: false),
            message: message,
            observation: reference
        )
    }
}
