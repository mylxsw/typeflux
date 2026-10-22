import Foundation
import TypefluxChat

/// Authenticated conversations execute on this Mac. The server's history copy
/// is observation-only; neither synchronization nor observation can advance a run.
actor AskDeviceAPI: AskAPI {
    typealias AccountResolver = @Sendable (String) async throws -> String
    typealias EngineFactory = @Sendable (String, URL) -> AskLocalEngine

    private struct Journal: Codable {
        var pending: [String: AskDeviceSnapshot] = [:]
        var acknowledged: [String: Int64] = [:]
        var deleted: Set<String> = []
        var legacy: Set<String> = []
        var replicas: Set<String> = []
        var adopting: Set<String> = []
    }

    private struct Account {
        let engine: AskLocalEngine
        let lease: AskConversationDirectoryLease?
        let directory: URL
        var journal: Journal
    }

    let requiresExclusiveAccess: Bool
    private let root: URL
    private let legacy: any AskAPI
    private let transport: any AskDeviceTransporting
    private let resolveAccount: AccountResolver
    private let refreshToken: (@Sendable (String) async -> String?)?
    private let factory: EngineFactory
    private var accounts: [String: Account] = [:]
    private var tokens: [String: String] = [:]
    private var tokenOwners: [String: String] = [:]
    private var workers: [String: Task<Void, Never>] = [:]
    private var failures: Set<String> = []
    private var retryAfter: [String: [String: Date]] = [:]
    private var retryDelay: [String: Int] = [:]

    init(root: URL, legacy: any AskAPI, transport: any AskDeviceTransporting = AskDeviceTransport(),
         resolveAccount: @escaping AccountResolver,
         refreshToken: (@Sendable (String) async -> String?)? = nil,
         requiresExclusiveAccess: Bool = false, factory: @escaping EngineFactory) {
        self.requiresExclusiveAccess = requiresExclusiveAccess
        self.root = root; self.legacy = legacy; self.transport = transport
        self.resolveAccount = resolveAccount; self.factory = factory
        self.refreshToken = refreshToken
    }

    private func account(_ token: String) async throws -> String {
        let owner: String
        if let resolved = try? await resolveAccount(token) {
            owner = resolved
            tokenOwners[token] = owner
            tokens[owner] = token
        } else if let bound = tokenOwners[token], let fresh = await refreshToken?(bound),
                  await (try? resolveAccount(fresh)) == bound {
            // A previously admitted local call may finish after JWT rotation.
            // Refresh only within that same currently authenticated account.
            owner = bound; tokens[owner] = fresh; tokenOwners[fresh] = owner
        } else { throw AuthError.unauthorized }
        guard AskStorageIdentifier.isValid(owner), !token.isEmpty else { throw AuthError.unauthorized }
        if accounts[owner] == nil {
            let directory = root.appendingPathComponent(owner, isDirectory: true)
            // Acquire before reading the outbox or constructing an engine. A
            // second process must not upload, adopt or delete using stale state.
            let lease = try requiresExclusiveAccess ? AskConversationDirectoryLease(directory: directory) : nil
            let file = directory.appendingPathComponent("sync.json")
            // A corrupt synchronization journal must not silently resurrect
            // deleted history. Execution snapshots remain untouched on failure.
            let journal: Journal = if FileManager.default.fileExists(atPath: file.path) {
                try AskCoding.decoder().decode(Journal.self, from: Data(contentsOf: file))
            } else { Journal() }
            accounts[owner] = Account(
                engine: factory(owner, directory.appendingPathComponent("conversations", isDirectory: true)),
                lease: lease,
                directory: directory,
                journal: journal
            )
            // Execution snapshots are the durable outbox source. Recover a
            // crash between committing an engine result and queuing its sync.
            var offset = 0
            while let engine = accounts[owner]?.engine {
                let page = try await engine.list(token: "", offset: offset)
                for item in page {
                    let value = try await engine.conversation(id: item.id, token: "")
                    queue(value, owner: owner)
                }
                offset += page.count
                if page.count < 50 { break }
            }
        }
        startWorker(owner)
        return owner
    }

    private func persist(_ owner: String) throws {
        guard let account = accounts[owner] else { return }
        try FileManager.default.createDirectory(at: account.directory, withIntermediateDirectories: true)
        // The engine already owns the durable content. Keep only identities and
        // revisions here, rather than rewriting every offline attachment on each
        // step. Deletion tombstones remain durable after the engine file is gone.
        var journal = account.journal
        for id in journal.pending.keys {
            journal.pending[id]?.conversation = nil
        }
        try AskPrivateFile.write(AskCoding.encoder().encode(journal),
                                 to: account.directory.appendingPathComponent("sync.json"))
    }

    private func queue(_ value: AskConversation, owner: String) {
        guard let device = value.run?.deviceId, !device.isEmpty,
              accounts[owner]?.journal.deleted.contains(value.id) == false,
              accounts[owner]?.journal.adopting.contains(value.id) == false,
              value.revision > (accounts[owner]?.journal.acknowledged[value.id] ?? 0),
              value.revision > (accounts[owner]?.journal.pending[value.id]?.revision ?? 0) else { return }
        accounts[owner]?.journal.pending[value.id] = .init(
            deviceId: device,
            revision: value.revision,
            conversation: value
        )
        // A sync-journal failure never rolls back committed execution. The next
        // launch reconstructs pending snapshots from the engine's own files.
        do { try persist(owner) } catch { failures.insert(owner) }
        startWorker(owner)
    }

    private func startWorker(_ owner: String) {
        guard workers[owner] == nil, accounts[owner]?.journal.pending.isEmpty == false else { return }
        workers[owner] = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = await self?.synchronizeOne(owner) else { return }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }

    private func synchronizeOne(_ owner: String) async -> Double? {
        if let fresh = await refreshToken?(owner), await (try? resolveAccount(fresh)) == owner {
            tokens[owner] = fresh; tokenOwners[fresh] = owner
        }
        guard !Task.isCancelled, let token = tokens[owner], await (try? resolveAccount(token)) == owner,
              let pending = accounts[owner]?.journal.pending, !pending.isEmpty else {
            workers[owner] = nil
            return nil
        }
        guard let (id, queued) = pending.first(where: { (retryAfter[owner]?[$0.key] ?? .distantPast) <= Date() })
        else { return 1 }
        do {
            var snapshot = queued
            if !snapshot.deleted, snapshot.conversation == nil, let engine = accounts[owner]?.engine {
                let value = try await engine.conversation(id: id, token: "")
                guard accounts[owner]?.journal.pending[id]?.deleted != true else { return 0 }
                guard value.revision >= snapshot.revision else { throw AskLocalError.message(L("ask.cache.failed")) }
                snapshot = .init(deviceId: snapshot.deviceId, revision: value.revision, conversation: value)
            }
            try await transport.put(id: id, snapshot: snapshot, token: token)
            try Task.checkCancellation()
            let acknowledged = max(accounts[owner]?.journal.acknowledged[id] ?? 0, snapshot.revision)
            accounts[owner]?.journal.acknowledged[id] = acknowledged
            if let current = accounts[owner]?.journal.pending[id], current.revision <= snapshot.revision,
               current.deleted == snapshot.deleted { accounts[owner]?.journal.pending[id] = nil }
            try persist(owner)
            retryAfter[owner]?[id] = nil
            if accounts[owner]?.journal.pending.isEmpty == true { failures.remove(owner) }
            retryDelay[owner] = 1
        } catch {
            failures.insert(owner)
            let delay = retryDelay[owner] ?? 1
            retryAfter[owner, default: [:]][id] = Date().addingTimeInterval(TimeInterval(delay))
            retryDelay[owner] = min(60, delay * 2)
        }
        return 0
    }

    func shutdown() {
        for task in workers.values {
            task.cancel()
        }
        workers.removeAll()
        tokens.removeAll()
        tokenOwners.removeAll()
    }

    func hasPendingSynchronization(token: String) async throws -> Bool {
        let owner = try await account(token)
        return accounts[owner]?.journal.pending.isEmpty == false || failures.contains(owner)
    }

    func historySyncPending(token: String) async -> Bool {
        guard let owner = try? await account(token) else { return false }
        return accounts[owner]?.journal.pending.isEmpty == false
    }

    private func ensureAvailable(_ id: String, owner: String) throws -> AskLocalEngine {
        guard AskStorageIdentifier.isValid(id), let account = accounts[owner],
              !account.journal.deleted.contains(id) else {
            throw AskLocalError.message(L("ask.local.notFound"))
        }
        return account.engine
    }

    private func localValue(_ id: String, owner: String) async throws -> AskConversation? {
        let engine = try ensureAvailable(id, owner: owner)
        do { return try await engine.conversation(id: id, token: "") }
        catch let AskLocalError.message(message) where message == L("ask.local.notFound") { return nil }
    }

    private func commit(_ value: AskConversation, owner: String) async -> AskConversation {
        if let engine = accounts[owner]?.engine, await !(engine.isTemporary(value.id)) { queue(value, owner: owner) }
        return value
    }

    func list(token: String, offset: Int) async throws -> [AskConversationSummary] {
        let owner = try await account(token)
        guard let engine = accounts[owner]?.engine else { throw AuthError.unauthorized }
        var local: [AskConversationSummary] = [], pageOffset = 0
        while true {
            let page = try await engine.list(token: "", offset: pageOffset)
            local += page; pageOffset += page.count
            if page.count < 50 { break }
        }
        var remote: [AskConversationSummary] = []
        do {
            while remote.count < max(0, offset) + 50 + local.count {
                let page = try await transport.list(token: token, offset: remote.count)
                remote += page
                if page.count < 50 { break }
            }
        } catch {
            // Older servers still expose legacy history. Failure to list either
            // service cannot hide or interrupt device-owned conversations.
            remote = await (try? legacy.list(token: token, offset: 0)) ?? []
            failures.insert(owner)
        }
        guard try await resolveAccount(token) == owner else { throw CancellationError() }
        // Concurrent uploads can move a row across offset-page boundaries.
        // Deduplicate those rows rather than trapping on a repeated identity.
        var byID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { $0.updatedAt >= $1.updatedAt ? $0 : $1 })
        for item in local {
            byID[item.id] = item
        }
        let sorted = byID.values.filter { accounts[owner]?.journal.deleted.contains($0.id) != true }
            .sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
        return Array(sorted.dropFirst(max(0, offset)).prefix(50))
    }

    func conversation(id: String, token: String) async throws -> AskConversation {
        let owner = try await account(token)
        if let value = try await localValue(id, owner: owner) { return value }
        if let snapshot = try await transport.snapshot(id: id, token: token), let value = snapshot.conversation {
            accounts[owner]?.journal.replicas.insert(id)
            try persist(owner)
            return value
        }
        let value = try await legacy.conversation(id: id, token: token)
        accounts[owner]?.journal.legacy.insert(id)
        try persist(owner)
        return value
    }

    func send(conversationId id: String, request: AskSendRequest, token: String) async throws -> AskConversation {
        let owner = try await account(token)
        let engine = try ensureAvailable(id, owner: owner)
        if try await localValue(id, owner: owner) == nil {
            guard accounts[owner]?.journal.replicas.contains(id) != true
            else { throw AskLocalError.message(L("ask.tool.otherDevice")) }
            if request.deviceCreate != true {
                _ = try await conversation(id: id, token: token)
                guard accounts[owner]?.journal.legacy.contains(id) == true
                else { throw AskLocalError.message(L("ask.tool.otherDevice")) }
            }
        }
        try await adoptLegacy(id, owner: owner, device: request.deviceId, token: token)
        return try await commit(engine.send(conversationId: id, request: request, token: ""), owner: owner)
    }

    private func adoptLegacy(
        _ id: String,
        owner: String,
        device: String,
        token: String,
        sameDevice: Bool = false
    ) async throws {
        let engine = try ensureAvailable(id, owner: owner)
        guard accounts[owner]?.journal.replicas.contains(id) != true
        else { throw AskLocalError.message(L("ask.tool.otherDevice")) }
        if try await localValue(id, owner: owner) == nil, accounts[owner]?.journal.legacy.contains(id) == true {
            let value = try await legacy.conversation(id: id, token: tokens[owner] ?? token)
            guard value.run?.isActive != true,
                  value.run?.needsRecoveryInspection != true else { throw AskLocalError.message(L("ask.local.busy")) }
            if sameDevice, let run = value.run,
               run.deviceId != device { throw AskLocalError.message(L("ask.tool.otherDevice")) }
            accounts[owner]?.journal.adopting.insert(id)
            try persist(owner)
            try await engine.importLegacy(value)
        }
        if accounts[owner]?.journal.adopting.contains(id) == true {
            var seed = try await engine.conversation(id: id, token: "")
            seed.run?.deviceId = device
            let claim = AskDeviceSnapshot(deviceId: device, revision: seed.revision, conversation: seed)
            // This one-time migration is confirmed before dispatch. All later
            // task progress uses the independent, nonblocking outbox.
            do { try await transport.put(id: id, snapshot: claim, token: tokens[owner] ?? token) }
            catch let ChatAPIError.server("ASK_CONFLICT", message) {
                // A definite rejection leaves the old owner in charge. A lost
                // response instead retains the adoption intent for safe retry.
                try await engine.delete(conversationId: id, token: "")
                accounts[owner]?.journal.adopting.remove(id)
                try persist(owner)
                throw ChatAPIError.server(code: "ASK_CONFLICT", message: message)
            }
            accounts[owner]?.journal.acknowledged[id] = seed.revision
            accounts[owner]?.journal.adopting.remove(id)
            try persist(owner)
        }
    }

    /// Existing active server runs retain their original route until they settle.
    /// Replicas fetched from device history are never execution seeds.
    private func execution(_ id: String, owner: String) async throws -> (any AskAPI, String) {
        let engine = try ensureAvailable(id, owner: owner)
        guard accounts[owner]?.journal.adopting.contains(id) != true
        else { throw AskLocalError.message(L("ask.local.conflict")) }
        guard accounts[owner]?.journal.replicas.contains(id) != true
        else { throw AskLocalError.message(L("ask.tool.otherDevice")) }
        if try await localValue(id, owner: owner) != nil { return (engine, "") }
        if accounts[owner]?.journal.legacy.contains(id) == true, let token = tokens[owner] { return (legacy, token) }
        throw AskLocalError.message(L("ask.tool.otherDevice"))
    }

    func inferenceResult(conversationId id: String, request: AskInferenceResult,
                         token: String) async throws -> AskConversation {
        let owner = try await account(token), (api, route) = try await execution(id, owner: owner)
        let value = try await api.inferenceResult(conversationId: id, request: request, token: route)
        return route.isEmpty ? await commit(value, owner: owner) : value
    }

    func result(conversationId id: String, request: AskToolResultRequest,
                token: String) async throws -> AskConversation {
        let owner = try await account(token), (api, route) = try await execution(id, owner: owner)
        let value = try await api.result(conversationId: id, request: request, token: route)
        return route.isEmpty ? await commit(value, owner: owner) : value
    }

    func cancel(conversationId: String, runId: String, token: String) async throws -> AskConversation {
        try await cancel(conversationId: conversationId, runId: runId, partial: nil, token: token)
    }

    func cancel(conversationId id: String, runId: String, partial: AskInferenceResult?,
                token: String) async throws -> AskConversation {
        let owner = try await account(token), (api, route) = try await execution(id, owner: owner)
        let value = try await api.cancel(conversationId: id, runId: runId, partial: partial, token: route)
        return route.isEmpty ? await commit(value, owner: owner) : value
    }

    func retry(conversationId: String, runId: String, deviceId: String, modelRef: String?,
               token: String) async throws -> AskConversation {
        try await retry(
            conversationId: conversationId,
            runId: runId,
            deviceId: deviceId,
            modelRef: modelRef,
            maxSteps: nil,
            token: token
        )
    }

    func retry(
        conversationId id: String,
        runId: String,
        deviceId: String,
        modelRef: String?,
        maxSteps: Int?,
        token: String
    ) async throws -> AskConversation {
        let owner = try await account(token)
        if try await localValue(id, owner: owner) == nil { _ = try await conversation(id: id, token: token) }
        try await adoptLegacy(id, owner: owner, device: deviceId, token: token, sameDevice: true)
        let (api, route) = try await execution(id, owner: owner)
        let value = try await api.retry(
            conversationId: id,
            runId: runId,
            deviceId: deviceId,
            modelRef: modelRef,
            maxSteps: maxSteps,
            token: route
        )
        return route.isEmpty ? await commit(value, owner: owner) : value
    }

    func regenerate(conversationId id: String, request: AskRegenerateRequest,
                    token: String) async throws -> AskConversation {
        let owner = try await account(token)
        if try await localValue(id, owner: owner) == nil { _ = try await conversation(id: id, token: token) }
        try await adoptLegacy(id, owner: owner, device: request.deviceId, token: token)
        let (api, route) = try await execution(id, owner: owner)
        let value = try await api.regenerate(conversationId: id, request: request, token: route)
        return route.isEmpty ? await commit(value, owner: owner) : value
    }

    func steer(conversationId id: String, request: AskSteerRequest, token: String) async throws -> AskConversation {
        let owner = try await account(token), (api, route) = try await execution(id, owner: owner)
        let value = try await api.steer(conversationId: id, request: request, token: route)
        return route.isEmpty ? await commit(value, owner: owner) : value
    }

    func recover(conversationId id: String, request: AskRecoveryRequest, token: String) async throws -> AskConversation {
        let owner = try await account(token), (api, route) = try await execution(id, owner: owner)
        let value = try await api.recover(conversationId: id, request: request, token: route)
        return route.isEmpty ? await commit(value, owner: owner) : value
    }

    func resume(conversationId id: String, runId: String, token: String) async throws -> AskConversation {
        let owner = try await account(token), (api, route) = try await execution(id, owner: owner)
        let value = try await api.resume(conversationId: id, runId: runId, token: route)
        return route.isEmpty ? await commit(value, owner: owner) : value
    }

    func updateTitle(id: String, request: AskTitleRequest, token: String) async throws -> AskConversation {
        let owner = try await account(token), (api, route) = try await execution(id, owner: owner)
        let value = try await api.updateTitle(id: id, request: request, token: route)
        return route.isEmpty ? await commit(value, owner: owner) : value
    }

    func keep(conversationId id: String, token: String) async throws -> AskConversation {
        let owner = try await account(token), (api, route) = try await execution(id, owner: owner)
        let value = try await api.keep(conversationId: id, token: route)
        return route.isEmpty ? await commit(value, owner: owner) : value
    }

    func usage(id: String, runId: String?, cursor: Int64?, token: String) async throws -> AskUsagePage {
        let owner = try await account(token), (api, route) = try await execution(id, owner: owner)
        return try await api.usage(id: id, runId: runId, cursor: cursor, token: route)
    }

    func models(token: String) async throws -> [AskCloudModel] {
        try await legacy.models(token: token)
    }

    func models(token: String, scenario: String) async throws -> [AskCloudModel] {
        try await legacy.models(
            token: token,
            scenario: scenario
        )
    }

    func featureModels(feature: String,
                       token: String) async throws -> [AskCloudModel]? {
        try await legacy.featureModels(
            feature: feature,
            token: token
        )
    }

    func purgeMemory(token: String) async throws {
        let owner = try await account(token)
        try await accounts[owner]?.engine.purgeMemory(token: "")
        try await legacy.purgeMemory(token: token)
    }

    func delete(conversationId id: String, token: String) async throws {
        let owner = try await account(token)
        let engine = try ensureAvailable(id, owner: owner)
        if await engine.isTemporary(id) {
            try await engine.delete(conversationId: id, token: "")
            return
        }
        if let value = try await localValue(id, owner: owner), let device = value.run?.deviceId {
            accounts[owner]?.journal.deleted.insert(id)
            accounts[owner]?.journal.pending[id] = .init(deviceId: device, revision: value.revision + 1, deleted: true)
            try persist(owner)
            try await engine.delete(conversationId: id, token: "")
            startWorker(owner)
        } else if accounts[owner]?.journal.legacy.contains(id) == true {
            try await legacy.delete(conversationId: id, token: token)
        } else { throw AskLocalError.message(L("ask.tool.otherDevice")) }
    }
}
