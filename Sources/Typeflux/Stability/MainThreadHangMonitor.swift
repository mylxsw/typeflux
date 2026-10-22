import Darwin
import Foundation
import os

/// One outstanding probe prevents a stalled main queue from accumulating work.
/// Large sampling gaps invalidate the probe (sleep, debugger, or a suspended process).
struct MainThreadHeartbeat {
    enum Event: Equatable, Sendable { case probe(UInt64), stalled(TimeInterval), recovered(TimeInterval) }
    var threshold: TimeInterval = 2
    var maximumSamplingGap: TimeInterval = 5
    private var sequence: UInt64 = 0
    private var pending: (id: UInt64, sent: TimeInterval)?
    private var lastTick: TimeInterval?
    private var reported = false

    mutating func tick(at now: TimeInterval) -> Event? {
        defer { lastTick = now }
        if let lastTick, now < lastTick || now - lastTick > maximumSamplingGap {
            pending = nil; reported = false
        }
        if let pending {
            guard !reported, now - pending.sent >= threshold else { return nil }
            reported = true
            return .stalled(now - pending.sent)
        }
        sequence &+= 1
        pending = (sequence, now)
        return .probe(sequence)
    }

    mutating func acknowledge(_ id: UInt64, at now: TimeInterval) -> Event? {
        guard let pending, pending.id == id else { return nil }
        self.pending = nil
        defer { reported = false }
        return reported ? .recovered(max(0, now - pending.sent)) : nil
    }
}

/// Owns a small independent queue. Reporting never waits for AppKit or ErrorLogStore.
final class MainThreadHangMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "typeflux.main-thread-health", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var heartbeat = MainThreadHeartbeat()
    private var generation = UUID()
    private let report: @Sendable (MainThreadHeartbeat.Event) -> Void
    private let scheduleProbe: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let now: @Sendable () -> TimeInterval

    init(report: @escaping @Sendable (MainThreadHeartbeat.Event) -> Void = { MainThreadHangDiagnostics.shared.record($0) },
         scheduleProbe: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.report = report; self.scheduleProbe = scheduleProbe; self.now = now
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            generation = UUID(); heartbeat = MainThreadHeartbeat()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            generation = UUID(); timer?.cancel(); timer = nil
        }
    }

    deinit { timer?.cancel() }

    private func tick() {
        guard let event = heartbeat.tick(at: now()) else { return }
        if case let .probe(id) = event {
            let current = generation
            scheduleProbe { [weak self] in
                guard let self else { return }
                let acknowledgedAt = now()
                queue.async { [self] in
                    guard self.generation == current,
                          let event = self.heartbeat.acknowledge(id, at: acknowledgedAt) else { return }
                    self.report(event)
                }
            }
        } else { report(event) }
    }
}

/// Samples contain stack frames, not clipboard or conversation payloads. They stay
/// local, are rate limited, and have bounded retention. Never auto-restart the app.
final class MainThreadHangDiagnostics: @unchecked Sendable {
    static let shared = MainThreadHangDiagnostics()
    private let queue = DispatchQueue(label: "typeflux.hang-diagnostics", qos: .utility)
    private let logger = Logger(subsystem: "ai.gulu.app.typeflux", category: "Responsiveness")
    private let lock = NSLock()
    private var sampling = false
    private var lastSample: TimeInterval = -.infinity
    private let directory: URL?
    private let now: @Sendable () -> TimeInterval
    private let capture: @Sendable (ManagedProcess.Request) throws -> ManagedProcess.Result
    private let sampleFinished: @Sendable () -> Void

    init(directory: URL? = nil,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         capture: @escaping @Sendable (ManagedProcess.Request) throws -> ManagedProcess.Result = {
             try ManagedProcess().runBlocking($0, isCancelled: { false })
         }, sampleFinished: @escaping @Sendable () -> Void = {}) {
        self.directory = directory; self.now = now
        self.capture = capture; self.sampleFinished = sampleFinished
    }

    func record(_ event: MainThreadHeartbeat.Event) {
        switch event {
        case let .stalled(seconds):
            logger.error("Main thread unresponsive for \(seconds, privacy: .public) seconds")
            let now = now()
            let admitted = lock.withLock {
                guard !sampling, now - lastSample >= 60 else { return false }
                sampling = true; lastSample = now; return true
            }
            guard admitted else { return }
            queue.async { [self] in
                defer { lock.withLock { sampling = false }; sampleFinished() }
                sample()
            }
        case let .recovered(seconds):
            logger.notice("Main thread recovered after \(seconds, privacy: .public) seconds")
        case .probe: break
        }
    }

    private func sample() {
        let directory = directory ?? TypefluxDataDirectories.cache.appendingPathComponent("hang-diagnostics", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("main-") && $0.pathExtension == "txt" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for file in files.prefix(max(0, files.count - 4)) { try? FileManager.default.removeItem(at: file) }
            let target = directory.appendingPathComponent("main-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).txt")
            // The process wrapper enforces termination and output bounds even if sample stalls.
            let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            let result = try capture(.init(executable: "/usr/bin/sample",
                arguments: [String(ProcessInfo.processInfo.processIdentifier), "1", "10", "-file", "/dev/stdout"],
                environment: ["PATH": "/usr/bin:/bin"], directoryDescriptor: descriptor,
                timeout: 5, outputLimit: 2 * 1024 * 1024, stopOnOutputLimit: true, stderrLimit: 1024))
            guard !result.stdout.isEmpty else { return }
            try Data(result.stdout.utf8).write(to: target, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        } catch { logger.error("Could not save main-thread diagnostic") }
    }
}
