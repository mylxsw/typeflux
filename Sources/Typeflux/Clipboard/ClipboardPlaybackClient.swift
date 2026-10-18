import Darwin
import Foundation
import TypefluxMediaProtocol

protocol ClipboardPlaybackClient: Sendable {
    func request(_ kind: MediaPlaybackMessage.Kind, fraction: Double?) async throws -> MediaPlaybackState
    func stop()
    func retainPixels(_ reservation: AskToolPixelBudget.Lease) throws
    func request(_ kind: MediaPlaybackMessage.Kind, fraction: Double?, range: MediaPlaybackRange?) async throws -> MediaPlaybackState
    func request(_ kind: MediaPlaybackMessage.Kind, fraction: Double?, range: MediaPlaybackRange?,
                 mix: MediaPlaybackMix?) async throws -> MediaPlaybackState
}
extension ClipboardPlaybackClient {
    func request(_ kind: MediaPlaybackMessage.Kind, fraction: Double?, range: MediaPlaybackRange?) async throws -> MediaPlaybackState {
        guard range == nil else { throw MediaFailure.invalidProtocol }
        return try await request(kind, fraction: fraction)
    }
    func request(_ kind: MediaPlaybackMessage.Kind, fraction: Double?, range: MediaPlaybackRange?,
                 mix: MediaPlaybackMix?) async throws -> MediaPlaybackState {
        guard mix == nil else { throw MediaFailure.invalidProtocol }
        return try await request(kind, fraction: fraction, range: range)
    }
}

/// Independent playback admission. Cancelled children keep their slot and input until reaped.
final class ClipboardPlaybackPool: @unchecked Sendable {
    static let shared = ClipboardPlaybackPool(requiresLifecycle: true)
    private struct Entry {
        let lease: MediaLease
        let generation: UUID?
        var stop: (@Sendable () -> Void)?
        var pixels: AskToolPixelBudget.Lease?
    }
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var failedIDs = Set<UUID>()
    private var disabled = false
    private var budget = ModuleRecoveryBudget()
    private var lifecycle: ModuleWorkerGate?
    private var waiter: CheckedContinuation<Void, Never>?
    private let requiresLifecycle: Bool
    private let executable: URL
    private let uptime: @Sendable () -> TimeInterval
    init(executable: URL = MediaWorker.helperURL, requiresLifecycle: Bool = false,
         uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.executable = executable; self.requiresLifecycle = requiresLifecycle; self.uptime = uptime
    }
    func reserve() throws -> (UUID, MediaLease) {
        let result = try lock.withLock {
            guard !disabled, entries.count < 2 else { throw MediaFailure.unavailable }
            let generation: UUID?
            if let lifecycle {
                guard let value = try? lifecycle.admit() else { throw MediaFailure.unavailable }
                generation = value
            } else {
                guard !requiresLifecycle, budget.permitsAttempt(at: uptime()) else { throw MediaFailure.unavailable }
                generation = nil
            }
            let id = UUID(), lease = MediaLease()
            entries[id] = Entry(lease: lease, generation: generation)
            lease.cleanup = { [self] in
                let done = lock.withLock {
                    entries[id] = nil; failedIDs.remove(id)
                    guard entries.isEmpty else { return Optional<CheckedContinuation<Void, Never>>.none }
                    let done = waiter; waiter = nil; return done
                }
                lock.withLock { lifecycle }?.changed(); done?.resume()
            }
            return (id, lease)
        }
        lock.withLock { lifecycle }?.changed(); return result
    }
    func permits(_ id: UUID) -> Bool {
        lock.withLock {
            guard !disabled, let entry = entries[id], !entry.lease.cancelled else { return false }
            return lifecycle.map { $0.permits(entry.generation) } ?? !requiresLifecycle
        }
    }
    func attach(_ id: UUID, stop: @escaping @Sendable () -> Void) {
        lock.withLock { entries[id]?.stop = stop }
        if !permits(id) { stop() }
    }
    func retainPixels(_ id: UUID, reservation: AskToolPixelBudget.Lease) throws {
        guard permits(id) else { throw MediaFailure.unavailable }
        try lock.withLock {
            guard let entry = entries[id], !entry.lease.cancelled, entry.pixels == nil else { throw MediaFailure.unavailable }
            entries[id]?.pixels = reservation
        }
    }
    func failed(_ id: UUID, configuration: Bool = false) {
        lock.withLock {
            guard !disabled, let entry = entries[id], !entry.lease.cancelled, failedIDs.insert(id).inserted else { return }
            if let lifecycle { lifecycle.failed(entry.generation, configuration: configuration) }
            else { budget.failed(at: uptime()) }
        }
    }
    func succeeded(_ id: UUID) {
        lock.withLock {
            guard !disabled, let entry = entries[id], !entry.lease.cancelled else { return }
            if let lifecycle { lifecycle.succeeded(entry.generation) }
            else { budget.succeeded(at: uptime()) }
        }
    }
    func bind(_ gate: ModuleWorkerGate) -> Bool {
        lock.withLock {
            guard lifecycle == nil, entries.isEmpty, !disabled else { return false }
            lifecycle = gate; return true
        }
    }
    func checkReadiness() async throws {
        let path = executable.path
        let available = await Task.detached(priority: .utility) { FileManager.default.isExecutableFile(atPath: path) }.value
        guard available, lock.withLock({ !disabled && entries.isEmpty }) else { throw ModuleFailure.unavailable }
    }
    func stopOwned() {
        let values = lock.withLock { Array(entries.values) }
        values.forEach { $0.lease.cancel(); $0.stop?() }
    }
    func retireManaged() async {
        stopOwned()
        await withCheckedContinuation { continuation in
            let done = lock.withLock {
                guard !entries.isEmpty else { return true }
                waiter = continuation; return false
            }
            if done { continuation.resume() }
        }
    }
    func preventNewWork() {
        lock.withLock { disabled = true; lifecycle?.admission.shutdown() }
        stopOwned()
    }
    func shutdown() async {
        preventNewWork()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while activeCount > 0, ContinuousClock.now < deadline, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
    }
    var activeCount: Int { lock.withLock { entries.count } }
}

/// A failed acknowledgement can follow partial native effects; it never permits replay.
enum ClipboardPlaybackFailure: Error { case unconfirmed }

struct ClipboardPlaybackSource: Equatable, Sendable {
    let url: URL
    let limit: Int
    let device: dev_t, inode: ino_t, bytes: off_t
    let modified: Int, modifiedNanos: Int, changed: Int, changedNanos: Int
    init(_ url: URL, limit: Int = 512 * 1024 * 1024) throws {
        var info = stat(), mount = statfs()
        guard url.isFileURL, url.path.utf8.count <= 4096, !url.path.contains("\0"),
              lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= limit, limit > 0, limit <= 8 * 1024 * 1024 * 1024,
              info.st_flags & UInt32(SF_DATALESS) == 0, statfs(url.path, &mount) == 0,
              mount.f_flags & UInt32(MNT_LOCAL) != 0 else { throw MediaFailure.unreadable }
        self.url = url; self.limit = limit; device = info.st_dev; inode = info.st_ino; bytes = info.st_size
        modified = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
        changed = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
    }
    func check() throws { guard self == (try Self(url, limit: limit)) else { throw MediaFailure.unreadable } }
}

final class ClipboardPlaybackProcess: ClipboardPlaybackClient, @unchecked Sendable {
    typealias Runner = MediaWorker.Runner
    private let socket: MediaPlaybackSocket
    private let lease: MediaLease
    private let retirement: ClipboardPlaybackRetirement
    private let source: ClipboardPlaybackSource
    private let pool: ClipboardPlaybackPool
    private let id = UUID()
    private let poolID: UUID
    private let lock = NSLock()
    private var sequence = 0, busy = false
    private let timeout: Double
    private let video: Bool
    private init(socket: MediaPlaybackSocket, lease: MediaLease, source: ClipboardPlaybackSource,
                 pool: ClipboardPlaybackPool, poolID: UUID, timeout: Double, video: Bool) {
        self.socket = socket; self.lease = lease; self.retirement = ClipboardPlaybackRetirement(lease, opening: true); self.source = source; self.pool = pool; self.poolID = poolID; self.timeout = timeout; self.video = video
    }
    /// Admission precedes any detached copy, spawn or socket operation.
    static func open(_ url: URL, video: Bool = false, recording: Bool = false, pool: ClipboardPlaybackPool = .shared,
                     executable: URL = MediaWorker.helperURL, timeout: Double = 5,
                     run: @escaping Runner = { try ManagedProcess().runBlocking($0, isCancelled: $1) }) async throws -> ClipboardPlaybackProcess {
        guard !recording || video, timeout.isFinite, timeout > 0, timeout <= 10,
              let container = MediaAVContainer(rawValue: url.pathExtension.lowercased()) else { throw MediaFailure.unreadable }
        try Task.checkCancellation()
        let (key, lease) = try pool.reserve()
        return try await withTaskCancellationHandler {
            let client = try await Task.detached(priority: .utility) {
                do {
                    if !pool.permits(key) { throw CancellationError() }
                    let limit = recording ? 8 * 1024 * 1024 * 1024 : 512 * 1024 * 1024
                    let source = try ClipboardPlaybackSource(url, limit: limit)
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("typeflux-playback-" + key.uuidString)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    lease.directory = directory
                    try MediaWorker.copy(.file(url), to: directory.appendingPathComponent("audio." + container.rawValue),
                                         limit: limit, cancelled: { lease.cancelled })
                    try source.check()
                    if !pool.permits(key) { throw CancellationError() }
                    var pair: [Int32] = [-1, -1]
                    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw MediaFailure.unavailable }
                    let inherited = PlaybackDescriptor(pair[1])
                    let socket = try MediaPlaybackSocket(owning: pair[0])
                    guard fcntl(inherited.value, F_SETFD, FD_CLOEXEC) == 0 else { throw MediaFailure.unavailable }
                    let client = ClipboardPlaybackProcess(socket: socket, lease: lease, source: source, pool: pool, poolID: key, timeout: timeout, video: video)
                    pool.attach(key) { socket.stop(); lease.cancel() }
                    // A host filesystem check can ignore cancellation even after the child exits.
                    // Keep admission until both process collection and every host exchange return.
                    let retirement = client.retirement
                    Task.detached(priority: .utility) {
                        defer { inherited.closeOnce(); retirement.processReturned() }
                        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                        guard fd >= 0 else { pool.failed(key, configuration: true); socket.stop(); return }
                        defer { close(fd) }
                        do {
                            guard pool.permits(key) else { socket.stop(); return }
                            let result = try run(.init(executable: executable.path,
                                arguments: [recording ? "--recording-playback" : video ? "--video-playback" : "--audio-playback", "100", container.rawValue],
                                environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"],
                                directoryDescriptor: fd, timeout: MediaPlaybackMessage.lifetime,
                                outputLimit: 1024, stopOnOutputLimit: true,
                                onStarted: { lease.started(); inherited.closeOnce() }, stderrLimit: 1024,
                                immediateCleanupOnExit: true, onReaped: { lease.reaped() }, ipcDescriptor: inherited.value), { lease.cancelled })
                            if result.termination != .cancelled,
                               result.termination != .exited(0) || result.outputTruncated { pool.failed(key); socket.stop() }
                        } catch {
                            let code = error as NSError
                            pool.failed(key, configuration: code.domain == NSPOSIXErrorDomain
                                && [Int(EACCES), Int(EPERM), Int(ENOENT), Int(ENOEXEC)].contains(code.code))
                            socket.stop()
                        }
                        // A clean EOF may still have a final failed acknowledgement buffered.
                        // Let the request consume it rather than discarding it on process exit.
                    }
                    return client
                } catch { lease.returned(); throw error }
            }.value
            defer { client.retirement.endRequest() }
            if Task.isCancelled || !pool.permits(key) { client.stop(); throw CancellationError() }
            return client
        } onCancel: { lease.cancel() }
    }
    deinit { stop() }
    func stop() { socket.stop(); lease.cancel() }
    func retainPixels(_ reservation: AskToolPixelBudget.Lease) throws { try pool.retainPixels(poolID, reservation: reservation) }
    func request(_ kind: MediaPlaybackMessage.Kind, fraction: Double? = nil) async throws -> MediaPlaybackState {
        try await request(kind, fraction: fraction, range: nil)
    }
    func request(_ kind: MediaPlaybackMessage.Kind, fraction: Double?, range: MediaPlaybackRange?) async throws -> MediaPlaybackState {
        try await request(kind, fraction: fraction, range: range, mix: nil)
    }
    func request(_ kind: MediaPlaybackMessage.Kind, fraction: Double?, range: MediaPlaybackRange?,
                 mix: MediaPlaybackMix?) async throws -> MediaPlaybackState {
        let message = try lock.withLock {
            guard !busy, !lease.cancelled, !socket.isStopped, pool.permits(poolID) else { throw MediaFailure.unavailable }
            guard kind != .reply, kind != .failed else { throw MediaFailure.invalidProtocol }
            let request = MediaPlaybackMessage(id: id, sequence: sequence + 1,
                kind: video && kind == .load ? .loadVideo : kind, fraction: fraction, range: range, mix: mix)
            try request.validate()
            try retirement.beginRequest()
            busy = true; sequence += 1; return request
        }
        defer { lock.withLock { busy = false }; retirement.endRequest() }
        return try await withTaskCancellationHandler {
            do {
                let result = try await Task.detached(priority: .utility) { [self] in
                    try source.check()
                    guard pool.permits(poolID) else { throw CancellationError() }
                    let deadline = ContinuousClock.now.advanced(by: .seconds(kind == .load ? 10 : timeout))
                    let state: MediaPlaybackState
                    do {
                        try socket.send(message, deadline: deadline)
                        let response = try socket.receive(deadline: deadline)
                        guard response.id == id, response.sequence == message.sequence else { throw MediaFailure.invalidProtocol }
                        if response.kind == .failed { throw ClipboardPlaybackFailure.unconfirmed }
                        guard response.kind == .reply, var value = response.state, value.video == video else { throw MediaFailure.invalidProtocol }
                        if let frame = value.frame { value.pixels = try socket.receivePixels(count: frame.bytes, deadline: deadline) }
                        state = value
                    } catch {
                        if !(error is ClipboardPlaybackFailure) { pool.failed(poolID) }
                        throw error
                    }
                    try source.check()
                    return state
                }.value
                try Task.checkCancellation()
                guard pool.permits(poolID) else { throw CancellationError() }
                pool.succeeded(poolID)
                return result
            } catch { stop(); throw error }
        } onCancel: { self.stop() }
    }
}

private final class PlaybackDescriptor: @unchecked Sendable {
    let value: Int32
    private let lock = NSLock()
    private var closed = false
    init(_ value: Int32) { self.value = value }
    func closeOnce() { lock.withLock { if !closed { closed = true; close(value) } } }
    deinit { closeOnce() }
}

/// Reaping alone cannot release a slot occupied by an uncooperative host file check.
final class ClipboardPlaybackRetirement: @unchecked Sendable {
    private let lock = NSLock()
    private let lease: MediaLease
    private var requests = 0
    private var returned = false
    private var released = false
    init(_ lease: MediaLease, opening: Bool = false) { self.lease = lease; requests = opening ? 1 : 0 }
    func beginRequest() throws {
        try lock.withLock {
            guard !returned else { throw MediaFailure.unavailable }
            requests += 1
        }
    }
    func endRequest() { lock.withLock { requests -= 1 }; finish() }
    func processReturned() { lock.withLock { returned = true }; finish() }
    private func finish() {
        let ready = lock.withLock {
            guard returned, requests == 0, !released else { return false }
            released = true; return true
        }
        if ready { lease.returned() }
    }
}
