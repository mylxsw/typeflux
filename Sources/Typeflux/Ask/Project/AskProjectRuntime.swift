import AppKit
import Foundation

struct AskProjectRuntimeLease: Codable, Equatable {
    let id: String
    let sessionId: String
    let workspace: AskWorkspaceRef
    let root: String
    let createdAt: Date
    let port: UInt16?
}

/// Host-only D02 seam. D04 owns AskLocalTools/DI registration and UI rollout.
/// Model-provided WorkspaceRef/handle values are never execution authority.
@MainActor
final class AskProjectRuntime {
    private struct Entry {
        let lease: AskProjectRuntimeLease
        let process: AskTerminalSession
        let authorizedRoots: () -> [String]
    }

    private let enabled: Bool
    private let projects: AskProjectWorkspace
    private let storage: AskSecureDirectory
    private let notificationCenter: NotificationCenter
    private let sessionId = UUID().uuidString.lowercased()
    private var entries: [String: Entry] = [:]
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var closed = false
    private var invalidationObservers: [UUID: (AskProjectRuntimeLease, () -> Void)] = [:]
    private(set) var invalidatedLeases: [AskProjectRuntimeLease] = []

    init(storageURL: URL, projects: AskProjectWorkspace, enabled: Bool = false,
         notificationCenter: NotificationCenter = .default) throws {
        self.enabled = enabled; self.projects = projects
        self.notificationCenter = notificationCenter
        storage = try AskSecureDirectory.openRoot(storageURL)
        try storage.lock()
        // The journal is historical evidence only. Never resume commands or kill
        // stored PIDs: after a crash their identities may have been reused.
        for name in storage.entries(limit: 129) {
            guard let directory = try? storage.child(name),
                  let data = try? directory.readFile("lease.json", limit: 16384),
                  let lease = try? JSONDecoder().decode(AskProjectRuntimeLease.self, from: data) else { continue }
            invalidatedLeases.append(lease)
            if (try? directory.readFile("invalidated", limit: 32)) == nil {
                try directory.createFile("invalidated", data: Data("app-session-ended".utf8))
            }
        }
        observer = notificationCenter.addObserver(forName: NSApplication.willTerminateNotification,
                                                  object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileAuthorization() }
        }
    }

    deinit {
        timer?.invalidate()
        if let observer {
            notificationCenter.removeObserver(observer)
        }
        for entry in entries.values {
            entry.process.stop(.appExit)
        }
    }

    func approval(for request: AskProjectLaunchRequest, workspace: AskWorkspaceRef,
                  scope: AskProjectScope, authorizedRoots: [String], callId: String) throws -> AskApprovalRequest {
        guard enabled, !closed else { throw AskProjectRuntimeError.disabled }
        try AskProjectRuntimePolicy.validate(request)
        _ = try AskProjectRuntimePolicy.interpreter()
        return try projects
            .withValidatedSnapshot(workspace, scope: scope, authorizedRoots: authorizedRoots) { state, _ in
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let arguments = try String(data: encoder.encode(request), encoding: .utf8)!
                let target = AskExecutionTarget(kind: "workspace", id: workspace.id,
                                                version: workspace.version, path: state.root)
                let binding = AskToolBinding(target: target, toolVersion: AskProjectRuntimePolicy.version,
                                             summary: "Run \(request.script) in a private project copy; offline, single process" +
                                                 (request.servicePort == nil ? "." : "; loopback development service."))
                let call = AskToolCall(id: callId, function: .init(name: "project_terminal", arguments: arguments))
                return AskToolPolicy.request(call: call, owner: scope.ownerId, conversation: scope.conversationId,
                                             run: scope.runId, step: callId, binding: binding, risk: .write)
            }
    }

    // Current roots are supplied by the trusted host, re-read after copying and
    // periodically during the lease. Grant consumption and spawn never suspend.
    // swiftlint:disable:next function_parameter_count
    func start(_ request: AskProjectLaunchRequest, workspace: AskWorkspaceRef, scope: AskProjectScope,
               authorizedRoots: @escaping () -> [String], callId: String,
               grantId: String, approvals: AskApprovalStore,
               beforeCopyValidation: (() throws -> Void)? = nil,
               authorize: () throws -> Void = {}) throws -> AskProjectRuntimeLease {
        try Task.checkCancellation()
        let approval = try approval(for: request, workspace: workspace, scope: scope,
                                    authorizedRoots: authorizedRoots(), callId: callId)
        guard entries.values.filter({ [.starting, .running, .ready].contains($0.process.snapshot().state) }).count < 4,
              storage.entries(limit: 129).count < 128 else { throw AskProjectRuntimeError.capacity }
        let interpreter = try AskProjectRuntimePolicy.interpreter()
        let id = UUID().uuidString.lowercased()
        let control = try storage.child(id, create: true, privateDirectory: true)
        var published = false
        defer {
            if !published {
                try? storage.remove(id)
            }
        }
        let project = try control.child("project", create: true, privateDirectory: true)
        let temporary = try control.child("temporary", create: true, privateDirectory: true)
        try projects
            .withValidatedSnapshot(workspace, scope: scope, authorizedRoots: authorizedRoots()) { state, access in
                try AskProjectExecutionCopy.prepare(state, access: access, destination: project,
                                                    beforeValidation: beforeCopyValidation)
            }
        // Verify the requested entry point with no-follow descriptor access.
        guard try AskProjectFileAccess(directory: project).snapshot(request.script).data != nil else {
            throw AskProjectRuntimeError.invalidRequest
        }
        let current = try self.approval(for: request, workspace: workspace, scope: scope,
                                        authorizedRoots: authorizedRoots(), callId: callId)
        try Task.checkCancellation()
        try authorize()
        // Deadline is reconstructed, but the grant matcher compares its own expiry
        // and every stable execution field (including the entire request hash).
        guard current.binding == approval.binding, approvals.consume(grantId, for: current) else {
            throw AskProjectRuntimeError.approvalRequired
        }
        let port = try request.servicePort.map { try AskProjectPortLease(requested: $0) }
        let lease = AskProjectRuntimeLease(id: id, sessionId: sessionId, workspace: workspace,
                                           root: current.binding.target.path!, createdAt: Date(), port: port?.port)
        try control.createFile("lease.json", data: JSONEncoder().encode(lease))
        let process = try AskTerminalSession(request: request, project: project, temporary: temporary,
                                             control: control, interpreter: interpreter, port: port)
        entries[id] = .init(lease: lease, process: process, authorizedRoots: authorizedRoots)
        published = true
        return lease
    }

    private func entry(_ lease: AskProjectRuntimeLease, scope: AskProjectScope) throws -> Entry {
        guard lease.sessionId == sessionId, let entry = entries[lease.id], entry.lease == lease,
              lease.workspace.ownerId == scope.ownerId, lease.workspace.conversationId == scope.conversationId,
              lease.workspace.runId == scope.runId else { throw AskProjectRuntimeError.unknownLease }
        return entry
    }

    func status(_ lease: AskProjectRuntimeLease, scope: AskProjectScope) throws -> AskProjectProcessStatus {
        let entry = try entry(lease, scope: scope)
        reconcileAuthorization()
        return entry.process.snapshot()
    }

    func output(_ lease: AskProjectRuntimeLease, scope: AskProjectScope,
                cursor: Int64, maximumBytes: Int = 65536) throws -> AskTerminalOutput {
        try entry(lease, scope: scope).process.read(cursor: cursor, maximumBytes: maximumBytes)
    }

    /// Each interactive submission needs its own single-use host approval. The
    /// request binds the bytes, EOF flag, lease, workspace and current run.
    func inputApproval(_ lease: AskProjectRuntimeLease, scope: AskProjectScope, data: Data,
                       eof: Bool, callId: String) throws -> AskApprovalRequest {
        let entry = try entry(lease, scope: scope)
        guard !closed, authorized(entry) else { throw AskProjectRuntimeError.denied }
        let call = AskToolCall(id: callId, function: .init(name: "project_terminal",
                                                           arguments: lease.id + ":" + String(eof) + ":" + data
                                                               .base64EncodedString()))
        let binding = AskToolBinding(target: .init(kind: "workspace", id: lease.workspace.id,
                                                   version: lease.workspace.version, path: lease.root),
                                     toolVersion: AskProjectRuntimePolicy.version,
                                     summary: "Send \(data.count) bytes to project process")
        return AskToolPolicy.request(call: call, owner: scope.ownerId, conversation: scope.conversationId,
                                     run: scope.runId, step: callId, binding: binding, risk: .write)
    }

    // swiftlint:disable:next function_parameter_count
    func send(_ data: Data, eof: Bool = false, lease: AskProjectRuntimeLease, scope: AskProjectScope,
              callId: String, grantId: String, approvals: AskApprovalStore) throws {
        let request = try inputApproval(lease, scope: scope, data: data, eof: eof, callId: callId)
        guard approvals.consume(grantId, for: request) else { throw AskProjectRuntimeError.approvalRequired }
        try entry(lease, scope: scope).process.send(data, eof: eof)
    }

    func stop(_ lease: AskProjectRuntimeLease, scope: AskProjectScope) throws {
        try entry(lease, scope: scope).process.stop()
        notifyInvalidations()
    }

    func serviceAddress(_ lease: AskProjectRuntimeLease, scope: AskProjectScope) throws -> URL? {
        guard try status(lease, scope: scope).state == .ready, let port = lease.port else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    func cancel(scope: AskProjectScope) {
        for entry in entries.values where entry.lease.workspace.ownerId == scope.ownerId &&
            entry.lease.workspace.conversationId == scope.conversationId && entry.lease.workspace.runId == scope.runId {
            entry.process.stop(.cancelled)
        }
        notifyInvalidations()
    }

    func workspaceDeleted(_ workspace: AskWorkspaceRef, scope: AskProjectScope) {
        guard workspace.ownerId == scope.ownerId, workspace.conversationId == scope.conversationId,
              workspace.runId == scope.runId else { return }
        for entry in entries.values where entry.lease.workspace.id == workspace.id {
            entry.process.stop(.revoked)
        }
        notifyInvalidations()
    }

    private func authorized(_ entry: Entry) -> Bool {
        guard entry.authorizedRoots().map(AskProjectFileAccess.normalizedRoot).contains(entry.lease.root)
        else { return false }
        // Reopening verifies owner, root identity and source existence without
        // treating a later staged revision as permission to restart the process.
        let workspace = entry.lease.workspace
        let scope = AskProjectScope(
            ownerId: workspace.ownerId,
            conversationId: workspace.conversationId,
            runId: workspace.runId
        )
        return (try? projects.reference(root: entry.lease.root, scope: scope,
                                        authorizedRoots: entry.authorizedRoots()).0.id) == workspace.id
    }

    func reconcileAuthorization() {
        for entry in entries.values where [.starting, .running, .ready].contains(entry.process.snapshot().state) {
            if !authorized(entry) {
                entry.process.stop(.revoked)
            }
        }
        notifyInvalidations()
    }

    /// Host-only subscription. Stop/revocation closes pages synchronously; natural
    /// exit and timeout are detected by the existing 250 ms lifecycle timer.
    func observeInvalidation(_ lease: AskProjectRuntimeLease, scope: AskProjectScope,
                             action: @escaping () -> Void) throws -> UUID {
        guard try status(lease, scope: scope).state == .ready else { throw AskProjectRuntimeError.closed }
        let id = UUID()
        invalidationObservers[id] = (lease, action)
        return id
    }

    func removeObserver(_ id: UUID) { invalidationObservers[id] = nil }

    private func notifyInvalidations() {
        let invalid = invalidationObservers.filter { _, value in
            entries[value.0.id]?.process.snapshot().state != .ready
        }
        for (id, value) in invalid {
            invalidationObservers[id] = nil
            value.1()
        }
    }

    func shutdown() {
        closed = true; timer?.invalidate()
        for entry in entries.values {
            entry.process.stop(.appExit)
        }
        notifyInvalidations()
    }
}

extension AskProjectRuntimeLease {
    var reference: AskProcessRef {
        .init(id: id, ownerId: workspace.ownerId, conversationId: workspace.conversationId,
              runId: workspace.runId, workspaceId: workspace.id, instanceId: sessionId,
              startedAt: Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down)), cleanup: "app_session")
    }
}
