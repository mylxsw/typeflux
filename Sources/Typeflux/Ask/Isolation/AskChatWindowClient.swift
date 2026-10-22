import Darwin
import Foundation
import TypefluxChatWindowProtocol

/// One private connection to one presentation child. The inherited descriptor
/// is the capability: no discoverable endpoint or bearer credential is exposed.
/// All blocking IPC runs off the actor. There is one outstanding request, no
/// automatic reconnect and no replay after a timeout or uncertain response.
actor AskChatWindowClient {
    nonisolated let generation: UUID
    private nonisolated let socket: ChatWindowSocket
    private nonisolated let control: ChatWindowProcessControl
    private nonisolated let process: Task<Void, Never>
    private var connected = false
    private var busy = false

    nonisolated static func executableURL(appExecutable: URL) -> URL {
        let directory = appExecutable.deletingLastPathComponent()
        if directory.lastPathComponent == "MacOS", directory.deletingLastPathComponent().lastPathComponent == "Contents" {
            return directory.deletingLastPathComponent().appendingPathComponent("Helpers/TypefluxChatWindowHelper.app/Contents/MacOS/TypefluxChatWindowHelper")
        }
        return directory.appendingPathComponent("TypefluxChatWindowHelper")
    }

    init(executable: URL = AskChatWindowClient.executableURL(appExecutable: AskFileReader.executableURL),
         generation: UUID = UUID(), probeStall: TimeInterval? = nil,
         run: @escaping @Sendable (ManagedProcess.Request) async throws -> ManagedProcess.Result = { try await ManagedProcess().run($0) }) throws {
        if let probeStall {
            guard probeStall.isFinite, (0 ... 30).contains(probeStall) else { throw ChatWindowFailure.invalidProtocol }
        }
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw ChatWindowFailure.unavailable }
        guard pair.allSatisfy({ fcntl($0, F_SETFD, FD_CLOEXEC) == 0 }) else {
            pair.forEach { close($0) }; throw ChatWindowFailure.unavailable
        }
        let inherited = ChatWindowInheritedDescriptor(pair[1])
        let socket = try ChatWindowSocket(owning: pair[0])
        self.socket = socket; self.generation = generation
        let control = ChatWindowProcessControl(socket: socket)
        self.control = control
        process = Task.detached {
            let directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            defer { if directory >= 0 { close(directory) }; inherited.closeOnce(); socket.stop() }
            guard directory >= 0 else { return }
            var arguments = ["--ipc-fd", "100"]
            if let probeStall { arguments += ["--probe", String(probeStall)] }
            _ = try? await run(.init(executable: executable.path, arguments: arguments,
                environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"], directoryDescriptor: directory,
                timeout: 86400, outputLimit: 1024, stopOnOutputLimit: true,
                onStarted: { inherited.closeOnce() }, stderrLimit: 1024,
                immediateCleanupOnExit: true, ipcDescriptor: inherited.descriptor))
        }
        control.install(process)
    }

    deinit { control.stop() }
    nonisolated func stop() { control.stop() }
    nonisolated func stopAndWait() async { control.stop(); await process.value }

    func connect(timeout: TimeInterval = 5) async throws {
        guard !connected else { throw ChatWindowFailure.invalidProtocol }
        _ = try await exchange(.init(generation: generation, kind: .hello), expected: .ready, timeout: timeout)
        connected = true
    }
    func present(_ snapshot: ChatWindowSnapshot, timeout: TimeInterval = 5) async throws {
        try await request(.present, snapshot: snapshot, expected: .acknowledged, timeout: timeout)
    }
    func ping(timeout: TimeInterval = 2) async throws {
        try await request(.ping, expected: .pong, timeout: timeout)
    }
    func hide(timeout: TimeInterval = 2) async throws {
        try await request(.hide, expected: .acknowledged, timeout: timeout)
    }
    func shutdown() async {
        try? await request(.shutdown, expected: .acknowledged, timeout: 2)
        await stopAndWait()
    }

    private func request(_ kind: ChatWindowEnvelope.Kind, snapshot: ChatWindowSnapshot? = nil,
                         expected: ChatWindowEnvelope.Kind, timeout: TimeInterval) async throws {
        guard connected else { throw ChatWindowFailure.unavailable }
        _ = try await exchange(.init(generation: generation, kind: kind, snapshot: snapshot), expected: expected, timeout: timeout)
    }
    private func exchange(_ request: ChatWindowEnvelope, expected: ChatWindowEnvelope.Kind,
                          timeout: TimeInterval) async throws -> ChatWindowEnvelope {
        try Task.checkCancellation()
        try request.validate()
        guard timeout.isFinite, timeout > 0, timeout <= 60 else { throw ChatWindowFailure.invalidProtocol }
        guard !busy else { throw ChatWindowFailure.busy }
        guard !socket.isStopped else { throw ChatWindowFailure.unavailable }
        busy = true
        defer { busy = false }
        let socket = socket, control = control
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        let exchange = Task.detached {
            try socket.send(request, deadline: deadline)
            let reply = try socket.receive(deadline: deadline)
            guard reply.generation == request.generation, reply.id == request.id, reply.kind == expected,
                  reply.sequence == request.snapshot?.sequence else { throw ChatWindowFailure.invalidProtocol }
            return reply
        }
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let reply = try await exchange.value
                try Task.checkCancellation()
                return reply
            } onCancel: { control.stop() }
        } catch {
            control.stop()
            // Await the bounded I/O task; cancellation must not leave a hidden reader.
            _ = try? await exchange.value
            throw error
        }
    }
}

private final class ChatWindowInheritedDescriptor: @unchecked Sendable {
    let descriptor: Int32
    private let lock = NSLock()
    private var closed = false
    init(_ descriptor: Int32) { self.descriptor = descriptor }
    func closeOnce() { lock.withLock { if !closed { closed = true; close(descriptor) } } }
    deinit { closeOnce() }
}

private final class ChatWindowProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private let socket: ChatWindowSocket
    private var process: Task<Void, Never>?
    private var stopped = false
    init(socket: ChatWindowSocket) { self.socket = socket }
    func install(_ task: Task<Void, Never>) {
        lock.withLock { process = task; if stopped { task.cancel() } }
    }
    func stop() { lock.withLock { stopped = true; socket.stop(); process?.cancel() } }
}
