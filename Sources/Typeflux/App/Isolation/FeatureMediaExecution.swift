import Darwin
import Foundation
import TypefluxMediaProtocol

struct FeatureMediaJob: Codable, Sendable {
    let id: UUID
    var owner: FeatureRole = .host
    let directory: String
    let input: Data
    let timeout: TimeInterval
    let outputLimit: Int
}

struct FeatureMediaAdmission: Codable, Sendable { let accepted: Bool }
enum MediaWorkAdmissionBusy: Error { case busy }

struct FeatureMediaReply: Codable, Sendable {
    var result: ManagedProcess.Result?
    var finished: Bool
    var busy = false
}

/// File-backed media stays in its private operation directory. Only bounded
/// control messages and decoder metadata cross the feature channels.
enum FeatureMediaExecution {
    static func run(_ request: ManagedProcess.Request,
                    cancelled: @escaping @Sendable () -> Bool) throws -> ManagedProcess.Result {
        guard FeatureProcess.enabled, FeatureProcess.role != .background,
              request.executable == MediaWorker.helperURL.path, request.arguments.isEmpty,
              request.onOutput == nil, request.onRawOutput == nil,
              let input = request.stdin,
              let envelope = try? JSONDecoder().decode(MediaRequest.self, from: input) else {
            return try ManagedProcess().runBlocking(request, isCancelled: cancelled)
        }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(request.directoryDescriptor, F_GETPATH, &path) == 0 else { throw MediaFailure.unavailable }
        let job = FeatureMediaJob(
            id: envelope.id,
            owner: FeatureProcess.role,
            directory: String(cString: path),
            input: input,
            timeout: request.timeout,
            outputLimit: request.outputLimit
        )
        let data = try JSONEncoder().encode(job)
        guard let admission: FeatureMediaAdmission = FeatureBackgroundCall.blocking(.init(
            destination: .background,
            action: "media.submit",
            payload: data
        )) else { throw MediaFailure.unavailable }
        guard admission.accepted else { throw MediaWorkAdmissionBusy.busy }
        request.onStarted?()
        // Capacity remains reserved until the backend confirms actual child reaping.
        // A broken channel deliberately leaves the local lease unreclaimed.
        let id = try JSONEncoder().encode(job.id)
        guard let reply: FeatureMediaReply = FeatureBackgroundCall.blocking(
            .init(destination: .background, action: "media.wait", payload: id), cancelled: cancelled,
            timeout: min(115, job.timeout + 10), cancellationCommand: .init(
                destination: .background,
                action: "media.cancel",
                payload: id
            )
        ),
            reply.finished else { throw MediaFailure.unavailable }
        request.onReaped?()
        let _: FeatureRPC.Empty? = FeatureBackgroundCall.blocking(.init(
            destination: .background,
            action: "media.ack",
            payload: id
        ))
        if reply.busy { throw MediaWorkAdmissionBusy.busy }
        guard let result = reply.result else { throw MediaFailure.unavailable }
        if result.termination == .cancelled { throw CancellationError() }
        return result
    }
}

/// Global media admission replaces the independent per-window decoder limits.
/// Accepted explicit jobs queue; disposable callers cancel obsolete jobs.
@MainActor
final class FeatureMediaJobs {
    typealias Execution = @MainActor (FeatureMediaJob, @escaping @Sendable () -> Void) async throws -> ManagedProcess.Result
    private let execution: Execution?
    init(execution: Execution? = nil) { self.execution = execution }

    private struct Job {
        let request: FeatureMediaJob
        let deadline: ContinuousClock.Instant
        var deadlineTask: Task<Void, Never>?
        var busy = false
        var task: Task<Void, Never>?
        var result: ManagedProcess.Result?
        var returned = false
        var reaped = false
        var cancelled = false
        var orphaned = false
    }

    private var jobs: [UUID: Job] = [:]
    private var waiters: [UUID: CheckedContinuation<FeatureMediaReply, Never>] = [:]
    private var queue: [UUID] = []
    private var stopped = false
    var onBusy: ((Bool) -> Void)?
    private let maximumActive = 2
    private let maximumQueued = 24

    func handle(_ command: FeatureCommand) throws -> Data {
        func encode(_ value: some Encodable) throws -> Data {
            try JSONEncoder().encode(value)
        }
        if command.action == "media.submit" {
            let request = try JSONDecoder().decode(FeatureMediaJob.self, from: command.payload)
            try Self.validate(request)
            guard !stopped, jobs[request.id] == nil else { throw FeatureRPC.Failure.busy }
            guard jobs.count < maximumQueued else { return try encode(FeatureMediaAdmission(accepted: false)) }
            jobs[request.id] = Job(request: request, deadline: .now.advanced(by: .seconds(request.timeout)))
            jobs[request.id]?.deadlineTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(request.timeout)) } catch { return }
                self?.expireQueued(request.id)
            }
            queue.append(request.id); advance()
            return try encode(FeatureMediaAdmission(accepted: true))
        }
        if command.action == "media.ownerExited" {
            let owner = try JSONDecoder().decode(FeatureRole.self, from: command.payload)
            for id in jobs.keys.filter({ jobs[$0]?.request.owner == owner }) {
                jobs[id]?.orphaned = true; jobs[id]?.task?.cancel()
                if jobs[id]?.task == nil {
                    jobs[id]?.returned = true; jobs[id]?.reaped = true
                }
                collectOrphan(id)
            }
            queue.removeAll { jobs[$0] == nil }
            return try encode(FeatureRPC.Empty())
        }
        let id = try JSONDecoder().decode(UUID.self, from: command.payload)
        guard var job = jobs[id] else { throw FeatureRPC.Failure.unavailable }
        switch command.action {
        case "media.poll": return try encode(FeatureMediaReply(
                result: job.result,
                finished: job.returned && job.reaped, busy: job.busy
            ))
        case "media.cancel":
            job.cancelled = true; job.task?.cancel()
            if job.task == nil {
                job.returned = true; job.reaped = true; queue.removeAll { $0 == id }
            }
            jobs[id] = job
            notify(id)
        case "media.ack":
            guard job.returned, job.reaped else { throw FeatureRPC.Failure.busy }
            job.deadlineTask?.cancel(); jobs[id] = nil
        default: throw FeatureRPC.Failure.invalidMessage
        }
        return try encode(FeatureRPC.Empty())
    }

    func wait(_ command: FeatureCommand) async throws -> Data {
        let id = try JSONDecoder().decode(UUID.self, from: command.payload)
        guard let job = jobs[id], waiters[id] == nil else { throw FeatureRPC.Failure.unavailable }
        if job.returned, job.reaped {
            return try JSONEncoder().encode(FeatureMediaReply(
                result: job.result,
                finished: true, busy: job.busy
            ))
        }
        let reply = await withCheckedContinuation { waiters[id] = $0 }
        return try JSONEncoder().encode(reply)
    }

    private func notify(_ id: UUID) {
        guard let job = jobs[id], job.returned, job.reaped else { return }
        job.deadlineTask?.cancel()
        waiters.removeValue(forKey: id)?.resume(returning: .init(result: job.result, finished: true, busy: job.busy))
    }

    private func expireQueued(_ id: UUID) {
        guard var job = jobs[id], job.task == nil, !job.returned else { return }
        job.busy = true; job.returned = true; job.reaped = true
        jobs[id] = job; queue.removeAll { $0 == id }; notify(id)
    }

    static func validate(_ request: FeatureMediaJob) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let url = URL(fileURLWithPath: request.directory).standardizedFileURL
        var info = stat()
        let input = try JSONDecoder().decode(MediaRequest.self, from: request.input)
        try input.validate()
        guard input.id == request.id, request.input.count <= MediaPreviewOptions.requestBytes,
              request.timeout.isFinite, request.timeout > 0, request.timeout <= 600,
              request.outputLimit > 0, request.outputLimit <= MediaLimits.responseBytes,
              url.deletingLastPathComponent().resolvingSymlinksInPath() == root,
              url.lastPathComponent == "typeflux-media-" + request.id.uuidString,
              lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw FeatureRPC.Failure.invalidMessage }
    }

    private func advance() {
        guard !stopped else { return }
        onBusy?(jobs.values.contains { $0.task != nil && !$0.reaped })
        while jobs.values.filter({ $0.task != nil && !$0.reaped }).count < maximumActive, !queue.isEmpty {
            let id = queue.removeFirst()
            guard let job = jobs[id], !job.cancelled else { continue }
            let request = job.request
            jobs[id]?.task = Task { [weak self] in
                if let execution = self?.execution {
                    do {
                        let result = try await execution(request) { Task { @MainActor [weak self] in self?.reaped(id) } }
                        self?.finished(id, result: result, reaped: false)
                    } catch { self?.finished(id, result: nil, reaped: true) }
                    return
                }
                let cancellation = AskSearchCancellation()
                let lease: FeatureHelperBudget.Lease
                do {
                    lease = try await withTaskCancellationHandler {
                        try await Task.detached(priority: .userInitiated) {
                            try FeatureHelperBudget.shared.acquire(
                                deadline: Date().addingTimeInterval(8),
                                cancelled: { cancellation.isCancelled }
                            )
                        }.value
                    } onCancel: { cancellation.cancel() }
                } catch { self?.jobs[id]?.busy = true; self?.finished(id, result: nil, reaped: true); return }
                guard let deadline = self?.jobs[id]?.deadline else { lease.finish(); return }
                let duration = ContinuousClock.now.duration(to: deadline).components
                let remaining = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
                guard remaining > 0 else {
                    lease.finish(); self?.jobs[id]?.busy = true; self?.finished(id, result: nil, reaped: true); return
                }
                let fd = open(request.directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { self?.finished(id, result: nil, reaped: true); return }
                defer { close(fd) }
                let launched = HotkeyRecordingFlag()
                do {
                    let result = try await ManagedProcess().run(.init(executable: MediaWorker.helperURL.path,
                                                                      environment: [
                                                                          "PATH": "/usr/bin:/bin",
                                                                          "LANG": "en_US.UTF-8"
                                                                      ], directoryDescriptor: fd,
                                                                      timeout: remaining,
                                                                      outputLimit: request.outputLimit,
                                                                      stopOnOutputLimit: true,
                                                                      preserveWhitespace: true,
                                                                      onStarted: { launched.value = true },
                                                                      stdin: request.input, stderrLimit: 1024,
                                                                      onReaped: {
                                                                          lease
                                                                              .finish(); Task { @MainActor [
                                                                                  weak self
                                                                              ] in
                                                                                  self?.reaped(id)
                                                                              }
                                                                      }))
                    self?.finished(id, result: result, reaped: false)
                } catch {
                    // A launch failure has no child. ManagedProcess retains any
                    // launched child until its onReaped callback.
                    if !launched.value {
                        lease.finish()
                    }
                    self?.finished(id, result: nil, reaped: !launched.value)
                }
            }
            onBusy?(true)
        }
    }

    private func finished(_ id: UUID, result: ManagedProcess.Result?, reaped: Bool) {
        jobs[id]?.result = result; jobs[id]?.returned = true
        if reaped {
            jobs[id]?.reaped = true
        }
        notify(id); collectOrphan(id); advance()
    }

    private func reaped(_ id: UUID) {
        jobs[id]?.reaped = true; notify(id); collectOrphan(id); advance()
    }

    private func collectOrphan(_ id: UUID) {
        guard let job = jobs[id], job.orphaned, job.returned, job.reaped else { return }
        job.deadlineTask?.cancel(); jobs[id] = nil
        let directory = job.request.directory
        DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(atPath: directory) }
    }

    var isBusy: Bool {
        jobs.values.contains { !$0.returned || !$0.reaped }
    }

    func shutdown(timeout: Duration = .seconds(2)) async throws {
        stop()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while isBusy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard !isBusy else { throw FeatureRPC.Failure.busy }
    }

    func stop() {
        stopped = true; queue.removeAll()
        for id in Array(jobs.keys) {
            jobs[id]?.orphaned = true; jobs[id]?.deadlineTask?.cancel(); jobs[id]?.task?.cancel()
            if jobs[id]?.task == nil {
                jobs[id]?.returned = true; jobs[id]?.reaped = true
            }
            notify(id); collectOrphan(id)
        }
    }
}
