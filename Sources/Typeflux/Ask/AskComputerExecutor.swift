import AppKit

@MainActor
final class AskComputerExecutor {
    struct Target {
        var reference: AskObservationRef
        var display: CGDirectDisplayID
        var bounds: CGRect
        var window: CGRect
        var description: String
        var dispatchIdentity: String
    }

    struct Environment {
        var target: () throws -> Target
        var activate: () throws -> Void
        var isActive: () -> Bool
        var screenshot: (CGDirectDisplayID) async throws -> AskContextCapture
            .Screenshot = { try await AskContextCapture.screenshot(displayId: $0) }
        var post: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }
        var pause: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    }

    let store: AskObservationStore
    var writesEnabled = false

    init(store: AskObservationStore) {
        self.store = store
    }

    static func isObservation(_ args: [String: Any]) -> Bool {
        ["inspect", "screenshot", "wait"]
            .contains(args["action"] as? String ?? "")
    }

    func binding(_ args: [String: Any], scope: AskObservationStore.Scope,
                 environment: Environment) throws -> AskExecutionTarget {
        if args["action"] as? String == "wait" {
            return .init(kind: "workspace", id: scope.conversation)
        }
        if !Self.isObservation(args), !writesEnabled {
            throw AskObservationError.disabled
        }
        let current = try environment.target()
        if Self.isObservation(args) {
            return current.reference.target
        }
        let reference = try store.validate(
            id: args["observation_id"] as? String,
            scope: scope,
            target: current.reference.target
        )
        _ = try Self.events(args, target: current)
        return AskObservationStore.boundTarget(reference)
    }

    // Keep authorization and unconditional input release in one control-flow boundary.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func execute(_ args: [String: Any], scope: AskObservationStore.Scope, environment: Environment,
                 approved: AskExecutionTarget? = nil,
                 authorize: () throws -> Void = {}) async throws -> AskLocalToolOutput {
        let action = args["action"] as? String ?? ""
        try Task.checkCancellation()
        if action == "wait" {
            let seconds = (args["seconds"] as? Double) ?? (args["seconds"] as? Int).map(Double.init) ?? 1
            guard seconds.isFinite, (0 ... 5).contains(seconds) else { throw AskObservationError.invalid }
            try authorize()
            try await environment.pause(.seconds(seconds))
            return .init(content: "Waited \(seconds) s.")
        }
        if !Self.isObservation(args), !writesEnabled {
            throw AskObservationError.disabled
        }
        let current = try environment.target()
        if Self.isObservation(args) {
            guard approved == nil || approved == current.reference.target
            else { throw AskObservationError.needsObservation }
            try authorize()
            store.invalidate(scope: scope)
            var image: String?
            if action == "screenshot" {
                let shot = try await environment.screenshot(current.display)
                guard shot.displayId == current.display else { throw AskObservationError.needsObservation }
                image = shot.dataURL
            }
            try Task.checkCancellation()
            guard try environment.target().reference.target == current.reference.target
            else { throw AskObservationError.needsObservation }
            let reference = store.record(current.reference, scope: scope)
            return AskActionReceipt.observed(
                "Coordinates are fractions of display \(current.display), from top-left (0,0) to bottom-right (1,1).\n" +
                    current.description,
                reference: reference
            ).output(image: image)
        }
        let reference = try store.validate(
            id: args["observation_id"] as? String,
            scope: scope,
            target: current.reference.target
        )
        guard approved == nil || approved == AskObservationStore.boundTarget(reference)
        else { throw AskObservationError.needsObservation }
        let events = try Self.events(args, target: current)
        try authorize()
        try environment.activate()
        try await environment.pause(.milliseconds(200))
        try Task.checkCancellation()
        try authorize()
        guard environment.isActive(),
              try environment.target().reference.target == current.reference.target
        else { throw AskObservationError.needsObservation }
        _ = try store.consume(id: reference.id, scope: scope, target: current.reference.target)
        var sent = false
        var release: CGEvent?
        // Release never awaits or checks cancellation/approval: once down is sent,
        // cleanup is mandatory even if the window, grant or task changes.
        defer {
            if let release {
                environment.post(release)
            }
        }
        do {
            for batch in events {
                try Task.checkCancellation()
                try authorize()
                guard environment.isActive(),
                      try environment.target().dispatchIdentity == current.dispatchIdentity
                else { throw AskObservationError.needsObservation }
                for event in batch.events {
                    if let cleanup = batch.release {
                        release = cleanup
                    }
                    environment.post(event); sent = true
                }
                if batch.clearsRelease {
                    release = nil
                }
                if let delay = batch.delay {
                    try await environment.pause(delay)
                }
            }
            return AskActionReceipt(
                outcome: .init(status: "ok", eventDispatched: sent, effectVerified: false),
                message: "Input dispatched. Observe again to verify the application or business effect."
            ).output()
        } catch {
            if !sent {
                throw error
            }
            return AskActionReceipt(
                outcome: .init(status: "unknown", eventDispatched: true, effectVerified: false),
                message: "Input was partially dispatched; held input was released. " +
                        "Observe and reconcile; do not replay."
            ).output()
        }
    }

    struct Batch {
        var events: [CGEvent]
        var release: CGEvent?
        var clearsRelease = false
        var delay: Duration?
    }

    // Construct all events before the first post so allocation/argument failures
    // cannot strand a pressed key or mouse button.
    // One exhaustive action switch constructs events before any are posted.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func events(_ args: [String: Any], target: Target) throws -> [Batch] {
        func point(_ xKey: String, _ yKey: String) throws -> CGPoint {
            guard let horizontal = args[xKey] as? Double ?? (args[xKey] as? Int).map(Double.init),
                  let vertical = args[yKey] as? Double ?? (args[yKey] as? Int).map(Double.init),
                  let position = AskDesktopActions.point(x: horizontal, y: vertical, in: target.bounds),
                  target.window.contains(position) else { throw AskObservationError.invalid }
            return position
        }
        func mouse(_ type: CGEventType, _ position: CGPoint, _ button: CGMouseButton = .left,
                   _ clicks: Int64 = 1) throws -> CGEvent {
            guard let event = CGEvent(
                mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: position,
                mouseButton: button
            ) else { throw AskObservationError.invalid }
            event.setIntegerValueField(.mouseEventClickState, value: clicks)
            return event
        }
        func key(_ key: CGKeyCode, flags: CGEventFlags = [], text: [UniChar]? = nil) throws -> Batch {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
                  let released = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
            else { throw AskObservationError.invalid }
            for event in [down, released] {
                event.flags = flags
                if let text {
                    text.withUnsafeBufferPointer { event.keyboardSetUnicodeString(
                        stringLength: text.count,
                        unicodeString: $0.baseAddress!
                    ) }
                }
            }
            return Batch(events: [down, released])
        }
        switch args["action"] as? String {
        case "click", "double_click", "right_click":
            let position = try point("x", "y"), right = args["action"] as? String == "right_click"
            let clicks = try (1 ... (args["action"] as? String == "double_click" ? 2 : 1)).flatMap { clicks in
                try [mouse(right ? .rightMouseDown : .leftMouseDown, position, right ? .right : .left, Int64(clicks)),
                     mouse(right ? .rightMouseUp : .leftMouseUp, position, right ? .right : .left, Int64(clicks))]
            }
            return [.init(events: clicks)]
        case "drag":
            let from = try point("x", "y"), destination = try point("to_x", "to_y")
            var batches = try [Batch(events: [mouse(.leftMouseDown, from)], release: mouse(.leftMouseUp, from))]
            for step in 1 ... 12 {
                let fraction = CGFloat(step) / 12, position = CGPoint(
                    x: from.x + (destination.x - from.x) * fraction,
                    y: from.y + (destination.y - from.y) * fraction
                )
                try batches.append(.init(
                    events: [mouse(.leftMouseDragged, position)],
                    release: mouse(.leftMouseUp, position),
                    delay: .milliseconds(15)
                ))
            }
            try batches.append(.init(events: [mouse(.leftMouseUp, destination)], clearsRelease: true))
            return batches
        case "type":
            guard let text = args["text"] as? String, !text.isEmpty,
                  text.utf16.count <= 10000 else { throw AskObservationError.invalid }
            let chars = Array(text.utf16)
            var batches: [Batch] = [], offset = 0
            while offset < chars.count {
                var end = min(chars.count, offset + 20)
                if end < chars.count, (0xD800 ... 0xDBFF).contains(chars[end - 1]) {
                    end -= 1
                }
                var batch = try key(0, text: Array(chars[offset ..< end])); batch.delay = .zero
                batches.append(batch); offset = end
            }
            return batches
        case "key":
            guard let name = (args["key"] as? String)?.lowercased(),
                  let code = AskDesktopActions.keyCodes[name] else { throw AskObservationError.invalid }
            return try [key(code)]
        case "hotkey":
            guard let shortcut = AskDesktopActions.parseHotkey(args["keys"] as? String ?? args["key"] as? String ?? "")
            else { throw AskObservationError.invalid }
            return try [key(shortcut.key, flags: shortcut.flags)]
        case "scroll":
            guard let amount = args["amount"] as? Int, (-10 ... 10).contains(amount),
                  let event = CGEvent(
                      scrollWheelEvent2Source: nil,
                      units: .line,
                      wheelCount: 1,
                      wheel1: Int32(amount),
                      wheel2: 0,
                      wheel3: 0
                  ) else { throw AskObservationError.invalid }
            // A scroll event acts at the pointer, so pin it inside the observed window.
            let position = try point("x", "y")
            event.location = position
            return try [.init(events: [mouse(.mouseMoved, position), event])]
        default: throw AskObservationError.invalid
        }
    }
}
