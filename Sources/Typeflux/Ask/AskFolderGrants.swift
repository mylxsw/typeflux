import Foundation

/// Local authority only. Historical attachments and UserDefaults are never imported.
final class AskFolderGrants: @unchecked Sendable {
    enum Lifetime: String, Codable, Sendable, CaseIterable { case task, conversationSession }
    struct Scope: Hashable, Sendable {
        let ownerId: String
        let deviceId: String
        let sessionEpoch: UUID
        let conversationId: String
        var taskIdentity: UUID?
        var runId: String?
        var conversation: Scope {
            var copy = self; copy.taskIdentity = nil; copy.runId = nil; return copy
        }
    }

    struct Grant: Identifiable, Sendable {
        let id: UUID
        let revision: UUID
        let root: String
        let rootIdentity: String
        let lifetime: Lifetime
        var scope: Scope
        let messageID: String
        var admitted: Bool
    }

    struct GrantLease: Sendable {
        let grant: Grant
        let executionScope: Scope
    }

    static let maximumConversations = 200
    static let maximumRoots = 32
    static let defaultsKey = "ask.folderGrants"
    private let lock = NSLock()
    private var grants: [Grant] = []
    private var sessionEpoch = UUID()

    /// The parameter is retained solely for composition compatibility; persisted paths are inert.
    init(defaults _: UserDefaults = .standard) {}

    func scope(ownerId: String, deviceId: String, conversationId: String,
               taskIdentity: UUID? = nil, runId: String? = nil) -> Scope {
        lock.lock(); defer { lock.unlock() }
        return Scope(ownerId: ownerId, deviceId: deviceId, sessionEpoch: sessionEpoch,
                     conversationId: conversationId, taskIdentity: taskIdentity, runId: runId)
    }

    @discardableResult
    func stage(_ paths: [String], lifetime: Lifetime, submissionScope: Scope, messageID: String) throws -> [Grant] {
        lock.lock(); defer { lock.unlock() }
        guard submissionScope.sessionEpoch == sessionEpoch, submissionScope.taskIdentity != nil,
              submissionScope.runId == nil, !messageID.isEmpty,
              ![submissionScope.ownerId, submissionScope.deviceId, submissionScope.conversationId].contains("")
        else { throw AskFileAccess.denied }
        let roots = try paths.map { path -> (String, String) in
            guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.contains("\0") else { throw AskFileAccess.denied }
            let root = AskProjectFileAccess.normalizedRoot(path)
            let directory = try AskFileAccess.openRoot(root)
            return try (root, AskFileAccess.identity(directory.descriptor))
        }
        var next = grants.filter {
            !($0.lifetime == .task && $0.scope.conversation == submissionScope.conversation &&
                $0.scope.taskIdentity != submissionScope.taskIdentity)
        }
        for (root, identity) in roots {
            // A lifetime change replaces authority, invalidating every held lease for this root.
            next.removeAll { $0.scope.conversation == submissionScope.conversation && $0.root == root &&
                ($0.lifetime != lifetime || $0.rootIdentity != identity)
            }
            let scope = lifetime == .task ? submissionScope : submissionScope.conversation
            if next.contains(where: { $0.scope == scope && $0.root == root }) {
                continue
            }
            next.append(Grant(id: UUID(), revision: UUID(), root: root, rootIdentity: identity,
                              lifetime: lifetime, scope: scope, messageID: messageID, admitted: false))
        }
        guard Set(next.map(\.scope.conversation)).count <= Self.maximumConversations,
              Set(next.filter { $0.scope.conversation == submissionScope.conversation }.map(\.root)).count <= Self
              .maximumRoots
        else { throw AskLocalError.message("Too many temporary folder grants. Revoke an existing grant and try again.")
        }
        grants = next
        return grants.filter { $0.messageID == messageID && $0.scope.conversation == submissionScope.conversation }
    }

    func bindSubmission(messageID: String, admittedRun: String, trustedScope: Scope) throws {
        lock.lock(); defer { lock.unlock() }
        guard trustedScope.sessionEpoch == sessionEpoch, trustedScope.taskIdentity != nil,
              !admittedRun.isEmpty else { throw AskFileAccess.denied }
        for index in grants.indices where grants[index].messageID == messageID &&
            grants[index].scope.conversation == trustedScope.conversation {
            if grants[index].lifetime == .task {
                guard grants[index].scope.taskIdentity == trustedScope.taskIdentity,
                      grants[index].scope.runId == nil || grants[index].scope.runId == admittedRun
                else { throw AskFileAccess.denied }
                grants[index].scope.runId = admittedRun
            }
            grants[index].admitted = true
        }
    }

    func list(scope: Scope) -> [Grant] {
        lock.lock(); defer { lock.unlock() }
        guard scope.sessionEpoch == sessionEpoch else { return [] }
        return grants.filter { $0.scope.conversation == scope.conversation }
    }

    private func permits(_ grant: Grant, _ scope: Scope) -> Bool {
        grant.admitted && scope.sessionEpoch == sessionEpoch && scope.runId != nil &&
            grant.scope.conversation == scope.conversation &&
            (grant.lifetime == .conversationSession || grant.scope == scope)
    }

    func roots(for executionScope: Scope) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return grants.filter { permits($0, executionScope) }.map(\.root)
    }

    func capture(_ root: String, executionScope: Scope) throws -> GrantLease {
        lock.lock(); defer { lock.unlock() }
        guard let grant = grants.first(where: { $0.root == root && permits($0, executionScope) }) else {
            throw AskFileAccess.denied
        }
        let directory = try AskFileAccess.openRoot(root)
        guard try AskFileAccess.identity(directory.descriptor) == grant.rootIdentity
        else { throw AskFileAccess.conflict }
        return GrantLease(grant: grant, executionScope: executionScope)
    }

    func validate(_ lease: GrantLease) throws {
        lock.lock(); defer { lock.unlock() }
        guard let grant = grants.first(where: { $0.id == lease.grant.id }),
              grant.revision == lease.grant.revision,
              permits(grant, lease.executionScope) else { throw AskFileAccess.denied }
        let directory = try AskFileAccess.openRoot(grant.root)
        guard try AskFileAccess.identity(directory.descriptor) == lease.grant.rootIdentity
        else { throw AskFileAccess.conflict }
    }

    func revoke(_ id: UUID, scope: Scope) {
        lock.lock(); defer { lock.unlock() }
        grants.removeAll { $0.id == id && $0.scope.conversation == scope.conversation }
    }

    func revokeSubmission(messageID: String, scope: Scope) {
        lock.lock(); defer { lock.unlock() }
        grants.removeAll { $0.messageID == messageID && $0.scope.conversation == scope.conversation && !$0.admitted }
    }

    func revokeTask(scope: Scope) {
        lock.lock(); defer { lock.unlock() }
        grants.removeAll { $0.lifetime == .task && $0.scope.conversation == scope.conversation &&
            (scope.taskIdentity == nil || $0.scope.taskIdentity == scope.taskIdentity)
        }
    }

    func revokeConversation(scope: Scope) {
        lock.lock(); defer { lock.unlock() }
        grants.removeAll { $0.scope.conversation == scope.conversation }
    }

    func resetSession() {
        lock.lock(); defer { lock.unlock() }
        grants.removeAll(); sessionEpoch = UUID()
    }
}
