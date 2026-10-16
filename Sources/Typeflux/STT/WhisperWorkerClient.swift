import Darwin
import Foundation
import TypefluxInferenceProtocol

final class WhisperWorkerClient: @unchecked Sendable {
    static var executableURL: URL {
        executableURL(appExecutable: AskFileReader.executableURL)
    }

    static func executableURL(appExecutable: URL) -> URL {
        let directory = appExecutable.deletingLastPathComponent()
        if directory.lastPathComponent == "MacOS", directory.deletingLastPathComponent().lastPathComponent == "Contents" {
            return directory.deletingLastPathComponent().appendingPathComponent("Helpers/TypefluxInferenceHelper")
        }
        return directory.appendingPathComponent("TypefluxInferenceHelper")
    }

    private let socket: InferenceSocket
    private let process: Task<Void, Never>
    private let control: WhisperProcessControl
    private let retirement: WhisperWorkerRetirement
    private let scratch: URL
    private let lock = NSLock()
    private var busy = false
    private let timeout: TimeInterval
    private let copyAudio: @Sendable (URL, URL) throws -> Void

    init(configuration: InferenceConfiguration, pool: WhisperWorkerPool = .shared,
         executable: URL = WhisperWorkerClient.executableURL, timeout: TimeInterval = 1800,
         copyAudio: @escaping @Sendable (URL, URL) throws -> Void = { try WhisperWorkerClient.copyAudio($0, $1) },
         run: @escaping @Sendable (ManagedProcess.Request) async throws -> ManagedProcess.Result = {
             try await ManagedProcess().run($0)
         }) throws {
        try configuration.validate()
        guard timeout.isFinite, timeout > 0, timeout <= 86400 else { throw InferenceFailure.protocolViolation }
        self.timeout = timeout
        self.copyAudio = copyAudio
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw InferenceFailure.unavailable }
        guard pair.allSatisfy({ fcntl($0, F_SETFD, FD_CLOEXEC) == 0 }) else {
            pair.forEach { close($0) }
            throw InferenceFailure.unavailable
        }
        let inherited = WhisperInheritedDescriptor(pair[1])
        let socket = try InferenceSocket(owning: pair[0])
        self.socket = socket
        let control = WhisperProcessControl(socket: socket)
        self.control = control
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("typeflux-inference-" + UUID().uuidString)
        self.scratch = scratch
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let id: UUID
        do {
            id = try pool.reserve(paths: [configuration.modelFolder, configuration.downloadBase,
                                          configuration.tokenizerFolder].compactMap { $0 }, stop: { control.stop() })
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
        let retirement = WhisperWorkerRetirement(pool: pool, id: id, scratch: scratch)
        self.retirement = retirement
        process = Task.detached {
            let directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            defer { if directory >= 0 { close(directory) }; inherited.closeOnce() }
            var started = false
            let marker = WhisperLaunchMarker()
            do {
                guard retirement.permits, !Task.isCancelled else { throw InferenceFailure.cancelled }
                guard directory >= 0 else { throw InferenceFailure.unavailable }
                let result = try await run(ManagedProcess.Request(
                    executable: executable.path, arguments: ["--ipc-fd", "100"],
                    environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
                                  "HOME": FileManager.default.homeDirectoryForCurrentUser.path],
                    directoryDescriptor: directory, timeout: 86400, outputLimit: 1024,
                    onStarted: { marker.mark(); inherited.closeOnce() }, stderrLimit: 1024,
                    immediateCleanupOnExit: true, onReaped: { retirement.reaped() },
                    ipcDescriptor: inherited.descriptor))
                started = marker.started
                if !socket.isStopped, result.termination != .cancelled,
                   result.termination != .exited(0) || result.outputTruncated { retirement.markFailed() }
                retirement.completed()
            } catch {
                started = marker.started
                if !socket.isStopped {
                    let code = error as NSError
                    retirement.markFailed(configuration: code.domain == NSPOSIXErrorDomain
                        && [Int(EACCES), Int(EPERM), Int(ENOENT), Int(ENOEXEC)].contains(code.code))
                }
                retirement.completed()
            }
            if !started { retirement.reaped() }
        }
        control.install(process)
    }

    deinit { stop() }

    func stop() { control.stop() }
    var canReuse: Bool { !socket.isStopped && retirement.canReuse }

    func request(_ request: InferenceMessage,
                 onUpdate: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> InferenceMessage {
        try admit()
        defer { finishRequest() }
        try request.validate()
        return try await exchange(request, onUpdate: onUpdate)
    }

    private func admit() throws {
        try lock.withLock {
            guard !busy else { throw InferenceFailure.busy }
            guard !socket.isStopped, retirement.permits else { throw InferenceFailure.unavailable }
            try retirement.beginHostWork()
            busy = true
        }
    }

    private func finishRequest() {
        lock.withLock { busy = false }
        retirement.endHostWork()
    }

    private func exchange(_ request: InferenceMessage,
                          onUpdate: @escaping @Sendable (String) async -> Void) async throws -> InferenceMessage {
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                guard retirement.permits else { throw InferenceFailure.cancelled }
                let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
                try await blocking { try self.socket.send(request, deadline: deadline) }
                var sequence = request.kind == .transcribe ? 1 : 0
                while true {
                    let reply = try await blocking { try self.socket.receive(deadline: deadline) }
                    try Task.checkCancellation()
                    guard !socket.isStopped, retirement.permits else { throw InferenceFailure.cancelled }
                    guard reply.id == request.id, reply.sequence == sequence,
                          reply.configuration == nil, reply.audioPath == nil, reply.prompt == nil,
                          reply.language == nil, !reply.lowEnergy else { throw InferenceFailure.protocolViolation }
                    switch reply.kind {
                    case .progress where request.kind == .transcribe:
                        guard reply.modelPath == nil else { throw InferenceFailure.protocolViolation }
                        sequence += 1
                        await onUpdate(reply.text ?? "")
                    case .final where request.kind == .transcribe:
                        guard reply.modelPath == nil else { throw InferenceFailure.protocolViolation }
                        retirement.succeeded(); return reply
                    case .ready where request.kind == .prepare || request.kind == .probe:
                        guard reply.text == nil else { throw InferenceFailure.protocolViolation }
                        retirement.succeeded(); return reply
                    case .failed:
                        guard reply.text == nil, reply.modelPath == nil else { throw InferenceFailure.protocolViolation }
                        throw InferenceFailure.engineFailed
                    default: throw InferenceFailure.protocolViolation
                    }
                }
            } catch {
                if !Task.isCancelled, error as? InferenceFailure != .cancelled,
                   error as? InferenceFailure != .engineFailed { retirement.markFailed() }
                stop()
                throw (error as? InferenceFailure) ?? InferenceFailure.unavailable
            }
        } onCancel: { self.stop() }
    }

    func transcribe(audio: URL, lowEnergy: Bool, prompt: String?, language: String?,
                    deliverFinal: @escaping @Sendable (String) async throws -> Void = { _ in },
                    onUpdate: @escaping @Sendable (String) async -> Void) async throws -> String {
        try admit()
        defer { finishRequest() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let destination = scratch.appendingPathComponent(UUID().uuidString).appendingPathExtension(audio.pathExtension)
            // Keep a private recording copy so caller cleanup cannot remove a child's
            // input. Failed/cancelled requests retain it until actual process reaping.
            var message = InferenceMessage(kind: .transcribe)
            message.audioPath = destination.path
            message.lowEnergy = lowEnergy; message.prompt = prompt; message.language = language
            try message.validate()
            try await blocking { try self.copyAudio(audio, destination) }
            let reply = try await exchange(message, onUpdate: onUpdate)
            // Final consumer delivery belongs to this request too: a stopped child
            // must not release the model/input leases while its consumer still runs.
            guard retirement.permits else { throw InferenceFailure.cancelled }
            try await deliverFinal(reply.text ?? "")
            try Task.checkCancellation()
            guard !socket.isStopped, retirement.permits else { throw InferenceFailure.cancelled }
            try? FileManager.default.removeItem(at: destination)
            return reply.text ?? ""
        } onCancel: { self.stop() }
    }

    static func copyAudio(_ audio: URL, _ destination: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: audio.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= 512 * 1024 * 1024,
              attributes[.type] as? FileAttributeType == .typeRegular else { throw InferenceFailure.unavailable }
        try FileManager.default.copyItem(at: audio, to: destination)
    }

    private func blocking<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try operation() }) }
        }
    }
}

private final class WhisperInheritedDescriptor: @unchecked Sendable {
    let descriptor: Int32
    private let lock = NSLock()
    private var closed = false
    init(_ descriptor: Int32) { self.descriptor = descriptor }
    func closeOnce() { lock.withLock { if !closed { closed = true; close(descriptor) } } }
    deinit { closeOnce() }
}

private final class WhisperLaunchMarker: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var started: Bool { lock.withLock { value } }
    func mark() { lock.withLock { value = true } }
}

private final class WhisperWorkerRetirement: @unchecked Sendable {
    private let lock = NSLock()
    private let pool: WhisperWorkerPool
    private let id: UUID
    private let scratch: URL
    private var collected = false
    private var returned = false
    private var released = false
    private var failure = false
    private var hostActivities = 0
    init(pool: WhisperWorkerPool, id: UUID, scratch: URL) { self.pool = pool; self.id = id; self.scratch = scratch }
    func beginHostWork() throws {
        try lock.withLock {
            guard !collected, !returned, !released else { throw InferenceFailure.unavailable }
            hostActivities += 1
        }
    }
    func endHostWork() {
        lock.withLock { hostActivities -= 1 }
        finish()
    }
    var permits: Bool { pool.permits(id) }
    var canReuse: Bool { lock.withLock { !collected && !returned && !released } && permits }
    func succeeded() { pool.succeeded(id) }
    func markFailed(configuration: Bool = false) {
        let first = lock.withLock { let first = !failure; failure = true; return first }
        if first { pool.recordFailure(id, configuration: configuration) }
    }
    func reaped() { lock.withLock { collected = true }; finish() }
    func completed() { lock.withLock { returned = true }; finish() }
    private func finish() {
        let ready = lock.withLock {
            guard collected, returned, !released, hostActivities == 0 else { return false }
            released = true
            return true
        }
        guard ready else { return }
        // Never block the global process reaper on filesystem cleanup.
        DispatchQueue.global(qos: .utility).async { [self] in
            try? FileManager.default.removeItem(at: scratch)
            pool.release(id, failed: false)
        }
    }
}

private final class WhisperProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private let socket: InferenceSocket
    private var task: Task<Void, Never>?
    private var stopped = false
    init(socket: InferenceSocket) { self.socket = socket }
    func install(_ task: Task<Void, Never>) {
        lock.withLock { self.task = task; if stopped { task.cancel() } }
    }
    func stop() {
        lock.withLock { stopped = true; socket.stop(); task?.cancel() }
    }
}
