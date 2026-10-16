import Darwin
import Foundation
import Testing
@testable import Typeflux

@Suite("Native command protocol and adapters", .serialized)
struct NativeSystemProtocolTests {
    @Test func versionIdentityOperationAndSizeAreValidated() throws {
        let request = NativeSystemRequest(operation: .toggleWiFi)
        #expect(try NativeSystemProtocol.decodeRequest(JSONEncoder().encode(request)).requestID == request.requestID)
        var response = NativeSystemResponse(requestID: request.requestID, operation: request.operation, outcome: .completed)
        #expect(try NativeSystemProtocol.decodeResponse(JSONEncoder().encode(response), for: request) == .completed)
        response.requestID = UUID()
        #expect(throws: NativeSystemFailure.unknown) {
            try NativeSystemProtocol.decodeResponse(JSONEncoder().encode(response), for: request)
        }
        response.requestID = request.requestID; response.operation = .toggleBluetooth
        #expect(throws: NativeSystemFailure.unknown) {
            try NativeSystemProtocol.decodeResponse(JSONEncoder().encode(response), for: request)
        }
        response.operation = request.operation; response.version = 2
        #expect(throws: NativeSystemFailure.unknown) {
            try NativeSystemProtocol.decodeResponse(JSONEncoder().encode(response), for: request)
        }
        var unsupported = request; unsupported.version = 2
        for data in [try JSONEncoder().encode(unsupported), Data(repeating: 32, count: 1025), Data("{}".utf8),
                     Data("{\"version\":1,\"operation\":\"shutdown\"}".utf8)] {
            #expect(throws: (any Error).self) { try NativeSystemProtocol.decodeRequest(data) }
        }
        #expect(throws: NativeSystemFailure.unknown) {
            try NativeSystemProtocol.decodeResponse(Data(repeating: 32, count: 1025), for: request)
        }
    }

    @Test func settersRunOnceAndFailuresAfterEntryRemainUnknown() {
        for operation in NativeSystemOperation.allCases where operation != .probe {
            var value = false, writes = 0, notices = 0, reads = 0
            let control = NativeSystemAdapter.Control(read: { reads += 1; return value }, write: { value = $0; writes += 1 })
            let adapter = NativeSystemAdapter(wifi: { control }, bluetooth: { control }, scroll: { control },
                                              sleep: { _ in }, notifyScrollChange: { notices += 1 })
            #expect(adapter.execute(operation) == .completed)
            #expect(writes == 1 && reads == 2 && value)
            #expect(notices == (operation == .toggleScrollDirection ? 1 : 0))
        }
        var writes = 0
        let failure = NativeSystemFailure.notExecuted
        var adapter = NativeSystemAdapter(wifi: { throw failure })
        #expect(adapter.execute(.toggleWiFi) == .notExecuted)
        adapter.wifi = { .init(read: { throw failure }, write: { _ in writes += 1 }) }
        #expect(adapter.execute(.toggleWiFi) == .notExecuted && writes == 0)
        adapter.wifi = { .init(read: { false }, write: { _ in writes += 1; throw failure }) }
        #expect(adapter.execute(.toggleWiFi) == .unknown && writes == 1)
        var reads = 0
        adapter.wifi = { .init(read: { reads += 1; if reads > 1 { throw failure }; return false }, write: { _ in }) }
        #expect(adapter.execute(.toggleWiFi) == .unknown)
        var sleeps = 0
        adapter.bluetooth = { .init(read: { false }, write: { _ in writes += 1 }) }
        adapter.sleep = { _ in sleeps += 1 }
        #expect(adapter.execute(.toggleBluetooth) == .unknown && sleeps == 20 && writes == 2)
        #expect(adapter.execute(.probe) == .completed && writes == 2)
    }

    @Test func dynamicBindingsRetainLibrariesAndUseCorrectFunctionTypes() throws {
        let symbols = HarmlessNativeSymbols()
        var bluetooth: NativeSystemAdapter.Control? = try NativeSystemAdapter.bluetoothControl(library: symbols)
        try bluetooth?.write(true)
        #expect(try bluetooth?.read() == true)
        try bluetooth?.write(false)
        #expect(try bluetooth?.read() == false)
        let scroll = try NativeSystemAdapter.scrollControl(library: symbols)
        try scroll.write(true)
        #expect(try scroll.read())
        try scroll.write(false)
        #expect(try !scroll.read())
        symbols.missing = true
        #expect(throws: (any Error).self) { try NativeSystemAdapter.bluetoothControl(library: symbols) }
        #expect(throws: (any Error).self) { try NativeSystemAdapter.scrollControl(library: symbols) }
        bluetooth = nil
        #expect(throws: (any Error).self) { try NativeSystemLibrary(path: "/nonexistent/typeflux-native-fixture") }
        let library = try NativeSystemLibrary(path: "/usr/lib/libSystem.B.dylib")
        _ = try library.symbol("getpid") // Resolve only; never call a system mutation.
        #expect(throws: (any Error).self) { try library.symbol("typeflux_missing_fixture_symbol") }
    }

    @Test func childEntryRejectsUntrustedInputBeforeCallingAdapters() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var writes = 0, value = false
        let control = NativeSystemAdapter.Control(read: { value }, write: { value = $0; writes += 1 })
        let adapter = NativeSystemAdapter(wifi: { control }, bluetooth: { control }, scroll: { control }, sleep: { _ in },
                                          notifyScrollChange: {})
        func run(_ data: Data, arguments: [String] = []) throws -> (Int32, Data) {
            let source = root.appendingPathComponent("input"), destination = root.appendingPathComponent("output")
            try data.write(to: source); try Data().write(to: destination)
            let input = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: destination)
            defer { try? input.close(); try? output.close() }
            let code = NativeSystemWorkerCommand.run(arguments: arguments, input: input, output: output, adapter: adapter)
            return (code, try Data(contentsOf: destination))
        }
        for operation in NativeSystemOperation.allCases {
            let request = NativeSystemRequest(operation: operation)
            let result = try run(JSONEncoder().encode(request))
            #expect(result.0 == 0)
            #expect(try NativeSystemProtocol.decodeResponse(result.1, for: request) == .completed)
        }
        #expect(writes == 3)
        for data in [Data(), Data("private invalid input".utf8), Data(repeating: 32, count: 1025)] {
            let result = try run(data)
            #expect(result.0 == 2 && result.1.isEmpty)
        }
        #expect(try run(Data(), arguments: ["unexpected"]).0 == 2)
        #expect(NativeSystemWorkerCommand.run(arguments: ["unexpected"]) == 2)
        #expect(NativeSystemWorkerCommand.handleInvocation(arguments: []) == nil)
        #expect(NativeSystemWorkerCommand.handleInvocation(arguments: ["unrelated"]) == nil)
        #expect(NativeSystemWorkerCommand.handleInvocation(arguments: ["native-system-worker", "unexpected"]) == 2)
        #expect(writes == 3)
    }
}

private final class HarmlessNativeSymbols: NativeSystemSymbols {
    static var value = false
    var missing = false
    func symbol(_ name: String) throws -> UnsafeMutableRawPointer {
        if missing { throw NativeSystemFailure.notExecuted }
        switch name {
        case "IOBluetoothPreferenceGetControllerPowerState":
            return unsafeBitCast(({ HarmlessNativeSymbols.value ? 1 : 0 } as @convention(c) () -> Int32), to: UnsafeMutableRawPointer.self)
        case "IOBluetoothPreferenceSetControllerPowerState":
            return unsafeBitCast(({ HarmlessNativeSymbols.value = $0 != 0 } as @convention(c) (Int32) -> Void), to: UnsafeMutableRawPointer.self)
        case "swipeScrollDirection":
            return unsafeBitCast(({ HarmlessNativeSymbols.value } as @convention(c) () -> Bool), to: UnsafeMutableRawPointer.self)
        default:
            return unsafeBitCast(({ HarmlessNativeSymbols.value = $0 } as @convention(c) (Bool) -> Void), to: UnsafeMutableRawPointer.self)
        }
    }
}

@Suite("Isolated native command lifecycle", .exclusiveUIState)
@MainActor
struct NativeSystemWorkerTests {
    private typealias UI = SettingsBehaviorTestSupport
    private let reply = "sed 's/}$/ ,\"outcome\":\"completed\"}/'"

    @Test func timedOutUnretiredChildPreventsReplacementUntilReaperConfirmsExit() async throws {
        final class Unretired: @unchecked Sendable {
            let lock = NSLock()
            var calls = 0
            var retired: (@Sendable () -> Void)?
            func run(_ request: ManagedProcess.Request) throws -> ManagedProcess.Result {
                lock.withLock { calls += 1 }
                request.onStarted?()
                if lock.withLock({ calls == 1 }) {
                    lock.withLock { retired = request.onReaped }
                    return .init(termination: .timedOut, exitCode: 137, stdout: "", stderr: "", outputTruncated: false)
                }
                let decoded = try NativeSystemProtocol.decodeRequest(request.stdin!)
                let response = NativeSystemResponse(requestID: decoded.requestID, operation: decoded.operation, outcome: .completed)
                request.onReaped?()
                return .init(termination: .exited(0), exitCode: 0,
                             stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self),
                             stderr: "", outputTruncated: false)
            }
            func finish() { lock.withLock { retired }?() }
        }
        let child = Unretired()
        var now = 0.0
        let worker = NativeSystemWorker(uptime: { now }, run: { try child.run($0) })
        await #expect(throws: NativeSystemFailure.unknown) { try await worker.perform(.toggleWiFi) }
        now = 301
        await #expect(throws: NativeSystemFailure.busy) { try await worker.perform(.toggleWiFi) }
        #expect(child.lock.withLock { child.calls } == 1)
        child.finish()
        try await worker.perform(.toggleWiFi)
        #expect(child.lock.withLock { child.calls } == 2)
        await worker.shutdown()
    }

    @Test func realCLIProbeAndFreshDisposableProcessesCompleteWithoutSystemEffects() async throws {
        let worker = NativeSystemWorker(timeout: 15)
        try await worker.perform(.probe)
        try await worker.perform(.probe)
        await worker.shutdown()
        await #expect(throws: NativeSystemFailure.disabled) { try await worker.perform(.probe) }
    }

    @Test func crashDoesNotReplayAndNewExplicitCommandRecoversAfterCooldown() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        var now = 0.0
        let worker = NativeSystemWorker(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c",
            "if [ ! -f \"$1\" ]; then printf x > \"$1\"; kill -KILL $$; fi; " + reply, "fixture", marker.path],
            uptime: { now })
        await #expect(throws: NativeSystemFailure.unknown) { try await worker.perform(.toggleWiFi) }
        await #expect(throws: NativeSystemFailure.coolingDown) { try await worker.perform(.toggleWiFi) }
        #expect(try String(contentsOf: marker) == "x")
        now = 301
        try await worker.perform(.toggleWiFi)
        #expect(try String(contentsOf: marker) == "x")
        await worker.shutdown()
    }

    @Test func malformedAndMismatchedRepliesAreUnknownWithoutRawOutput() async {
        for script in ["printf private-error", "exit 7", "sed 's/}$/ ,\"outcome\":\"unknown\"}/'",
                       "sed 's/}$/ ,\"outcome\":\"notExecuted\"}/'", reply + " | sed 's/\"version\":1/\"version\":99/'",
                       "while :; do printf 'private output flood'; done"] {
            let worker = NativeSystemWorker(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
            let expected: NativeSystemFailure = script.contains("notExecuted") ? .notExecuted : .unknown
            await #expect(throws: expected) { try await worker.perform(.toggleBluetooth) }
            await worker.shutdown()
        }
        let missing = NativeSystemWorker(executable: URL(fileURLWithPath: "/missing/typeflux-fixture"))
        await #expect(throws: NativeSystemFailure.notExecuted) { try await missing.perform(.probe) }
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: NativeSystemFailure.notExecuted) { try await missing.perform(.probe) }
        }
        await cancelled.value
    }

    @Test func timeoutCancellationBusyAndShutdownBoundOwnedChildLifetime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for mode in ["timeout", "cancel", "shutdown"] {
            let marker = root.appendingPathComponent(mode)
            let worker = NativeSystemWorker(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c",
                "echo $$ > \"$1\"; trap '' TERM; while :; do sleep 1; done", "fixture", marker.path],
                timeout: mode == "timeout" ? 0.2 : 5)
            let began = ContinuousClock.now
            let task = Task { try await worker.perform(.toggleScrollDirection) }
            try await UI.wait { FileManager.default.fileExists(atPath: marker.path) }
            await #expect(throws: NativeSystemFailure.busy) { try await worker.perform(.probe) }
            if mode == "cancel" { task.cancel() }
            if mode == "shutdown" { await worker.shutdown() }
            await #expect(throws: NativeSystemFailure.unknown) { try await task.value }
            #expect(began.duration(to: .now) < .seconds(3))
            let pid = try #require(Int32(String(contentsOf: marker).trimmingCharacters(in: .whitespacesAndNewlines)))
            try await UI.wait { kill(pid, 0) != 0 && errno == ESRCH }
            await worker.shutdown()
        }
    }

    @Test func launcherRoutesOnlyNativeAllowlistAndNeverOffersAutomaticRetry() async throws {
        final class Fake: NativeSystemWorking {
            var isEnabled = true
            var calls: [NativeSystemOperation] = []
            var failure: Error?
            func perform(_ operation: NativeSystemOperation) async throws {
                calls.append(operation)
                if let failure { throw failure }
            }
        }
        let previous = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(previous) }
        for language in AppLanguage.allCases {
            AppLocalization.shared.setLanguage(language)
            for failure in [NativeSystemFailure.notExecuted, .unknown, .busy, .coolingDown, .disabled] {
                #expect(L(failure.messageKey) != failure.messageKey)
            }
        }
        let fake = Fake(), runner = AskSystemCommandRunner(native: fake)
        #expect(runner.presentsFailures(for: .toggleWiFi))
        for command in [AskSystemCommand.toggleWiFi, .toggleBluetooth, .toggleScrollDirection] {
            try await runner.run(command)
        }
        #expect(fake.calls == [.toggleWiFi, .toggleBluetooth, .toggleScrollDirection])
        for failure in [NativeSystemFailure.notExecuted, .unknown, .busy, .coolingDown, .disabled] {
            fake.failure = failure
            do { try await runner.run(.toggleWiFi); Issue.record("Expected visible failure") }
            catch let error as AskPluginFailure { #expect(error.message == L(failure.messageKey) && !error.retry) }
        }
        fake.failure = CocoaError(.fileReadUnknown)
        do { try await runner.run(.toggleWiFi); Issue.record("Expected redacted unknown outcome") }
        catch let error as AskPluginFailure { #expect(error.message == L(NativeSystemFailure.unknown.messageKey) && !error.retry) }
        #expect(fake.calls.count == 9)
        fake.isEnabled = false
        #expect(!runner.presentsFailures(for: .toggleWiFi))
        #expect(!runner.presentsFailures(for: .toggleBluetooth))
        #expect(!runner.presentsFailures(for: .toggleScrollDirection))
        #expect(runner.presentsFailures(for: .displaySleep))
    }
}
