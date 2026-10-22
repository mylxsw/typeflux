import Darwin
import Foundation
import Testing
import TypefluxChatWindowProtocol
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct ChatWindowClientTests {
    @Test func realChildRoundTripsPresentationWithoutOwningAnyExecutionState() async throws {
        let client = try chatWindowTestClient()
        defer { client.stop() }
        let started = ContinuousClock.now
        try await client.connect()
        print("CHAT_WINDOW_COLD_START \(started.duration(to: .now))")
        await #expect(throws: ChatWindowFailure.invalidProtocol) { try await client.connect() }
        try await client.present(.init(sequence: 1, title: "Fixture only", messages: [.init(role: .user, text: "Not a submission")]))
        try await client.ping()
        try await client.hide()
        await client.shutdown()
        await #expect(throws: ChatWindowFailure.unavailable) { try await client.ping() }
    }

    @Test func signedGUIBundleAndNormalStartupUseTheSameProtocol() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-window-bundle-" + UUID().uuidString)
        let contents = root.appendingPathComponent("Helper.app/Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = contents.appendingPathComponent("MacOS/TypefluxChatWindowHelper")
        try FileManager.default.copyItem(at: sourceRoot.appendingPathComponent(".build/debug/TypefluxChatWindowHelper"), to: binary)
        let infoData = try Data(contentsOf: sourceRoot.appendingPathComponent("app/ChatWindowHelper-Info.plist"))
        var info = try #require(try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any])
        info["CFBundleIdentifier"] = "example.typeflux.chat-window-test"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        defer { close(directory) }
        for args in [["--force", "--sign", "-", "--options", "runtime", contents.deletingLastPathComponent().path],
                     ["--verify", "--strict", contents.deletingLastPathComponent().path]] {
            let result = try await ManagedProcess().run(.init(executable: "/usr/bin/codesign", arguments: args,
                environment: ["PATH": "/usr/bin:/bin"], directoryDescriptor: directory, timeout: 10))
            #expect(result.exitCode == 0)
        }
        let client = try chatWindowTestClient(stall: nil, executable: binary)
        defer { client.stop() }
        try await client.connect()
        try await client.ping()
        await client.shutdown()
    }

    @Test func helperRejectsStandaloneOrMalformedInvocation() async throws {
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        defer { close(directory) }
        for arguments in [["--invalid"], ["--ipc-fd", "100"]] {
            let result = try await ManagedProcess().run(.init(executable: sourceRoot.appendingPathComponent(".build/debug/TypefluxChatWindowHelper").path,
                arguments: arguments, environment: ["PATH": "/usr/bin:/bin"], directoryDescriptor: directory, timeout: 5))
            #expect(result.exitCode == (arguments.count == 1 ? 64 : 70))
        }
    }

    @Test func timeoutAndCancellationRetireOnlyTheOwnedChild() async throws {
        for cancel in [false, true] {
            let client = try chatWindowTestClient(stall: 30)
            defer { client.stop() }
            try await client.connect()
            try await client.present(.init(sequence: 1, title: "Fixture only", messages: []))
            let start = ContinuousClock.now
            let task = Task { try await client.ping(timeout: cancel ? 40 : 0.1) }
            if cancel {
                try await Task.sleep(for: .milliseconds(50))
                task.cancel()
            }
            await #expect(throws: (any Error).self) { try await task.value }
            await client.stopAndWait()
            #expect(start.duration(to: .now) < .seconds(3))
            await #expect(throws: ChatWindowFailure.unavailable) { try await client.ping() }
        }
    }

    @Test func oneOutstandingRequestRejectsBacklogAndNeverReplays() async throws {
        let client = try chatWindowTestClient(stall: 0.5)
        defer { client.stop() }
        try await client.connect()
        try await client.present(.init(sequence: 1, title: "Fixture", messages: []))
        let first = Task { try await client.ping() }
        try await Task.sleep(for: .milliseconds(50))
        await #expect(throws: ChatWindowFailure.busy) { try await client.ping() }
        try await first.value
        await client.shutdown()
    }

    @Test func invalidDeadlinesPayloadsAndUnavailableLaunchFailClosed() async throws {
        #expect(throws: ChatWindowFailure.invalidProtocol) { try chatWindowTestClient(stall: .infinity) }
        let client = try chatWindowTestClient()
        defer { client.stop() }
        await #expect(throws: ChatWindowFailure.unavailable) { try await client.ping() }
        await #expect(throws: ChatWindowFailure.invalidProtocol) { try await client.connect(timeout: 0) }
        try await client.connect()
        await #expect(throws: ChatWindowFailure.invalidProtocol) { try await client.present(.init(sequence: 0, title: "Bad", messages: [])) }
        try await client.ping()
        await client.shutdown()
        let missing = try AskChatWindowClient(executable: URL(fileURLWithPath: "/nonexistent/typeflux-test-helper"))
        defer { missing.stop() }
        await #expect(throws: ChatWindowFailure.self) { try await missing.connect(timeout: 1) }
        await missing.stopAndWait()
        #expect(AskChatWindowClient.executableURL(appExecutable: URL(fileURLWithPath: "/Applications/Typeflux.app/Contents/MacOS/Typeflux")).path == "/Applications/Typeflux.app/Contents/Helpers/TypefluxChatWindowHelper.app/Contents/MacOS/TypefluxChatWindowHelper")
        #expect(AskChatWindowClient.executableURL(appExecutable: URL(fileURLWithPath: "/tmp/debug/Typeflux")).path == "/tmp/debug/TypefluxChatWindowHelper")
    }

    @Test func mismatchedResponsesRetireConnection() async throws {
        for field in ["id", "generation", "kind", "sequence"] {
            let client = try AskChatWindowClient(run: { request in
                let peer = try ChatWindowSocket(owning: dup(request.ipcDescriptor!))
                request.onStarted?()
                return try await Task.detached {
                    let hello = try peer.receive(deadline: .now.advanced(by: .seconds(2)))
                    var reply = ChatWindowEnvelope(generation: hello.generation, id: hello.id, kind: .ready)
                    switch field {
                    case "id": reply.id = UUID()
                    case "generation": reply.generation = UUID()
                    case "kind": reply.kind = .pong
                    default: reply.kind = .acknowledged; reply.sequence = 1
                    }
                    try peer.send(reply, deadline: .now.advanced(by: .seconds(2)))
                    // Keep the peer alive until the client rejects the response.
                    _ = try? peer.receive(deadline: .now.advanced(by: .seconds(2)))
                    return ManagedProcess.Result(termination: .exited(0), exitCode: 0, stdout: "", stderr: "", outputTruncated: false)
                }.value
            })
            await #expect(throws: ChatWindowFailure.invalidProtocol) { try await client.connect() }
            await client.stopAndWait()
        }
    }
}

func chatWindowTestClient(stall: TimeInterval? = 0, executable supplied: URL? = nil) throws -> AskChatWindowClient {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let executable = supplied ?? root.appendingPathComponent(".build/debug/TypefluxChatWindowHelper")
    let profiles = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TYPEFLUX_CHAT_WINDOW_PROFILE_DIR"] ?? NSTemporaryDirectory() + "typeflux-chat-window-profiles")
    try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
    return try AskChatWindowClient(executable: executable, probeStall: stall, run: { request in
        var request = request
        request.environment["LLVM_PROFILE_FILE"] = profiles.appendingPathComponent("helper-%p.profraw").path
        return try await ManagedProcess().run(request)
    })
}
