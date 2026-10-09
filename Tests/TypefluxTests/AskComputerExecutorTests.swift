import AppKit
import Testing
@testable import Typeflux

@Suite("Computer observation execution", .exclusiveUIState)
@MainActor
struct AskComputerExecutorTests {
    let scope = AskObservationStore.Scope(owner: "o", conversation: "c", tool: "computer")

    final class Desktop {
        var current = AskComputerExecutor.Target(
            reference: .init(
                id: "",
                target: .init(kind: "desktop_window", id: "pid:window", version: "launch:display:tree"),
                capturedAt: Date(),
                pid: 42
            ),
            display: 1, bounds: CGRect(x: 100, y: 100, width: 1001, height: 1001),
            window: CGRect(x: 150, y: 150, width: 900, height: 900), description: "Button",
            dispatchIdentity: "window/display/focus"
        )
        var events: [CGEvent] = []
        var active = true
        var onPause: (Duration) throws -> Void = { _ in }
        var onPost: (CGEvent) -> Void = { _ in }
        var unavailable = false
        var shotDisplay: UInt32 = 1
        var onCapture: () -> Void = {}
        var environment: AskComputerExecutor.Environment {
            .init(target: {
                      if self.unavailable {
                          throw AskObservationError.needsObservation
                      }; return self.current
                  },
                  activate: {}, isActive: { self.active }, screenshot: { _ in
                      self.onCapture()
                      return .init(dataURL: "image", displayId: self.shotDisplay, width: 100, height: 100)
                  }, post: { self.events.append($0); self.onPost($0) }, pause: { try self.onPause($0) })
        }
    }

    func prepared(_ executor: AskComputerExecutor, _ desktop: Desktop,
                  action: String = "click") async throws -> [String: Any] {
        let output = try await executor.execute(["action": "inspect"], scope: scope, environment: desktop.environment)
        let projection = try JSONSerialization.jsonObject(with: Data(output.content.utf8)) as! [String: Any]
        let id = (projection["observation"] as! [String: Any])["id"] as! String
        return ["action": action, "observation_id": id, "x": 0.2, "y": 0.2, "to_x": 0.6, "to_y": 0.6]
    }

    @Test func `refuses writes by default and consumes successful observation`() async throws {
        let executor = AskComputerExecutor(store: .init()), desktop = Desktop()
        var args = try await prepared(executor, desktop)
        #expect(throws: AskObservationError.disabled) { try executor.binding(
            args,
            scope: scope,
            environment: desktop.environment
        ) }
        await #expect(throws: AskObservationError.disabled) { try await executor.execute(
            args,
            scope: scope,
            environment: desktop.environment
        ) }
        executor.writesEnabled = true
        let binding = try executor.binding(args, scope: scope, environment: desktop.environment)
        var checks = 0
        let result = try await executor.execute(
            args,
            scope: scope,
            environment: desktop.environment,
            approved: binding
        ) { checks += 1 }
        #expect(!result.isError); #expect(checks >= 3)
        #expect(result.content.contains("\"effect_verified\":false"))
        #expect(desktop.events.map(\.type) == [.leftMouseDown, .leftMouseUp])
        await #expect(throws: AskObservationError.needsObservation) { try await executor.execute(
            args,
            scope: scope,
            environment: desktop.environment
        ) }
        args["observation_id"] = "forged"
        await #expect(throws: AskObservationError.needsObservation) { try await executor.execute(
            args,
            scope: scope,
            environment: desktop.environment
        ) }
    }

    @Test(arguments: ["process exit", "window", "display", "coordinates", "redraw", "focus"])
    func `changes reject before dispatch`(_ change: String) async throws {
        let executor = AskComputerExecutor(store: .init()), desktop = Desktop()
        executor.writesEnabled = true
        let args = try await prepared(executor, desktop)
        let binding = try executor.binding(args, scope: scope, environment: desktop.environment)
        if change == "process exit" {
            desktop.unavailable = true
        } else {
            desktop.current.reference.target.version = change
        }
        await #expect(throws: AskObservationError.needsObservation) {
            try await executor.execute(args, scope: scope, environment: desktop.environment, approved: binding)
        }
        #expect(desktop.events.isEmpty)
    }

    @Test func `capture must complete against same display and window`() async throws {
        let executor = AskComputerExecutor(store: .init()), desktop = Desktop()
        let binding = try executor.binding(["action": "screenshot"], scope: scope, environment: desktop.environment)
        let result = try await executor.execute(
            ["action": "screenshot"],
            scope: scope,
            environment: desktop.environment,
            approved: binding
        )
        #expect(result.image == "image"); #expect(result.content.contains("captured_at"))
        desktop.shotDisplay = 2
        await #expect(throws: AskObservationError.needsObservation) { try await executor.execute(
            ["action": "screenshot"],
            scope: scope,
            environment: desktop.environment
        ) }
        desktop.shotDisplay = 1
        desktop.onCapture = { desktop.current.reference.target.version = "moved" }
        await #expect(throws: AskObservationError.needsObservation) { try await executor.execute(
            ["action": "screenshot"],
            scope: scope,
            environment: desktop.environment
        ) }
        await #expect(throws: AskObservationError.needsObservation) { try await executor.execute(
            ["action": "inspect"],
            scope: scope,
            environment: desktop.environment,
            approved: binding
        ) }
    }

    @Test(arguments: ["cancel", "revoke", "focus", "target"])
    func `interrupted drag always releases at last position`(_ reason: String) async throws {
        let executor = AskComputerExecutor(store: .init()), desktop = Desktop()
        executor.writesEnabled = true
        let args = try await prepared(executor, desktop, action: "drag")
        var revoked = false
        desktop.onPause = { delay in
            if delay == .milliseconds(15) {
                switch reason {
                case "cancel": throw CancellationError()
                case "revoke": revoked = true
                case "focus": desktop.active = false
                default: desktop.current.dispatchIdentity = "different window"
                }
            }
        }
        let result = try await executor.execute(args, scope: scope, environment: desktop.environment) {
            if revoked {
                throw AskObservationError.invalid
            }
        }
        #expect(result.isError); #expect(result.content.contains("unknown"))
        #expect(desktop.events.first?.type == .leftMouseDown)
        #expect(desktop.events.last?.type == .leftMouseUp)
        #expect(desktop.events.last?.location == desktop.events.dropLast().last?.location)
        #expect(desktop.events.filter { $0.type == .leftMouseUp }.count == 1)
    }

    @Test func `task cancellation runs cleanup and cannot replay`() async throws {
        let executor = AskComputerExecutor(store: .init()), desktop = Desktop()
        executor.writesEnabled = true
        let args = try await prepared(executor, desktop, action: "drag")
        var task: Task<AskLocalToolOutput, Error>!
        desktop.onPost = {
            if $0.type == .leftMouseDown {
                task.cancel()
            }
        }
        task = Task { try await executor.execute(args, scope: scope, environment: desktop.environment) }
        let result = try await task.value
        #expect(result.isError)
        #expect(desktop.events.map(\.type) == [.leftMouseDown, .leftMouseUp])
        await #expect(throws: AskObservationError.needsObservation) { try await executor.execute(
            args,
            scope: scope,
            environment: desktop.environment
        ) }
    }

    @Test func `changed or revoked while activating sends nothing`() async throws {
        let executor = AskComputerExecutor(store: .init()), desktop = Desktop()
        executor.writesEnabled = true
        let args = try await prepared(executor, desktop)
        desktop.onPause = { _ in desktop.current.reference.target.version = "new" }
        await #expect(throws: AskObservationError.needsObservation) { try await executor.execute(
            args,
            scope: scope,
            environment: desktop.environment
        ) }
        #expect(desktop.events.isEmpty)
        let fresh = try await prepared(executor, desktop)
        var checks = 0
        desktop.onPause = { _ in }
        await #expect(throws: AskObservationError.invalid) {
            try await executor.execute(fresh, scope: scope, environment: desktop.environment) {
                checks += 1; if checks == 2 {
                    throw AskObservationError.invalid
                }
            }
        }
        #expect(desktop.events.isEmpty)
        var other = desktop.current.reference.target; other.id = "other"
        await #expect(throws: AskObservationError.needsObservation) { try await executor.execute(
            fresh,
            scope: scope,
            environment: desktop.environment,
            approved: other
        ) }
    }

    @Test func `all supported events and invalid coordinates`() async throws {
        let executor = AskComputerExecutor(store: .init()), desktop = Desktop()
        executor.writesEnabled = true
        for action in ["double_click", "right_click", "drag", "type", "key", "hotkey", "scroll"] {
            var args = try await prepared(executor, desktop, action: action)
            args["text"] = String(repeating: "a", count: 19) +
                String(repeating: "🙂",
                       count: 25); args["key"] = "enter"; args["keys"] = "cmd+shift+t"; args["amount"] = -2
            let result = try await executor.execute(args, scope: scope, environment: desktop.environment)
            #expect(!result.isError)
        }
        let scroll = try AskComputerExecutor.events(
            ["action": "scroll", "amount": 1, "x": 0.2, "y": 0.2],
            target: desktop.current
        )
        #expect(scroll[0].events.last?.location == CGPoint(x: 300, y: 300))
        for args: [String: Any] in [["action": "click", "x": 0, "y": 0], ["action": "click", "x": Double.nan, "y": 0.5],
                                    ["action": "click"], ["action": "type"], ["action": "type", "text": ""], [
                                        "action": "key",
                                        "key": "unknown"
                                    ],
                                    ["action": "hotkey", "keys": "hyper+c"], ["action": "scroll", "amount": 12],
                                    ["action": "unknown"]] {
            #expect(throws: AskObservationError.invalid) {
                try AskComputerExecutor.events(args, target: desktop.current)
            }
        }
        #expect(try executor.binding(["action": "wait"], scope: scope, environment: desktop.environment).id == "c")
        #expect(try await executor.execute(
            ["action": "wait", "seconds": 0],
            scope: scope,
            environment: desktop.environment
        ).content == "Waited 0.0 s.")
        await #expect(throws: AskObservationError.invalid) { try await executor.execute(
            ["action": "wait", "seconds": Double.infinity],
            scope: scope,
            environment: desktop.environment
        ) }
    }

    @Test func `native probe does not accept unavailable app and fingerprint includes geometry`() throws {
        let probe = AskComputerTargetProbe()
        #expect(throws: (any Error).self) { try probe.target(app: nil) }
        #expect(throws: (any Error).self) { try probe.environment(app: nil).activate() }
        #expect(!probe.environment(app: nil).isActive())
        var node = AskDesktopActions.Node(role: "AXWindow", name: "a:b", value: "c", frame: .zero)
        let original = AskComputerTargetProbe.fingerprint(node)
        node.frame = CGRect(x: 0.00001, y: 0, width: 1, height: 1)
        #expect(AskComputerTargetProbe.fingerprint(node) != original)
        #expect(try !(AskComputerTargetProbe.displayTopology()).isEmpty)
    }
}
