import Foundation

enum NativeTextWriteResult {
    case acknowledged
    /// Only use this when the target could not have performed a write.
    case unsupported
    case unconfirmed
}

enum TextDeliveryObservation {
    case confirmed
    case unchanged
    case unavailable

    func result(method: TextInjectionMethod) -> TextDeliveryResult {
        switch self {
        case .confirmed: .delivered(method)
        case .unchanged: .notApplied(method)
        case .unavailable: .unconfirmed(method)
        }
    }
}

/// Platform calls live behind this boundary so tests exercise the actual delivery
/// sequence, including focus changes and failures after a potentially effective write.
@MainActor
protocol TextDeliveryBackend {
    associatedtype Target
    associatedtype Clipboard
    func resolve(_ destination: TextDeliveryDestination) async throws -> Target
    func writeNative(_ text: String, to target: Target) async throws -> NativeTextWriteResult
    func prepareClipboard() async throws -> Clipboard
    func paste(_ text: String, to target: Target, clipboard: Clipboard) async throws
    func observe(_ text: String, in target: Target) async -> TextDeliveryObservation
    /// Cleanup must run even if cancellation arrives after paste dispatch.
    func finishClipboard(_ clipboard: Clipboard, confirmed: Bool) async
}

@MainActor
final class TextDeliveryCoordinator<Backend: TextDeliveryBackend> {
    private let backend: Backend
    private var isDelivering = false

    init(backend: Backend) { self.backend = backend }

    func deliver(_ text: String, to destination: TextDeliveryDestination) async throws -> TextDeliveryResult {
        try Task.checkCancellation()
        guard !text.isEmpty else { throw TextDeliveryError.emptyOutput }
        guard !isDelivering else { throw TextDeliveryError.busy }
        isDelivering = true
        defer { isDelivering = false }

        let initialTarget = try await backend.resolve(destination)
        try Task.checkCancellation()
        switch try await backend.writeNative(text, to: initialTarget) {
        case .acknowledged:
            // Do not turn a completed write into cancellation or retry it.
            return .delivered(.ax)
        case .unconfirmed:
            return await backend.observe(text, in: initialTarget).result(method: .ax)
        case .unsupported:
            break
        }

        try Task.checkCancellation()
        // Persona validation may use Cmd+C. Finish that probe before taking the
        // clipboard snapshot; probing afterwards would invalidate our own lease.
        let selectionTarget: Backend.Target?
        if case .selection = destination {
            selectionTarget = try await backend.resolve(destination)
        } else {
            selectionTarget = nil
        }
        try Task.checkCancellation()
        let clipboard = try await backend.prepareClipboard()
        let result: TextDeliveryResult
        do {
            try Task.checkCancellation()
            // Clipboard materialization can take time. Dictation follows the new
            // caret; persona resolution must still authorize the original selection.
            let target: Backend.Target
            if let selectionTarget {
                target = selectionTarget
            } else {
                target = try await backend.resolve(destination)
            }
            try Task.checkCancellation()
            // The new destination may support native insertion even if the first
            // one did not. No earlier write occurred, so this attempt is safe.
            switch try await backend.writeNative(text, to: target) {
            case .acknowledged:
                result = .delivered(.ax)
            case .unconfirmed:
                result = await backend.observe(text, in: target).result(method: .ax)
            case .unsupported:
                try Task.checkCancellation()
                try await backend.paste(text, to: target, clipboard: clipboard)
                result = await backend.observe(text, in: target).result(method: .paste)
            }
        } catch {
            await backend.finishClipboard(clipboard, confirmed: false)
            throw error
        }
        await backend.finishClipboard(clipboard, confirmed: result == .delivered(.paste))
        return result
    }
}

enum TextDeliveryEvidence {
    /// Exact, range-based evidence only. A substring may have existed before the
    /// operation and is not proof that this particular delivery happened.
    static func confirms(text: String, before: String?, range: CFRange?, after: String?) -> Bool {
        guard let before, let range, let after,
              let expected = AXTextInjector.replacingUTF16Range(in: before, range: range, with: text)
        else { return false }
        return after == expected && after != before
    }
}

@MainActor
enum TextDeliveryObserver {
    static func confirm(
        text: String, before: String?, range: CFRange?,
        read: () async throws -> String?,
        pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(120)) }
    ) async -> Bool {
        await observe(text: text, before: before, range: range, read: read, pause: pause) == .confirmed
    }

    static func observe(
        text: String, before: String?, range: CFRange?,
        read: () async throws -> String?,
        pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(120)) }
    ) async -> TextDeliveryObservation {
        guard let before, let range else { return .unavailable }
        for _ in 0 ..< 4 {
            do {
                try await pause()
                guard let after = try await read() else { return .unavailable }
                if TextDeliveryEvidence.confirms(text: text, before: before, range: range, after: after) {
                    return .confirmed
                }
            } catch { return .unavailable }
        }
        // An external AX tree can stay stale after a successful edit. No match,
        // including an unchanged value, is absence of proof rather than failure.
        return .unavailable
    }
}
