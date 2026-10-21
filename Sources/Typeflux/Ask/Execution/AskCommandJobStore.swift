import Darwin
import Foundation

/// Main-actor admission and task ownership; drain buffers are independently locked.
/// Disk records are evidence, never process handles or permission grants.
@MainActor
final class AskCommandJobStore {
    enum State: String, Codable { case starting, running, exited, cancelled, interrupted
        case timedOut = "timed_out", failedToStart = "failed_to_start"
    }

    struct Record: Codable {
        var version = 1
        let handle: String
        let owner: String
        let conversation: String
        let run: String
        let device: String
        let invocation: String
        let digest: String
        let created: Date
        var updated: Date
        var state: State = .starting
        var exitCode: Int32?
        var ambiguous = false
        var stdout = AskCommandJobBuffer.Stream()
        var stderr = AskCommandJobBuffer.Stream()
        var durabilityAvailable = true
        var live: Bool {
            state == .starting || state == .running
        }
    }

    struct Status: Codable {
        enum CodingKeys: String, CodingKey {
            case jobId = "job_id", state, exitCode = "exit_code", outcomeAmbiguous = "outcome_ambiguous"
            case durabilityAvailable = "durability_available", lifetime
        }

        let jobId: String
        let state: String
        let exitCode: Int32?
        let outcomeAmbiguous: Bool
        let durabilityAvailable: Bool
        let lifetime: String
    }

    struct Logs: Encodable {
        enum CodingKeys: String, CodingKey {
            case status, text, nextOffset = "next_offset", retainedBytes = "retained_bytes"
            case omittedBytes = "omitted_bytes", incomplete
        }

        let status: Status
        let text: String
        let nextOffset: Int
        let retainedBytes: Int
        let omittedBytes: UInt64
        let incomplete: Bool
    }

    private final class Entry {
        var record: Record
        let scope: AskCommandJobScope?
        let persistent: Bool
        let buffer: AskCommandJobBuffer
        var task: Task<Void, Never>?
        var stopping = false
        init(record: Record, scope: AskCommandJobScope?, persistent: Bool) {
            self.record = record; self.scope = scope; self.persistent = persistent
            buffer = .init(stdout: record.stdout, stderr: record.stderr)
        }
    }

    private struct Binding {
        let scope: AskCommandJobScope
        let persistent: Bool
        var revoked = false
    }

    struct Hooks {
        var prepare: @MainActor (URL?) throws -> AskHostCommand.Prepared = AskHostCommand.prepare
        var run: @Sendable (ManagedProcess.Request) async throws -> ManagedProcess
            .Result = { try await ManagedProcess().run($0) }
        var beforePersist: @MainActor () throws -> Void = {}
        var now: @MainActor () -> Date = Date.init
    }

    static let maximumRecordBytes = 196_608
    private let storage: AskSecureDirectory?
    private let hooks: Hooks
    private var entries: [String: Entry] = [:]
    private var retiring: [String: Entry] = [:]
    private var storageHealthy = true
    private var bindings: [String: Binding] = [:]
    private var closed = false

    /// nil storage is explicitly memory-only (including injected tests).
    init(root: URL?, hooks: Hooks = .init()) throws {
        self.hooks = hooks
        storage = try root.map { try AskSecureDirectory.openRoot($0) }
        try storage?.lock()
        try load()
    }

    deinit {
        for entry in entries.values {
            entry.buffer.close(); entry.task?.cancel()
        }
        for entry in retiring.values {
            entry.task?.cancel()
        }
    }

    @discardableResult
    func bind(owner: String, conversation: String, run: String, device: String,
              persistent: Bool) -> AskCommandJobScope {
        if let old = bindings[conversation], old.scope.owner == owner, old.scope.run == run,
           old.scope.device == device {
            return old.scope
        }
        if let old = bindings[conversation] {
            cancelRun(old.scope)
        }
        // An account transition invalidates all admitted authority, including other conversations.
        for binding in Array(bindings.values) where binding.scope.owner != owner {
            cancelRun(binding.scope)
        }
        let scope = AskCommandJobScope(
            owner: owner,
            conversation: conversation,
            run: run,
            device: device,
            generation: UUID()
        )
        bindings[conversation] = Binding(scope: scope, persistent: persistent)
        return scope
    }

    func scope(owner: String, conversation: String) throws -> AskCommandJobScope {
        guard !closed, let binding = bindings[conversation],
              binding.scope.owner == owner else { throw AskCommandJobError.unavailable }
        return binding.scope
    }

    private func validate(_ scope: AskCommandJobScope) throws {
        guard !closed, let binding = bindings[scope.conversation], binding.scope == scope, !binding.revoked else {
            throw AskCommandJobError.unavailable
        }
    }

    /// Workspace preparation may suspend. All live authority is rechecked afterward.
    func start(
        _ request: AskCommandJobRequest,
        scope: AskCommandJobScope,
        invocationID: String,
        deadline: Date?,
        workspace: () async throws -> URL?,
        authorize: () throws -> Void,
        admission: @escaping @MainActor () throws -> Void = {}
    ) async throws -> Status {
        guard request.action == "start", (1 ... 600).contains(request.timeout),
              !request.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.command.utf8.count <= 1200, !request.command.contains("\0"), !invocationID.isEmpty,
              [scope.owner, scope.conversation, scope.run, scope.device, invocationID]
              .allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }) else {
            throw AskCommandJobError.invalid
        }
        try validate(scope)
        let digest = AskToolPolicy.digest(request.command + "\0" + String(request.timeout))
        if let existing = try retransmission(scope, invocation: invocationID, digest: digest) {
            return status(existing)
        }
        try authorize()
        try Task.checkCancellation()
        let directory = try await workspace()
        try validate(scope); try authorize(); try Task.checkCancellation()
        let prepared = try hooks.prepare(directory)
        // No suspension from this revalidation through persistence and task installation.
        try validate(scope); try authorize(); try Task.checkCancellation()
        let timeout = min(TimeInterval(request.timeout), deadline?.timeIntervalSince(hooks.now()) ?? .infinity)
        guard timeout > 0 else { throw CancellationError() }
        if let existing = try retransmission(scope, invocation: invocationID, digest: digest) {
            return status(existing)
        }
        prune()
        guard storageHealthy else { throw AskCommandJobError.storage }
        let live = (Array(entries.values) + Array(retiring.values)).filter(\.record.live)
        guard live.count < 4,
              live.filter({ $0.record.owner == scope.owner && $0.record.conversation == scope.conversation }).count < 2
        else {
            throw AskCommandJobError.capacity
        }
        let record = Record(
            handle: UUID().uuidString.lowercased(),
            owner: scope.owner,
            conversation: scope.conversation,
            run: scope.run,
            device: scope.device,
            invocation: invocationID,
            digest: digest,
            created: hooks.now(),
            updated: hooks.now()
        )
        let entry = Entry(record: record, scope: scope, persistent: bindings[scope.conversation]?.persistent == true)
        try persist(entry) // Initial evidence must be durable before any possible spawn.
        entries[record.handle] = entry
        let buffer = entry.buffer, runner = hooks.run
        let expires = hooks.now().addingTimeInterval(timeout)
        entry.task = Task { [weak self, weak entry] in
            // Cancellation between installation and this task's first instruction creates no child.
            let result: Result<ManagedProcess.Result, Error>
            do {
                try Task.checkCancellation()
                guard let self else { throw CancellationError() }
                try validate(scope)
                try admission()
                let remaining = expires.timeIntervalSince(hooks.now())
                guard remaining > 0 else { throw CancellationError() }
                result = try await .success(runner(.init(
                    executable: "/bin/zsh", arguments: ["-f", "-c", request.command], environment: prepared.environment,
                    directoryDescriptor: prepared.directory.descriptor, timeout: remaining, outputLimit: 0,
                    onStarted: { buffer.markStarted() }, onRawOutput: { buffer.append($0, $1) },
                    immediateCleanupOnExit: true
                )))
            } catch { result = .failure(error) }
            withExtendedLifetime(prepared.directory) {}
            guard let self else { return }
            retiring[record.handle] = nil
            guard let entry, entries[record.handle] === entry, entry.scope == scope else { return }
            complete(entry, result: result)
        }
        return status(entry) // Admission only. No await can lose the original-run receipt after spawn.
    }
}

extension AskCommandJobStore {
    private func retransmission(_ scope: AskCommandJobScope, invocation: String, digest: String) throws -> Entry? {
        let existing = entries.values
            .first { $0.record.owner == scope.owner && $0.record.conversation == scope.conversation
                && $0.record.run == scope.run && $0.record.device == scope.device && $0.record.invocation == invocation
            }
        if let existing, existing.record.digest != digest {
            throw AskCommandJobError.conflict
        }
        return existing
    }

    private func lookup(_ handle: String, scope: AskCommandJobScope) throws -> Entry {
        prune()
        guard !closed, let entry = entries[handle], entry.record.owner == scope.owner,
              entry.record.conversation == scope.conversation, entry.record.device == scope.device,
              bindings[scope.conversation]?.scope == scope else { throw AskCommandJobError.unavailable }
        if entry.record
            .live {
            try validate(scope); guard entry.scope == scope else { throw AskCommandJobError.unavailable }
        }
        return entry
    }

    func status(_ handle: String,
                scope: AskCommandJobScope) throws -> Status {
        try status(lookup(handle, scope: scope))
    }

    private func status(_ entry: Entry) -> Status {
        let snapshot = entry.buffer.snapshot()
        return .init(jobId: entry.record.handle,
                     state: entry.stopping && entry.record.live ? "stopping"
                         : entry.record.live && snapshot.started ? "running" : entry.record.state.rawValue,
                     exitCode: entry.record.exitCode,
                     outcomeAmbiguous: entry.record.ambiguous || (entry.stopping && entry.record.live),
                     durabilityAvailable: entry.record.durabilityAvailable,
                     lifetime: AskCommandJobRequest.lifetime)
    }

    func logs(_ handle: String, scope: AskCommandJobScope, stream: ManagedProcess.Stream, offset: Int,
              limit: Int) throws -> Logs {
        guard offset >= 0, (1 ... 16384).contains(limit) else { throw AskCommandJobError.invalid }
        let entry = try lookup(handle, scope: scope), snapshot = entry.buffer.snapshot()
        let data = stream == .stdout ? snapshot.stdout : snapshot.stderr
        let start = min(offset, data.prefix.count), end = start + min(limit, data.prefix.count - start)
        // Explicit lossy byte slicing keeps cursor progress even on invalid/split UTF-8.
        // Lossy decoding is part of the byte-cursor contract.
        // swiftlint:disable:next optional_data_string_conversion
        return .init(status: status(entry), text: String(decoding: data.prefix[start ..< end], as: UTF8.self),
                     nextOffset: end, retainedBytes: data.prefix.count, omittedBytes: data.omitted,
                     incomplete: entry.record.live || data.omitted > 0 || end < data.prefix.count)
    }

    @discardableResult
    func stop(_ handle: String, scope: AskCommandJobScope) throws -> Status {
        let entry = try lookup(handle, scope: scope)
        if entry.record.live {
            try validate(scope)
            guard entry.scope == scope else { throw AskCommandJobError.unavailable }
            cancel(entry)
        }
        return status(entry)
    }

    private func cancel(_ entry: Entry) {
        entry.stopping = true; entry.task?.cancel()
    }

    func cancelRun(_ scope: AskCommandJobScope) {
        if bindings[scope.conversation]?.scope == scope {
            bindings[scope.conversation]?.revoked = true
        }
        for entry in entries.values where entry.scope == scope && entry.record.live {
            cancel(entry)
        }
    }

    func cancelRun(owner: String, conversation: String, run: String) {
        guard let scope = bindings[conversation]?.scope, scope.owner == owner, scope.run == run else { return }
        cancelRun(scope)
    }

    func observeRun(owner: String, conversation: String, run: String?, active: Bool) {
        guard let scope = bindings[conversation]?.scope, scope.owner == owner else { return }
        // Terminal callbacks refer to their original run, never a replacement.
        if run == nil || (!active && scope.run == run) {
            cancelRun(scope)
        }
    }

    func cancelAll(conversation: String? = nil) {
        for binding in Array(bindings.values)
            where conversation == nil || binding.scope.conversation == conversation {
            cancelRun(binding.scope)
        }
    }

    func cancelConversation(owner: String, conversation: String) throws {
        if let scope = bindings[conversation]?.scope,
           scope.owner == owner {
            cancelRun(scope); bindings[conversation] = nil
        }
        var failed = false
        for (handle, entry) in Array(entries)
            where entry.record.owner == owner && entry.record.conversation == conversation {
            cancel(entry); entry.buffer.close()
            if entry.task != nil {
                retiring[handle] = entry
            }
            entries[handle] = nil
            if entry
                .persistent {
                do { try storage?.remove(handle + ".json") } catch { failed = true; storageHealthy = false }
            }
        }
        if failed {
            throw AskCommandJobError.storage
        }
    }

    /// Also used by deterministic host tests; awaiting never transfers task ownership.
    func waitForCompletion(_ handle: String) async {
        await entries[handle]?.task?.value
    }

    func shutdown() async {
        closed = true
        cancelAll()
        let tasks = entries.values.compactMap(\.task) + retiring.values.compactMap(\.task)
        for task in tasks {
            await task.value
        }
    }

    private func complete(_ entry: Entry, result: Result<ManagedProcess.Result, Error>) {
        entry.buffer.close()
        let snapshot = entry.buffer.snapshot()
        entry.record.stdout = snapshot.stdout; entry.record.stderr = snapshot.stderr
        entry.record.updated = hooks.now()
        switch result {
        case let .success(value):
            switch value.termination {
            case .exited: entry.record.state = .exited; entry.record.exitCode = value.exitCode
            case .timedOut: entry.record.state = .timedOut
            case .cancelled: entry.record.state = .cancelled
            case .signalled, .outputLimit: entry.record.state = .interrupted
            }
            entry.record.ambiguous = entry.record.state != .exited
        case .failure:
            entry.record.state = snapshot.started ? .interrupted : entry.stopping ? .cancelled : .failedToStart
            entry.record.ambiguous = snapshot.started
        }
        entry.task = nil
        do { try persist(entry) } catch { entry.record.durabilityAvailable = false }
        prune()
    }

    private func persist(_ entry: Entry) throws {
        guard entry.persistent else { return }
        guard let storage else { throw AskCommandJobError.storage }
        try hooks.beforePersist()
        let data = try JSONEncoder().encode(entry.record)
        guard data.count <= Self.maximumRecordBytes else { throw AskCommandJobError.storage }
        let temporary = ".write-" + UUID().uuidString
        defer { try? storage.remove(temporary) }
        try storage.createFile(temporary, data: data)
        guard renameat(storage.descriptor, temporary, storage.descriptor, entry.record.handle + ".json") == 0 else {
            throw AskCommandJobError.storage
        }
    }

    private func load() throws {
        guard let storage else { return }
        // Fixed enumeration/read bounds. Unknown/corrupt evidence is never overwritten or executed.
        for name in storage.entries(limit: 512).sorted() where name.hasSuffix(".json") && entries.count < 132 {
            let handle = String(name.dropLast(5))
            guard UUID(uuidString: handle) != nil,
                  let data = try? storage.readFile(name, limit: Self.maximumRecordBytes),
                  var record = try? JSONDecoder().decode(Record.self, from: data), record.version == 1,
                  record.handle == handle, record.stdout.prefix.count <= 65536, record.stderr.prefix.count <= 65536,
                  [record.owner, record.conversation, record.run, record.device, record.invocation, record.digest]
                  .allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }) else { continue }
            if record.live {
                record.state = .interrupted; record.ambiguous = true; record.updated = hooks.now()
            }
            let entry = Entry(record: record, scope: nil, persistent: true)
            entries[handle] = entry
            do { try persist(entry) } catch { entry.record.durabilityAvailable = false }
        }
        prune()
    }

    private func prune() {
        let terminal = entries.values.filter { !$0.record.live }.sorted { $0.record.updated > $1.record.updated }
        for (index, entry) in terminal.enumerated()
            where index >= 128 || hooks.now().timeIntervalSince(entry.record.updated) >= 86400 {
            // A failed delete keeps evidence for a later bounded retry; it never grants execution.
            if entry
                .persistent {
                do { try storage?.remove(entry.record.handle + ".json") } catch { storageHealthy = false }
            }
            entry.buffer.close(); entries[entry.record.handle] = nil
        }
    }
}
