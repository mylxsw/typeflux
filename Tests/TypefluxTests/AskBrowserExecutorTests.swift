import AppKit
import Testing
@testable import Typeflux

@MainActor
final class ObservationScriptRunner: ProcessCommandRunning {
    var stamp = "12\u{1f}34\u{1f}https://example.invalid/\u{1f}1800000000"
    var scripts: [String] = []
    var result = #"{"status":"ok","message":"Dispatched","event_dispatched":true,"effect_verified":false}"#
    var corruptCapture = false
    var failAction = false
    var onCapture: () -> Void = {}
    var onTarget: () -> Void = {}
    func run(
        executablePath _: String,
        arguments: [String],
        environment _: [String: String]?,
        currentDirectoryURL _: URL?
    ) async throws -> ProcessCommandResult {
        let script = arguments.last!
        scripts.append(script)
        let output: String
        if script.contains("const observationID=") {
            onCapture()
            let id = script.range(of: "[A-F0-9]{8}-[A-F0-9-]{27}", options: .regularExpression)
                .map { String(script[$0]) } ?? "missing"
            output = corruptCapture ? "bad" : "{\"observation_id\":\"\(id)\"}"
        } else if script.contains("return state.run") {
            if failAction {
                throw CancellationError()
            }
            output = result
        } else {
            onTarget(); output = stamp
        }
        return .init(stdout: output, stderr: "", exitCode: 0)
    }
}

@Suite("Browser observation execution")
@MainActor
struct AskBrowserExecutorTests {
    let scope = AskObservationStore.Scope(owner: "o", conversation: "c", tool: "browser")
    let bundle = "com.apple.Safari"

    func setup() -> (AskBrowserExecutor, ObservationScriptRunner) {
        let runner = ObservationScriptRunner()
        let executor = AskBrowserExecutor(store: .init(), runner: runner)
        executor.processInstance = { _ in "42:1800000000" }
        return (executor, runner)
    }

    func observe(_ executor: AskBrowserExecutor) async throws -> String {
        let result = try await executor.execute(["action": "snapshot"], bundle: bundle, scope: scope)
        let object = try JSONSerialization.jsonObject(with: Data(result.content.utf8)) as! [String: Any]
        return (object["observation"] as! [String: Any])["id"] as! String
    }

    @Test func `enabled writes require local observation and single use`() async throws {
        let (executor, runner) = setup()
        let id = try await observe(executor)
        let args: [String: Any] = ["action": "click", "ref": id + ":1", "observation_id": id]
        await #expect(throws: AskObservationError.disabled) { try await executor.binding(
            args,
            bundle: bundle,
            scope: scope
        ) }
        await #expect(throws: AskObservationError.disabled) { try await executor.execute(
            args,
            bundle: bundle,
            scope: scope
        ) }
        executor.writesEnabled = true
        let binding = try await executor.binding(args, bundle: bundle, scope: scope)
        var checks = 0
        let result = try await executor.execute(args, bundle: bundle, scope: scope, approved: binding) { checks += 1 }
        #expect(!result.isError); #expect(checks == 1)
        let dispatched = try #require(runner.scripts.last)
        #expect(dispatched.contains("in approvedTab"))
        #expect(dispatched.contains("if stamp is not"))
        await #expect(throws: AskObservationError.needsObservation) { try await executor.execute(
            args,
            bundle: bundle,
            scope: scope
        ) }
    }

    @Test(arguments: [0, 1, 2, 3, 4])
    func `target changes refuse old observation`(_ field: Int) async throws {
        let (executor, runner) = setup()
        executor.writesEnabled = true
        let id = try await observe(executor)
        if field < 4 {
            var fields = runner.stamp.split(separator: "\u{1f}").map(String.init)
            fields[field] += "changed"; runner.stamp = fields.joined(separator: "\u{1f}")
        } else {
            executor.processInstance = { _ in "43:new launch" }
        }
        await #expect(throws: AskObservationError.needsObservation) {
            try await executor.execute(["action": "back", "observation_id": id], bundle: bundle, scope: scope)
        }
        #expect(!runner.scripts.contains { $0.contains("return state.run") })
    }

    @Test func `capture and approval races fail closed`() async throws {
        let (executor, runner) = setup()
        let target = try await executor.binding(["action": "read"], bundle: bundle, scope: scope)
        runner.stamp += "new"
        await #expect(throws: AskObservationError.needsObservation) { try await executor.execute(
            ["action": "read"],
            bundle: bundle,
            scope: scope,
            approved: target
        ) }
        runner.onCapture = { runner.stamp += "changed" }
        await #expect(throws: AskObservationError.needsObservation) { try await observe(executor) }
        runner.onCapture = {}; runner.corruptCapture = true
        await #expect(throws: (any Error).self) { try await observe(executor) }
        runner.corruptCapture = false
        let id = try await observe(executor)
        executor.writesEnabled = true
        let args: [String: Any] = ["action": "back", "observation_id": id]
        await #expect(throws: AskObservationError.needsObservation) { try await executor.execute(
            args,
            bundle: bundle,
            scope: scope,
            approved: target
        ) }
        await #expect(throws: AskObservationError.invalid) {
            try await executor.execute(args, bundle: bundle, scope: scope) { throw AskObservationError.invalid }
        }
        #expect(!runner.scripts.contains { $0.contains("return state.run") })
    }

    @Test func `interrupted and malformed dispatch remain unknown without replay`() async throws {
        for malformed in [false, true] {
            let (executor, runner) = setup()
            executor.writesEnabled = true
            let id = try await observe(executor)
            runner.failAction = !malformed; runner.result = "Element not found"
            let args: [String: Any] = ["action": "back", "observation_id": id]
            let result = try await executor.execute(args, bundle: bundle, scope: scope)
            #expect(result.isError); #expect(result.content.contains("unknown"))
            await #expect(throws: AskObservationError.needsObservation) { try await executor.execute(
                args,
                bundle: bundle,
                scope: scope
            ) }
        }
    }

    @Test func `unavailable evidence and malformed arguments`() async throws {
        let (executor, runner) = setup()
        executor.processInstance = { _ in nil }
        await #expect(throws: AskObservationError.needsObservation) { try await executor.target(bundle: bundle) }
        executor.processInstance = { _ in "42:1" }; runner.stamp = "invalid"
        await #expect(throws: AskObservationError.needsObservation) { try await executor.target(bundle: bundle) }
        for args: [String: Any] in [["action": "click", "ref": 1], ["action": "fill", "ref": "v:1"],
                                    ["action": "scroll", "amount": 11], ["action": "open", "url": "file:///tmp/test"],
                                    ["action": "unknown"]] {
            #expect(throws: AskObservationError.invalid) { try AskBrowserExecutor.command(args) }
        }
        for args: [String: Any] in [
            ["action": "click", "selector": "#test"],
            ["action": "fill", "ref": "v:1", "text": "x'\n🙂"],
            ["action": "scroll", "amount": -1],
            ["action": "open", "url": "https://example.invalid"],
            ["action": "back"]
        ] {
            #expect(try !(AskBrowserExecutor.command(args)).isEmpty)
        }
        let chrome = AskBrowserExecutor.appleScript(
            bundle: "com.google.Chrome",
            expected: "1\u{1f}2\u{1f}url\u{1f}3",
            javascript: "'result'"
        )
        #expect(chrome.contains("id of approvedTab")); #expect(chrome.contains("execute approvedTab javascript"))
        #expect(AskBrowserExecutor.appleScript(bundle: bundle, expected: "broken", javascript: "x")
            .contains("needs-observation"))
        #expect(try AskBrowserExecutor
            .receipt(
                #"{"status":"invalid","message":"Element not found","event_dispatched":false,"effect_verified":false}"#
            )
            .output().isError)
    }
}
