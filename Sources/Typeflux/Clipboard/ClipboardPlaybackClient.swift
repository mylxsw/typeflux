import Darwin
import Foundation
import TypefluxMediaProtocol

protocol ClipboardPlaybackClient: Sendable {
    func request(_ kind: MediaPlaybackMessage.Kind, fraction: Double?) async throws -> MediaPlaybackState
    func stop()
    func retainPixels(_ reservation: AskToolPixelBudget.Lease) throws
}

/// Independent playback admission. Cancelled children keep their slot and input until reaped.
final class ClipboardPlaybackPool: @unchecked Sendable {
    static let shared = ClipboardPlaybackPool()
    private let lock = NSLock()
    private var entries: [UUID: (MediaLease, (@Sendable () -> Void)?, AskToolPixelBudget.Lease?)] = [:]
    private var failedIDs = Set<UUID>()
    private var disabled = false
    private var budget = ModuleRecoveryBudget()
    func reserve() throws -> (UUID, MediaLease) {
        try lock.withLock {
            guard !disabled, entries.count < 2, budget.permitsAttempt(at: ProcessInfo.processInfo.systemUptime) else { throw MediaFailure.unavailable }
            let id = UUID(), lease = MediaLease()
            entries[id] = (lease, nil, nil)
            lease.cleanup = { [self] in lock.withLock { entries[id] = nil; failedIDs.remove(id) } }
            return (id, lease)
        }
    }
    func attach(_ id: UUID, stop: @escaping @Sendable () -> Void) {
        let cancelled = lock.withLock {
            guard let entry = entries[id] else { return true }
            entries[id] = (entry.0, stop, entry.2)
            return disabled || entry.0.cancelled
        }
        if cancelled { stop() }
    }
    func retainPixels(_ id: UUID, reservation: AskToolPixelBudget.Lease) throws {
        try lock.withLock {
            guard let entry = entries[id], !entry.0.cancelled, entry.2 == nil else { throw MediaFailure.unavailable }
            entries[id] = (entry.0, entry.1, reservation)
        }
    }
    func failed(_ id: UUID) {
        lock.withLock {
            guard entries[id] != nil, failedIDs.insert(id).inserted else { return }
            budget.failed(at: ProcessInfo.processInfo.systemUptime)
        }
    }
    func preventNewWork() {
        let values = lock.withLock { disabled = true; return Array(entries.values) }
        values.forEach { $0.0.cancel(); $0.1?() }
    }
    func shutdown() async {
        preventNewWork()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while activeCount > 0, ContinuousClock.now < deadline, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
    }
    var activeCount: Int { lock.withLock { entries.count } }
}

struct ClipboardPlaybackSource: Equatable, Sendable {
    let url: URL
    let device: dev_t, inode: ino_t, bytes: off_t
    let modified: Int, modifiedNanos: Int, changed: Int, changedNanos: Int
    init(_ url: URL) throws {
        var info = stat(), mount = statfs()
        guard url.isFileURL, url.path.utf8.count <= 4096, !url.path.contains("\0"),
              lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= 512 * 1024 * 1024,
              info.st_flags & UInt32(SF_DATALESS) == 0, statfs(url.path, &mount) == 0,
              mount.f_flags & UInt32(MNT_LOCAL) != 0 else { throw MediaFailure.unreadable }
        self.url = url; device = info.st_dev; inode = info.st_ino; bytes = info.st_size
        modified = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
        changed = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
    }
    func check() throws { guard self == (try Self(url)) else { throw MediaFailure.unreadable } }
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
        self.socket = socket; self.lease = lease; self.retirement = ClipboardPlaybackRetirement(lease); self.source = source; self.pool = pool; self.poolID = poolID; self.timeout = timeout; self.video = video
    }
    /// Admission precedes any detached copy, spawn or socket operation.
    static func open(_ url: URL, video: Bool = false, pool: ClipboardPlaybackPool = .shared,
                     executable: URL = MediaWorker.helperURL, timeout: Double = 5,
                     run: @escaping Runner = { try ManagedProcess().runBlocking($0, isCancelled: $1) }) async throws -> ClipboardPlaybackProcess {
        guard timeout.isFinite, timeout > 0, timeout <= 10,
              let container = MediaAVContainer(rawValue: url.pathExtension.lowercased()) else { throw MediaFailure.unreadable }
        try Task.checkCancellation()
        let (key, lease) = try pool.reserve()
        return try await withTaskCancellationHandler {
            let client = try await Task.detached(priority: .utility) {
                do {
                    if lease.cancelled { throw CancellationError() }
                    let source = try ClipboardPlaybackSource(url)
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("typeflux-playback-" + key.uuidString)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    lease.directory = directory
                    try MediaWorker.copy(.file(url), to: directory.appendingPathComponent("audio." + container.rawValue),
                                         limit: 512 * 1024 * 1024, cancelled: { lease.cancelled })
                    try source.check()
                    if lease.cancelled { throw CancellationError() }
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
                        guard fd >= 0 else { pool.failed(key); socket.stop(); return }
                        defer { close(fd) }
                        do {
                            _ = try run(.init(executable: executable.path,
                                arguments: [video ? "--video-playback" : "--audio-playback", "100", container.rawValue],
                                environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"],
                                directoryDescriptor: fd, timeout: MediaPlaybackMessage.lifetime,
                                outputLimit: 1024, stopOnOutputLimit: true,
                                onStarted: { lease.started(); inherited.closeOnce() }, stderrLimit: 1024,
                                immediateCleanupOnExit: true, onReaped: { lease.reaped() }, ipcDescriptor: inherited.value), { lease.cancelled })
                        } catch { /* A failed request reports one sanitized failure, without restarting. */ }
                        if !lease.cancelled { pool.failed(key) }
                        socket.stop()
                    }
                    return client
                } catch { lease.returned(); throw error }
            }.value
            if Task.isCancelled { client.stop(); throw CancellationError() }
            return client
        } onCancel: { lease.cancel() }
    }
    deinit { stop() }
    func stop() { socket.stop(); lease.cancel() }
    func retainPixels(_ reservation: AskToolPixelBudget.Lease) throws { try pool.retainPixels(poolID, reservation: reservation) }
    func request(_ kind: MediaPlaybackMessage.Kind, fraction: Double? = nil) async throws -> MediaPlaybackState {
        let number = try lock.withLock {
            guard !busy, !lease.cancelled, !socket.isStopped else { throw MediaFailure.unavailable }
            try retirement.beginRequest()
            busy = true; sequence += 1; return sequence
        }
        defer { lock.withLock { busy = false }; retirement.endRequest() }
        return try await withTaskCancellationHandler {
            do {
                let result = try await Task.detached(priority: .utility) { [self] in
                    try source.check()
                    let request = MediaPlaybackMessage(id: id, sequence: number, kind: video && kind == .load ? .loadVideo : kind, fraction: fraction)
                    let deadline = ContinuousClock.now.advanced(by: .seconds(kind == .load ? 10 : timeout))
                    try socket.send(request, deadline: deadline)
                    let response = try socket.receive(deadline: deadline)
                    guard response.id == id, response.sequence == number, response.kind == .reply, var state = response.state, state.video == video else { throw MediaFailure.invalidProtocol }
                    if let frame = state.frame { state.pixels = try socket.receivePixels(count: frame.bytes, deadline: deadline) }
                    try source.check()
                    return state
                }.value
                try Task.checkCancellation()
                guard !lease.cancelled else { throw CancellationError() }
                return result
            } catch {
                if !lease.cancelled, !Task.isCancelled, (error as? MediaFailure) != .unreadable { pool.failed(poolID) }
                stop(); throw error
            }
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
    init(_ lease: MediaLease) { self.lease = lease }
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
