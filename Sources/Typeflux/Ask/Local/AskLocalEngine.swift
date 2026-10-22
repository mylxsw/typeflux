// swiftlint:disable file_length
import Foundation

/// Engine-only state stored next to a local conversation.
struct AskLocalRecord: Codable, Equatable, Sendable {
    var agentRoutes: AskRunRouteArchive?
    var agentState: AskRouteJSON?
    var summaryFallback: Bool?
    var summaryUnavailable: Bool?
    var contextLimits: AskContextLimits?
    var typedContentEnabled: Bool?
    var conversation: AskConversation
    var timeZone: String?
    var locale: String?
    /// The user's calendar date when the run started; pinning it keeps the prompt prefix stable.
    var localDate: String?
    /// Built-in tools of the current run, executed by the engine instead of the device.
    var builtinTools: [AskToolDefinition] = []
    var lastInferenceId: String?
    /// Optional so conversations saved before local metering still load.
    var localUsage: AskLocalUsage?
    var cloudCalls = 0
    var approvedCloudCallId: String?
    /// Messages sent into the running run that the model has not read yet.
    var steering: [AskMessage]?
}

/// Runs Ask conversations entirely on this Mac with the user's own models, for
/// people who are not signed in or keep Ask local. It implements the same API as
/// the Cloud service and mirrors its state machine: every model step becomes an
/// on-device inference (`waiting_inference`) that the conversation model already
/// knows how to run, device tools use the usual approval flow, and conversations
/// are stored as JSON files under Application Support.
actor AskLocalEngine: AskAPI, AskRunRouteAccess {
    static let maxSteps = 100
    static let maxMessages = 500
    static let maxToolCalls = 8
    static let maxBuiltinCalls = 16
    static let maxSteering = 5
    static let steeringStepBonus = 4
    static let maxExtraSteps = 12
    static let summarizeAfter = 28
    static let keepRecent = 12
    static let staleAfter: TimeInterval = 10 * 60

    private let turnPolicy: AskAgentTurnPolicy
    private let allowsCloudModels: Bool
    private let turnWriterLease: AskTurnWriterLease?
    private let turnOwnershipAvailable: Bool
    private let promptBuilder: any AskPromptBuilding
    let directory: URL
    private let snapshotStore: any AskLocalSnapshotStoring
    let budgetStore: any AskBudgetJournaling
    private let prepareImages: @Sendable ([AskMessage]) async -> [AskMessage]
    private let typedContentEnabled: Bool
    private let builtinTools: any AskBuiltinToolHosting
    let budgetEnabled: Bool
    let budgetLimits: AskBudgetResources
    let contextLimits: @Sendable (String) -> AskContextLimits
    let now: @Sendable () -> Date
    private var records: [String: AskLocalRecord] = [:]
    private struct BuiltinFlight {
        let id: UUID
        let runID: String
        let task: Task<[AskBuiltinToolOutput], Never>
    }
    private var builtinFlights: [String: BuiltinFlight] = [:]
    private let summarize: (@Sendable (AskInference, String, String) async -> AskInferenceResult)?
    private struct Preparation {
        var id: String
        var through: Int
        var cut: Int
        var prior: String?
        var prefix: String
        var fallback: Bool
        var task: Task<AskInferenceResult, Never>
        var result: AskInferenceResult?
    }
    private var summaries: [String: Preparation] = [:]
    /// Temporary conversations: kept in memory only and never listed.
    private var temporaryIDs: Set<String> = []
    private var loaded = false

    init(directory: URL = AskLocalEngine.defaultDirectory, webTools: AskLocalWebTools = AskLocalWebTools(),
         now: @escaping @Sendable () -> Date = { Date() }, typedContentEnabled: Bool = false,
         budgetEnabled: Bool = false, budgetLimits: AskBudgetResources = .standard,
         contextLimits: @escaping @Sendable (String) -> AskContextLimits = { _ in .init() },
         summarize: (@Sendable (AskInference, String, String) async -> AskInferenceResult)? = nil,
         prepareImages: @escaping @Sendable ([AskMessage]) async -> [AskMessage] = { await AskTypedContent.prepareHistory($0) },
         promptBuilder: any AskPromptBuilding = DefaultAskPromptBuilder(),
         builtinTools: (any AskBuiltinToolHosting)? = nil,
         snapshotStore: (any AskLocalSnapshotStoring)? = nil,
         budgetStore: (any AskBudgetJournaling)? = nil,
         turnPolicy: AskAgentTurnPolicy = .canonical, allowsCloudModels: Bool = false) {
        self.allowsCloudModels = allowsCloudModels
        self.turnPolicy = turnPolicy
        let writer = turnPolicy.claimWriter(directory: directory)
        turnWriterLease = writer.lease
        turnOwnershipAvailable = !writer.required || writer.lease != nil
        self.promptBuilder = promptBuilder
        self.summarize = summarize
        self.prepareImages = prepareImages
        self.budgetEnabled = budgetEnabled
        self.budgetLimits = budgetLimits
        self.contextLimits = contextLimits
        self.typedContentEnabled = typedContentEnabled
        self.directory = directory
        self.snapshotStore = snapshotStore ?? FileAskLocalSnapshotStore(directory: directory)
        self.budgetStore = budgetStore ?? AskBudgetStore(directory: directory)
        self.builtinTools = builtinTools ?? DefaultAskBuiltinToolHost(webTools: webTools)
        self.now = now
    }

    static var defaultDirectory: URL {
        TypefluxDataDirectories.data.appendingPathComponent("AskLocal", isDirectory: true)
    }

    // MARK: - Storage

    private func loadAll() {
        guard !loaded else { return }
        loaded = true
        snapshotStore.forEachSnapshot { data in
            if var record = try? AskLocalRecord.decodeSnapshot(data) {
                // A persisted engine step may have dispatched a built-in request before exit.
                // Inspect/cancel it; never infer that a fresh process can safely repeat it.
                if (try? resolveTurn(record)) != nil, record.conversation.run?.status == "running" {
                    record.conversation.run?.recovery = .init(state: "unknown_outcome", sequence: record.conversation.revision)
                }
                records[record.conversation.id] = record
            }
        }
    }

    /// Conversation IDs become file names, so only plain identifiers are accepted.
    static func validID(_ id: String) -> Bool {
        AskStorageIdentifier.isValid(id)
    }

    private func save(_ record: inout AskLocalRecord) throws {
        // A helper may report usage while image preparation is suspended. Merge
        // those receipts without replacing the foreground conversation snapshot.
        if let latest = records[record.conversation.id]?.localUsage {
            for item in latest.invocations {
                let usage = item.usage
                if record.localUsage?.invocations.contains(where: { $0.usage.id == usage.id }) == true {
                    if usage.status != "pending" {
                        _ = record.settleUsage(.init(runId: usage.runId, deviceId: item.deviceId,
                            inferenceId: usage.id, content: "", usage: usage.tokens))
                    }
                }
            }
        }
        try refreshBudget(&record)
        record.conversation.revision += 1
        record.conversation.updatedAt = now()
        record.conversation.run?.updatedAt = now()
        try persist(record)
    }

    /// Metering can arrive after a run ends without changing content or activity dates.
    /// A temporary conversation never reaches the disk.
    func persist(_ record: AskLocalRecord) throws {
        var record = record
        let cached = records[record.conversation.id]
        record.agentRoutes = try AskRunRouteArchive.merging(cached: cached?.agentRoutes, incoming: record.agentRoutes,
            previous: cached?.conversation.run, current: record.conversation.run)
        if !temporaryIDs.contains(record.conversation.id) {
            try snapshotStore.writeSnapshot(record.encodeSnapshot(), id: record.conversation.id)
        }
        var retained = record
        for index in retained.conversation.messages.indices { retained.conversation.messages[index].harness?.outcome?.preparedImages = [:] }
        records[record.conversation.id] = retained
        if let flight = builtinFlights[record.conversation.id],
           retained.conversation.run?.id != flight.runID || retained.conversation.run?.status != "running" {
            flight.task.cancel()
        }
    }

    func runRoute(conversationId: String, runId: String) async throws -> AskRunRouteLookup {
        loadAll()
        let id = AskConversationID.canonical(conversationId)
        guard Self.validID(id), let value = records[id] else { throw AskLocalError.message(L("ask.local.notFound")) }
        guard AskStorageIdentifier.isValid(runId) else { throw conflict() }
        return AskRunRouteArchive.lookup(archive: value.agentRoutes, current: value.conversation.run, runID: runId)
    }

    func isTemporary(_ id: String) -> Bool { temporaryIDs.contains(AskConversationID.canonical(id)) }

    private func record(_ id: String) throws -> AskLocalRecord {
        loadAll()
        let id = AskConversationID.canonical(id)
        guard Self.validID(id), var record = records[id] else { throw AskLocalError.message(L("ask.local.notFound")) }
        guard (try? resolveTurn(record)) != nil else { return record }
        record.conversation.memory = record.conversation.memory?.usable(at: now())
        if record.conversation.memory == nil, let payload = record.conversation.run?.inference?.payload {
            record.conversation.run?.inference?.payload = AskMemory.removingInjection(from: payload)
        }
        // An interrupted inference or engine step must not strand the conversation.
        if let run = record.conversation.run, run.isActive, run.status == "running", run.recovery?.blocksExecution != true,
           now().timeIntervalSince(run.updatedAt) > Self.staleAfter {
            keepPartial(&record)
            closePending(&record, reason: "The previous execution expired. It was not replayed.")
            record.conversation.run?.status = "failed"
            record.conversation.run?.error = L("ask.local.expired")
            try save(&record)
        }
        try refreshBudget(&record)
        return record
    }

    /// Metadata edits preserve the activity date and never replace messages.
    func updateTitle(id: String, request: AskTitleRequest, token _: String) async throws -> AskConversation {
        var value = try record(id)
        let changed = try AskConversationTitle.apply(request, to: &value.conversation, now: now())
        if changed {
            value.conversation.titleRevision = (value.conversation.titleRevision ?? 0) + 1
            value.conversation.revision += 1
            try persist(value)
        }
        return value.conversation
    }

    // MARK: - AskAPI

    func list(token _: String, offset: Int) async throws -> [AskConversationSummary] {
        loadAll()
        return records.values.map(\.conversation).filter { !temporaryIDs.contains($0.id) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .dropFirst(max(0, offset)).prefix(50)
            .map { AskConversationSummary(id: $0.id, title: $0.title, updatedAt: $0.updatedAt) }
    }

    func conversation(id: String, token _: String) async throws -> AskConversation {
        try record(id).conversation
    }

    func usage(id: String, runId: String?, cursor: Int64?, token _: String) async throws -> AskUsagePage {
        try record(id).localUsage?.page(runId: runId, cursor: cursor) ?? AskUsagePage(items: [], nextCursor: nil)
    }

    func models(token _: String) async throws -> [AskCloudModel] { [] }
    func models(token _: String, scenario _: String) async throws -> [AskCloudModel] { [] }

    func delete(conversationId: String, token _: String) async throws {
        loadAll()
        let id = AskConversationID.canonical(conversationId)
        guard Self.validID(id) else { return }
        summaries.removeValue(forKey: id)?.task.cancel()
        let flight = builtinFlights[id]
        flight?.task.cancel()
        records[id] = nil
        if let flight { _ = await flight.task.value }
        if temporaryIDs.remove(id) == nil { try? snapshotStore.removeSnapshot(id: id) }
    }

    /// Keeps a temporary conversation as an ordinary one stored on this Mac.
    func keep(conversationId: String, token _: String) async throws -> AskConversation {
        let value = try record(conversationId)
        if temporaryIDs.remove(value.conversation.id) != nil {
            do { try persist(value) }
            catch { temporaryIDs.insert(value.conversation.id); throw error }
        }
        return value.conversation
    }

    func purgeMemory(token _: String) async throws { try clearMemorySnapshots(owner: nil) }

    func purgeMemory(owner: String, token _: String) async throws { try clearMemorySnapshots(owner: owner) }

    private func clearMemorySnapshots(owner: String?) throws {
        loadAll()
        for id in Array(records.keys) where records[id]?.conversation.memory != nil {
            guard var record = records[id] else { continue }
            if let owner, let capturedOwner = record.conversation.memory?.owner, capturedOwner != owner { continue }
            record.conversation.memory = nil
            record.conversation.memoryOff = nil
            if let payload = record.conversation.run?.inference?.payload {
                record.conversation.run?.inference?.payload = AskMemory.removingInjection(from: payload)
            }
            try save(&record)
        }
    }

    func send(conversationId: String, request: AskSendRequest, token: String) async throws -> AskConversation {
        guard token.isEmpty else { throw conflict() }
        loadAll()
        let id = AskConversationID.canonical(conversationId)
        guard Self.validID(id) else { throw AskLocalError.message(L("ask.local.notFound")) }
        let hasQuestion = !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (request.references ?? []).contains { !$0.question.trimmingCharacters(in: .whitespaces).isEmpty }
            || !(request.attachments ?? []).isEmpty
        guard hasQuestion else { throw AskLocalError.message(L("ask.local.emptyQuestion")) }
        if records[id] == nil, request.temporary == true { temporaryIDs.insert(id) }
        var record = records[id] ?? AskLocalRecord(conversation: AskConversation(
            id: id, title: String(Self.title(request).prefix(50)),
            revision: 0, updatedAt: now(), messages: []))
        _ = try resolveTurn(record)
        if record.conversation.messages.contains(where: { $0.id == request.id }) { return record.conversation }
        if record.conversation.run?.isActive == true { throw AskLocalError.message(L("ask.local.busy")) }
        guard record.conversation.messages.count < Self.maxMessages else { throw AskLocalError.message(L("ask.local.full")) }
        let modelRef = try executionModel(request.modelRef)
        var c = record.conversation
        // A temporary conversation neither reads nor keeps memory.
        if c.messages.isEmpty { c.memory = temporaryIDs.contains(id) ? nil : request.memory?.usable(at: now()) }
        c.memoryOff = c.memory != nil && request.memoryOff == true ? true : nil
        if let zone = request.timeZone, TimeZone(identifier: zone) != nil { record.timeZone = zone }
        if let locale = request.locale, !locale.isEmpty, locale.count <= 35 { record.locale = locale }
        c.messages.append(AskMessage(id: request.id, role: "user", text: request.text, selection: request.selection, source: request.source,
                                     image: request.image, createdAt: now(), reasoningEffort: request.reasoningEffort, references: request.references,
                                     attachments: request.attachments, skills: request.skills, mcpServers: request.mcpServers))
        c.titlePolicy = request.titlePolicy ?? c.titlePolicy
        c.auxiliaryModelRef = request.auxiliaryModelRef
        c.modelRef = modelRef
        c.run = AskRun(id: UUID().uuidString.lowercased(), deviceId: request.deviceId, status: "running", steps: 0, updatedAt: now(),
                       tools: request.tools, pending: [], modelRef: modelRef, reasoningEffort: request.reasoningEffort)
        c.run?.maxSteps = try Self.configuredMaxSteps(request.maxSteps)
        c.run?.clientToolApproval = request.clientToolApproval
        c.run?.recoveryCheck = request.recoveryCheck
        record.conversation = c
        try prepareRun(&record)
        try save(&record)
        return try await step(&record)
    }

    func result(conversationId: String, request: AskToolResultRequest, token: String) async throws -> AskConversation {
        guard token.isEmpty else { throw conflict() }
        var record = try record(conversationId)
        guard let run = record.conversation.run, run.id == request.runId, run.deviceId == request.deviceId else { throw conflict() }
        _ = try resolveTurn(record)
        if record.conversation.messages.contains(where: { $0.role == "tool" && $0.toolCallId == request.toolCallId }) { return record.conversation }
        guard run.status == "waiting_tool", run.pending.first?.id == request.toolCallId else { throw conflict() }
        if run.clientToolApproval == true, let call = run.pending.first, isBuiltin(call, record) {
            guard request.approveExecution != nil else { throw conflict() }
            if request.approveExecution == true && !request.isError {
                record.approvedCloudCallId = call.id
                return try await continueTools(&record)
            }
            record.conversation.messages.append(AskMessage(id: UUID().uuidString, role: "tool",
                text: "User denied this tool call. Do not repeat it.", toolCallId: call.id, isError: true, createdAt: now()))
            record.conversation.run?.pending.removeFirst()
            return try await continueTools(&record)
        }
        try settleBudgetTool(record, callId: request.toolCallId)
        record.conversation.messages.append(request.message(step: run.steps, now: now()))
        record.conversation.run?.pending.removeFirst()
        if ["unknown", "timeout", "cancelled"].contains(AskExecutionReceipt.tool(request).status) {
            record.conversation.run?.status = "running"
            record.conversation.run?.recovery = .init(state: "unknown_outcome", sequence: record.conversation.revision + 1)
            try save(&record)
            return record.conversation
        }
        return try await continueTools(&record)
    }

    func inferenceResult(conversationId: String, request: AskInferenceResult, token: String) async throws -> AskConversation {
        guard token.isEmpty else { throw conflict() }
        var record = try record(conversationId)
        guard let run = record.conversation.run else { throw conflict() }
        let currentReceipt = run.id == request.runId && run.deviceId == request.deviceId
            && run.status == "waiting_inference" && run.inference?.id == request.inferenceId
        if currentReceipt {
            _ = try resolveTurn(record)
        } else if record.localUsage?.contains(request) == true {
            try admitSettlement(record, request: request)
        } else {
            guard run.id == request.runId, run.deviceId == request.deviceId else { throw conflict() }
            _ = try resolveTurn(record)
        }
        if run.budgetEnabled == true {
            let root = record.localUsage?.budgetRoot(for: request)
            if record.localUsage?.contains(request) != true || root == run.budgetRootId {
                try settleInference(record, request)
                try refreshBudget(&record)
            } else if request.usage?.isValid == false {
                throw AskBudgetError.invalid
            }
        }
        guard run.id == request.runId, run.deviceId == request.deviceId,
              run.status == "waiting_inference", let inference = run.inference,
              inference.id == request.inferenceId else {
            return try lateInferenceUsage(&record, request: request, run: run)
        }
        record.startUsage(inference, at: run.updatedAt)
        record.settleUsage(request)
        record.lastInferenceId = request.inferenceId
        record.conversation.run?.inference = nil
        if allowsCloudModels, request.failed, request.errorCode == "CREDITS_EXHAUSTED" {
            record.conversation.run?.status = AskRun.pausedCreditsStatus
            record.conversation.run?.creditsPausedAt = now()
            try save(&record)
            return record.conversation
        }
        if (inference.summaryThrough ?? 0) > 0,
           request.failed || request.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !request.toolCalls.isEmpty || request.finishReason == "length" || request.content.utf8.count > 64000 {
            if record.summaryFallback != true { record.summaryFallback = true } else { record.summaryUnavailable = true }
            record.conversation.run?.status = "running"
            return try await step(&record)
        }
        if request.failed, request.errorCode == "MODEL_CONTEXT_TOO_LONG", request.content.isEmpty,
           request.reasoning?.isEmpty != false, request.toolCalls.isEmpty, (run.contextRetries ?? 0) < 2 {
            record.conversation.run?.contextRetries = (run.contextRetries ?? 0) + 1
            record.conversation.run?.contextInputTarget = 1
            record.summaryUnavailable = nil
            record.conversation.run?.status = "running"
            return try await step(&record)
        }
        if request.failed {
            record.conversation.run?.preview = request.content
            record.conversation.run?.reasoning = request.reasoning
            return try fail(&record, L("ask.local.modelFailed"))
        }
        record.conversation.run?.status = "running"
        if let cut = inference.summaryThrough, cut > 0 {
            guard !request.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, request.toolCalls.isEmpty else {
                return try fail(&record, L("ask.local.badSummary"))
            }
            record.conversation.summary = request.content
            record.conversation.summaryThrough = cut
            record.conversation.run?.contextInputTarget = nil
            return try await step(&record)
        }
        record.conversation.run?.contextRetries = nil
        record.conversation.run?.reasoning = request.reasoning
        record.conversation.run?.reasoningMilliseconds = request.reasoningMilliseconds
        return try await applyCompletion(&record, content: request.content, calls: request.toolCalls, finishReason: request.finishReason)
    }

    private func lateInferenceUsage(_ record: inout AskLocalRecord, request: AskInferenceResult, run: AskRun) throws -> AskConversation {
        // Only a previously recorded invocation may update usage after cancellation,
        // retry or completion. Its content must never be applied again.
        if record.localUsage?.contains(request) == true {
            if record.settleUsage(request) { try persist(record) }
            return record.conversation
        }
        if run.budgetEnabled == true { return record.conversation }
        if run.id == request.runId, run.deviceId == request.deviceId,
           record.lastInferenceId == request.inferenceId { return record.conversation }
        throw conflict()
    }

    func resume(conversationId: String, runId: String, token: String) async throws -> AskConversation {
        guard token.isEmpty else { throw conflict() }
        var value = try record(conversationId)
        guard value.conversation.run?.id == runId else { throw conflict() }
        _ = try resolveTurn(value)
        if allowsCloudModels, value.conversation.run?.isPausedForCredits == true {
            value.conversation.run?.status = "running"
            value.conversation.run?.creditsPausedAt = nil
            try save(&value)
            return try await step(&value, previous: .resume)
        }
        if value.conversation.run?.status == "waiting_tool", value.conversation.run?.pending.isEmpty == true {
            value.conversation.run?.status = "running"
            try save(&value)
            return try await step(&value, previous: .resume)
        }
        return value.conversation
    }

    func cancel(conversationId: String, runId: String, token: String) async throws -> AskConversation {
        try await cancel(conversationId: conversationId, runId: runId, partial: nil, token: token)
    }

    func cancel(conversationId: String, runId: String, partial: AskInferenceResult?, token: String) async throws -> AskConversation {
        guard token.isEmpty else { throw conflict() }
        var record = try record(conversationId)
        guard let run = record.conversation.run, run.id == runId else { throw conflict() }
        _ = try resolveTurn(record)
        summaries.removeValue(forKey: AskConversationID.canonical(conversationId))?.task.cancel()
        guard run.isActive else { return record.conversation }
        if let partial, partial.runId == run.id, run.status == "waiting_inference",
           let inference = run.inference, inference.id == partial.inferenceId, partial.deviceId == run.deviceId {
            try settleInference(record, partial)
            record.startUsage(inference, at: run.updatedAt)
            record.settleUsage(partial)
            record.conversation.run?.preview = partial.content
            record.conversation.run?.reasoning = partial.reasoning
        }
        keepPartial(&record)
        closePending(&record, reason: "Cancelled by the user. Do not repeat this action.", status: .cancelled)
        record.conversation.run?.status = "cancelled"
        try save(&record)
        return record.conversation
    }

    /// Queues a message for the active run; the model reads it at the next step boundary.
    func steer(conversationId: String, request: AskSteerRequest, token: String) async throws -> AskConversation {
        guard token.isEmpty else { throw conflict() }
        var record = try record(conversationId)
        if (try? resolveTurn(record)) == nil {
            guard record.conversation.run?.id == request.runId else { throw conflict() }
            _ = try resolveTurn(record)
        }
        if record.conversation.messages.contains(where: { $0.id == request.id }) { return record.conversation }
        guard let run = record.conversation.run, run.isActive, run.id == request.runId else { throw conflict() }
        let hasQuestion = !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (request.references ?? []).contains { !$0.question.trimmingCharacters(in: .whitespaces).isEmpty }
            || !(request.attachments ?? []).isEmpty
        guard hasQuestion else { throw AskLocalError.message(L("ask.local.emptyQuestion")) }
        var waiting = record.steering ?? []
        if waiting.contains(where: { $0.id == request.id }) { return record.conversation }
        guard waiting.count < Self.maxSteering else { throw AskLocalError.message(L("ask.queue.full", Self.maxSteering)) }
        waiting.append(AskMessage(id: request.id, role: "user", text: request.text, selection: request.selection, source: request.source,
                                  image: request.image, createdAt: now(), reasoningEffort: run.reasoningEffort,
                                  references: request.references, runId: run.id, steered: true, attachments: request.attachments,
                                  skills: request.skills, mcpServers: request.mcpServers))
        record.steering = waiting
        try save(&record)
        return record.conversation
    }

    func retry(conversationId: String, runId: String, deviceId: String, modelRef: String?, token: String) async throws -> AskConversation {
        try await retry(conversationId: conversationId, runId: runId, deviceId: deviceId, modelRef: modelRef, maxSteps: nil, token: token)
    }

    func retry(conversationId: String, runId: String, deviceId: String, modelRef: String?, maxSteps: Int?, token: String) async throws -> AskConversation {
        guard token.isEmpty else { throw conflict() }
        var record = try record(conversationId)
        guard let run = record.conversation.run, run.id == runId, run.deviceId == deviceId else { throw conflict() }
        _ = try resolveTurn(record)
        if run.isActive || run.status == "completed" { return record.conversation }
        let model = try executionModel(modelRef ?? run.modelRef)
        record.conversation.modelRef = model
        record.conversation.run = AskRun(id: UUID().uuidString.lowercased(), deviceId: deviceId, status: "running", steps: 0, updatedAt: now(),
                                         tools: run.tools, pending: [], modelRef: model,
                                         reasoningEffort: model == run.modelRef ? run.reasoningEffort : nil,
                                         budgetEnabled: run.budgetEnabled, budgetRootId: run.budgetRootId, budgetDeadline: run.budgetDeadline, budgetLimits: run.budgetLimits)
        record.conversation.run?.maxSteps = try Self.configuredMaxSteps(maxSteps ?? run.maxSteps)
        record.conversation.run?.clientToolApproval = true
        record.conversation.run?.recoveryCheck = run.recoveryCheck
        try prepareRun(&record)
        try save(&record)
        return try await step(&record)
    }

    func regenerate(conversationId: String, request: AskRegenerateRequest, token: String) async throws -> AskConversation {
        guard token.isEmpty else { throw conflict() }
        var record = try record(conversationId)
        var c = record.conversation
        _ = try resolveTurn(record)
        if c.run?.isActive == true { throw conflict() }
        guard let index = c.messages.firstIndex(where: { $0.id == request.messageId && $0.role == "assistant" }),
              !c.messages[(index + 1)...].contains(where: { $0.role == "user" }) else { throw AskLocalError.message(L("ask.local.regenerateLatest")) }
        var cut = index
        while cut > 0, c.messages[cut - 1].role != "user" { cut -= 1 }
        guard cut > 0 else { throw AskLocalError.message(L("ask.local.regenerateLatest")) }
        let prompt = c.messages[cut - 1]
        let model = try executionModel(request.modelRef ?? c.modelRef)
        c.messages = Array(c.messages.prefix(cut))
        if let through = c.summaryThrough, through > c.messages.count { c.summaryThrough = c.messages.count }
        c.modelRef = model
        c.run = AskRun(id: UUID().uuidString.lowercased(), deviceId: request.deviceId, status: "running", steps: 0, updatedAt: now(),
                       tools: request.tools ?? c.run?.tools ?? [], pending: [], modelRef: model, reasoningEffort: prompt.reasoningEffort)
        c.run?.maxSteps = try Self.configuredMaxSteps(request.maxSteps ?? record.conversation.run?.maxSteps)
        c.run?.clientToolApproval = request.clientToolApproval
        c.run?.recoveryCheck = record.conversation.run?.recoveryCheck
        record.conversation = c
        try prepareRun(&record)
        try save(&record)
        return try await step(&record)
    }

    // MARK: - Run

    static func configuredMaxSteps(_ requested: Int?) throws -> Int {
        guard let requested else { return maxSteps }
        guard (10 ... 500).contains(requested) else { throw AskLocalError.message(L("ask.steps.invalid")) }
        return requested
    }

    /// Only the user's own models run locally; Typeflux Cloud models need the Cloud service.
    /// The typed question, or the first attachment's name when only files were sent.
    static func title(_ request: AskSendRequest) -> String {
        let typed = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? request.attachments?.first?.name ?? typed : typed
    }

    static func localModel(_ reference: String?) throws -> String {
        guard let reference, !reference.isEmpty, !reference.hasPrefix("cloud:") else {
            throw AskLocalError.message(L("ask.local.modelRequired"))
        }
        return reference
    }

    private func executionModel(_ reference: String?) throws -> String {
        if allowsCloudModels, let reference, reference.hasPrefix("cloud:"), reference.count > 6 { return reference }
        return try Self.localModel(reference)
    }

    /// Only a terminal legacy conversation may seed device execution. A history
    /// replica never imports pending calls, grants, or an active server run.
    func importLegacy(_ conversation: AskConversation) throws {
        loadAll()
        guard Self.validID(conversation.id), conversation.run?.isActive != true,
              conversation.run?.needsRecoveryInspection != true else { throw conflict() }
        _ = try AskAgentBinding.resolve(conversation.run?.agentBinding)
        guard records[conversation.id] == nil else { return }
        var record = AskLocalRecord(conversation: conversation)
        record.conversation.memory = nil
        record.conversation.run?.inference = nil
        record.conversation.run?.pending = []
        record.conversation.run?.budgetEnabled = nil
        record.conversation.run?.budgetRootId = nil
        record.conversation.run?.budgetDeadline = nil
        record.conversation.run?.budgetLimits = nil
        record.conversation.run?.budget = nil
        try persist(record)
    }

    private func conflict() -> AskLocalError { .message(L("ask.local.conflict")) }

    private func prepareRun(_ record: inout AskLocalRecord) throws {
        guard turnOwnershipAvailable, turnPolicy.acceptsDirectory(directory) else { throw AskLocalError.implementationUnavailable }
        _ = try turnPolicy.resolve(turnPolicy.selected, operations: Set(AskAgentOperation.allCases))
        record.conversation.run?.agentBinding = turnPolicy.selected
        record.agentState = nil
        if turnPolicy.selected != .default { record.agentState = stateEnvelope(record, sequence: 0, payload: .null) }
        record.typedContentEnabled = typedContentEnabled
        record.contextLimits = contextLimits(record.conversation.run?.modelRef ?? "")
        if budgetEnabled || record.conversation.run?.budgetEnabled == true {
            record.conversation.run?.budgetEnabled = true
            if record.conversation.run?.budgetRootId == nil {
                let root = record.conversation.run?.id
                record.conversation.run?.budgetRootId = root
                record.conversation.run?.budgetDeadline = Date(timeIntervalSince1970: now().timeIntervalSince1970.rounded(.down) + 600)
                record.conversation.run?.budgetLimits = budgetLimits
                _ = try budgetJournal(record, createIfMissing: true) { _ in }
            }
            record.contextLimits = contextLimits(record.conversation.run?.modelRef ?? "")
        }
        // Messages left from an earlier run were taken back by the device.
        record.summaryUnavailable = nil
        record.summaryFallback = nil
        record.steering = nil
        record.builtinTools = builtinTools.definitions()
        let deviceNames = Set(record.conversation.run?.tools.map(\.name) ?? [])
        record.conversation.run?.cloudTools = record.builtinTools.filter { !deviceNames.contains($0.name) }
        record.approvedCloudCallId = nil
        record.cloudCalls = 0
        let zone = record.timeZone.flatMap(TimeZone.init(identifier:)) ?? TimeZone(identifier: "UTC")!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd (EEEE)"
        record.localDate = formatter.string(from: now())
    }

    private func summaryPrefix(_ c: AskConversation, cut: Int) -> String {
        let encoder = AskCoding.encoder()
        encoder.outputFormatting = .sortedKeys
        return AskToolPolicy.digest(String(decoding: (try? encoder.encode(Array(c.messages.prefix(cut)))) ?? Data(), as: UTF8.self))
    }

    private func backgroundSummary(_ record: inout AskLocalRecord) async throws -> Bool {
        guard let summarize, record.summaryUnavailable != true, let run = record.conversation.run else { return false }
        let id = record.conversation.id
        let window = record.contextLimits?.window ?? 32768
        let prompt = promptBuilder.conversation(promptInput(record.conversation, record))
        let hard = AskContextCompaction.weight(prompt) >= window * 80 / 100 || (run.contextInputTarget ?? 0) > 0
        if var preparation = summaries[id] {
            let valid = preparation.cut <= record.conversation.messages.count
                && preparation.through == (record.conversation.summaryThrough ?? 0)
                && preparation.prior == record.conversation.summary
                && preparation.prefix == summaryPrefix(record.conversation, cut: preparation.cut)
            if !valid {
                preparation.task.cancel(); summaries[id] = nil
            } else {
                if hard, preparation.result == nil {
                    try save(&record)
                    _ = await preparation.task.value
                    try Task.checkCancellation()
                    guard let latest = records[id], latest.conversation.run?.id == run.id,
                          latest.conversation.run?.status == record.conversation.run?.status else { throw conflict() }
                    _ = try resolveTurn(latest)
                    record = latest
                    preparation = summaries[id] ?? preparation
                }
                guard let result = preparation.result else { return true }
                summaries[id] = nil
                if !result.failed, !result.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   result.toolCalls.isEmpty, result.finishReason != "length", result.content.utf8.count <= 64000 {
                    record.conversation.summary = result.content
                    record.conversation.summaryThrough = preparation.cut
                    record.conversation.run?.contextInputTarget = nil
                } else if preparation.fallback { record.summaryUnavailable = true }
                else { record.summaryFallback = true }
                return false
            }
        }
        guard !hard, let cut = AskSemanticCompaction.boundary(record.conversation, payload: prompt, limits: record.contextLimits) else { return false }
        let reference = AskSemanticCompaction.model(record.conversation, fallback: record.summaryFallback == true)
        let limits = contextLimits(reference)
        var payload = promptBuilder.summary(.init(conversation: record.conversation, through: cut,
            model: reference, window: limits.window, output: max(1, min(4096, limits.maxOutput, (record.contextLimits?.window ?? 32768) * 5 / 100))))
        let end = payload.removeValue(forKey: "typeflux_summary_through") as? Int ?? cut
        payload["typeflux_context_window"] = limits.window
        payload["typeflux_semantic_context"] = true
        payload["typeflux_deadline"] = min(now().addingTimeInterval(90), run.budgetDeadline ?? .distantFuture).timeIntervalSince1970
        if run.budgetEnabled == true { payload["typeflux_budget"] = true }
        let inference = AskInference(id: UUID().uuidString.lowercased(), payload: AskLocalPrompt.json(payload), summaryThrough: end)
        if run.budgetEnabled == true {
            guard let plan = try? AskContextPlanner.plan(payload, limits: limits) else { return false }
            try reserveBudget(record, operationId: inference.id, callId: inference.id, kind: "model",
                              resources: .init(tokens: Int64(plan.inputTokens + plan.outputReserve), operations: 1))
        }
        record.startUsage(inference, at: now())
        try save(&record)
        let frozen = record
        let task = Task { [weak self] in
            let receipt = await summarize(inference, run.id, run.deviceId)
            await self?.finishSummary(frozen, receipt: receipt)
            return receipt
        }
        summaries[id] = Preparation(id: inference.id, through: record.conversation.summaryThrough ?? 0,
            cut: end, prior: record.conversation.summary, prefix: summaryPrefix(record.conversation, cut: end),
            fallback: record.summaryFallback == true, task: task)
        return true
    }

    private func finishSummary(_ frozen: AskLocalRecord, receipt: AskInferenceResult) {
        let id = frozen.conversation.id
        // Budget settlement remains bound to the original root, even after cancellation.
        guard var latest = records[id], (try? admitSettlement(latest, request: receipt)) != nil else { return }
        try? settleInference(frozen, receipt)
        _ = latest.settleUsage(receipt)
        if let prepared = summaries[id], prepared.id == receipt.inferenceId,
           (try? resolveTurn(latest)) != nil, latest.conversation.run?.id == receipt.runId,
           latest.conversation.run?.status == "completed", !receipt.failed,
           !receipt.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           receipt.toolCalls.isEmpty, receipt.finishReason != "length", receipt.content.utf8.count <= 64000,
           (latest.conversation.summaryThrough ?? 0) == prepared.through,
           latest.conversation.summary == prepared.prior,
           prepared.cut <= latest.conversation.messages.count,
           summaryPrefix(latest.conversation, cut: prepared.cut) == prepared.prefix {
            latest.conversation.summary = receipt.content
            latest.conversation.summaryThrough = prepared.cut
            latest.conversation.revision += 1
            summaries[id] = nil
        }
        try? persist(latest)
        guard summaries[id]?.id == receipt.inferenceId else { return }
        summaries[id]?.result = receipt
    }

    private func promptInput(_ conversation: AskConversation, _ record: AskLocalRecord) -> AskConversationPromptInput {
        .init(conversation: conversation, tools: allTools(record), localDate: record.localDate ?? "",
              timeZone: record.timeZone, locale: record.locale, typedContentEnabled: record.typedContentEnabled == true)
    }

    private func allTools(_ record: AskLocalRecord) -> [AskToolDefinition] {
        let device = record.conversation.run?.tools ?? []
        let deviceNames = Set(device.map(\.name))
        return device + record.builtinTools.filter { !deviceNames.contains($0.name) }
    }

    private func isBuiltin(_ call: AskToolCall, _ record: AskLocalRecord) -> Bool {
        record.builtinTools.contains { $0.name == call.function.name }
            && !(record.conversation.run?.tools ?? []).contains { $0.name == call.function.name }
    }

    /// Queues the next on-device inference: a summary when the history is long, otherwise the answer.
    private func step(_ record: inout AskLocalRecord, previous: AskAgentTurnOutcome? = nil) async throws -> AskConversation {
        _ = try resolveTurn(record)
        let skipSummary = try await backgroundSummary(&record)
        record.conversation.memory = record.conversation.memory?.usable(at: now())
        if record.conversation.run?.status == "running" { deliverSteering(&record) }
        guard let run = record.conversation.run else { return record.conversation }
        guard run.steps < (run.maxSteps ?? Self.maxSteps) + (run.extraSteps ?? 0) else { return try fail(&record, L("ask.local.stepLimit")) }
        if record.conversation.summary != nil, !record.builtinTools.contains(where: { $0.name == AskSemanticCompaction.historyTool.name }) {
            record.builtinTools.append(AskSemanticCompaction.historyTool)
            let deviceNames = Set(record.conversation.run?.tools.map(\.name) ?? [])
            record.conversation.run?.cloudTools = record.builtinTools.filter { !deviceNames.contains($0.name) }
        }
        let c = record.conversation
        if !skipSummary, record.summaryUnavailable != true,
           let cut = AskSemanticCompaction.boundary(c, payload: promptBuilder.conversation(promptInput(c, record)), limits: record.contextLimits) {
            let model = AskSemanticCompaction.model(c, fallback: record.summaryFallback == true)
            let limits = contextLimits(model)
            let payload = promptBuilder.summary(.init(conversation: c, through: cut, model: model,
                                                        window: limits.window, output: max(1, min(4096, limits.maxOutput, (record.contextLimits?.window ?? 32768) * 5 / 100))))
            let end = payload["typeflux_summary_through"] as? Int ?? cut
            return try queue(&record, payload: payload, summaryThrough: end)
        }
        record.conversation.run?.assistantId = UUID().uuidString.lowercased()
        record.conversation.run?.preview = nil
        record.conversation.run?.reasoning = nil
        record.conversation.run?.reasoningMilliseconds = nil
        var promptConversation = record.conversation
        if promptConversation.messages.suffix(12).contains(where: { !$0.retainedResultImages.isEmpty && $0.harness?.outcome?.content != nil }) {
            // Persist the completed tool receipt before awaiting read-only image work.
            record.conversation.run?.status = "running"
            try save(&record)
            let revision = record.conversation.revision
            promptConversation = record.conversation
            promptConversation.messages = await prepareImages(promptConversation.messages)
            try Task.checkCancellation()
            // Cancellation, deletion, steering and privacy changes may have advanced the record.
            guard let latest = records[record.conversation.id], latest.conversation.revision == revision else { throw conflict() }
            _ = try resolveTurn(latest)
        }
        let payload = promptBuilder.conversation(promptInput(promptConversation, record))
        let decision = try await decideTurn(&record, payload: payload, previous: previous)
        switch decision {
        case let .requestModel(prompt, purpose, _):
            return try queue(&record, payload: modelPayload(prompt, purpose: purpose, prepared: payload), summaryThrough: nil)
        default:
            return try await applyDecision(&record, decision: decision, originalCalls: [])
        }
    }

    private func queue(_ record: inout AskLocalRecord, payload: [String: Any], summaryThrough: Int?) throws -> AskConversation {
        _ = try resolveTurn(record)
        let id = UUID().uuidString.lowercased()
        var payload = payload
        payload.removeValue(forKey: "typeflux_summary_through")
        let limits = summaryThrough != nil ? contextLimits(payload["model"] as? String ?? "") : (record.contextLimits ?? .init())
        var bounded = summaryThrough != nil ? payload : AskContextCompaction.compact(payload, window: limits.window)
        if record.conversation.run?.budgetEnabled == true {
            do {
                let plan = try AskContextPlanner.plan(payload, limits: limits)
                bounded = plan.payload
                try reserveBudget(record, operationId: id, callId: id, kind: "model",
                                  resources: .init(tokens: Int64(plan.inputTokens + plan.outputReserve), operations: 1))
                bounded["typeflux_budget"] = true
                bounded["typeflux_deadline"] = record.conversation.run?.budgetDeadline?.timeIntervalSince1970
                record.conversation.contextUsage = .init(modelRef: record.conversation.run?.modelRef ?? "", inputTokens: plan.inputTokens,
                    outputReserve: plan.outputReserve, capacity: plan.capacity, summarized: record.conversation.summary != nil, estimated: true, trimmed: plan.trimmed)
            } catch { return try stopBudget(&record, error: error) }
        }
        if record.conversation.run?.budgetEnabled != true {
            record.conversation.contextUsage = .init(modelRef: record.conversation.run?.modelRef ?? "",
                inputTokens: AskContextCompaction.weight(bounded), outputReserve: bounded["max_tokens"] as? Int ?? 0,
                capacity: limits.known ? limits.window : nil, summarized: record.conversation.summary != nil || AskContextCompaction.weight(bounded) < AskContextCompaction.weight(payload),
                estimated: true, trimmed: AskContextCompaction.weight(bounded) < AskContextCompaction.weight(payload))
        }
        bounded["typeflux_context_window"] = limits.window
        bounded["typeflux_semantic_context"] = true
        record.conversation.run?.status = "waiting_inference"
        record.conversation.run?.inference = AskInference(id: id, payload: AskLocalPrompt.json(bounded), summaryThrough: summaryThrough)
        if let inference = record.conversation.run?.inference { record.startUsage(inference, at: now()) }
        try save(&record)
        return record.conversation
    }

    private func applyCompletion(_ record: inout AskLocalRecord, content: String, calls: [AskToolCall], finishReason: String?) async throws -> AskConversation {
        _ = try resolveTurn(record)
        if finishReason == "length" {
            record.conversation.run?.preview = content
            return try fail(&record, L("ask.local.truncated"))
        }
        if calls.isEmpty, content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return try fail(&record, L("ask.local.empty")) }
        guard calls.count <= Self.maxToolCalls else { return try fail(&record, L("ask.local.invalidTools")) }
        let known = Set(allTools(record).map(\.name))
        var seen = Set(record.conversation.messages.flatMap { $0.toolCalls ?? [] }.map(\.id))
        for call in calls {
            guard !call.id.isEmpty, seen.insert(call.id).inserted, known.contains(call.function.name),
                  (try? JSONSerialization.jsonObject(with: Data(call.function.arguments.utf8))) is [String: Any] else {
                return try fail(&record, L("ask.local.invalidTools"))
            }
        }
        let outcome = AskAgentTurnOutcome.model(content: content, tools: calls.map { .init(name: $0.function.name, arguments: $0.function.arguments, callID: $0.id) }, finishReason: finishReason)
        let decision = try await decideTurn(&record, payload: nil, previous: outcome)
        switch decision {
        case .requestModel, .suspend: record.conversation.run?.steps += 1
        default: break
        }
        return try await applyDecision(&record, decision: decision, originalCalls: calls)
    }

    private func applyDecisionCompletion(_ record: inout AskLocalRecord, content: String, calls: [AskToolCall]) async throws -> AskConversation {
        guard let run = record.conversation.run else { return record.conversation }
        record.conversation.messages.append(AskMessage(id: run.assistantId ?? UUID().uuidString.lowercased(), role: "assistant", text: content,
                                                       toolCalls: calls.isEmpty ? nil : calls, createdAt: now(),
                                                       reasoning: run.reasoning, reasoningMilliseconds: run.reasoningMilliseconds, runId: run.id))
        record.conversation.run?.preview = nil
        record.conversation.run?.reasoning = nil
        record.conversation.run?.assistantId = nil
        record.conversation.run?.steps += 1
        record.conversation.run?.pending = calls
        if calls.isEmpty, deliverSteering(&record) {
            // Messages sent while the model was answering get a reply in the same run.
            record.conversation.run?.status = "running"
            // Commit the accepted completion and steering before the next adapter decision.
            try save(&record)
            return try await step(&record)
        }
        if calls.isEmpty {
            record.conversation.run?.status = "completed"
            try save(&record)
            return record.conversation
        }
        return try await continueTools(&record)
    }

    /// Runs leading built-in calls here, then hands device calls to the device or starts the next step.
    /// The host admits a contiguous prefix; unclassified tools and approval
    /// boundaries are never crossed to find additional work.
    private func builtinWave(_ record: AskLocalRecord) -> [AskToolCall] {
        var wave: [AskToolCall] = []
        for call in record.conversation.run?.pending ?? [] {
            guard wave.count < 3, isBuiltin(call, record) else { break }
            let approval = record.conversation.run?.clientToolApproval == true
            if approval && record.approvedCloudCallId != call.id { break }
            let definition = record.builtinTools.first { $0.name == call.function.name }
            let independent = definition.map { builtinTools.executionClassification(for: $0) == .independentWebRead } == true
                && ["web_search", "web_fetch"].contains(call.function.name)
            if !wave.isEmpty && (!independent || approval) { break }
            wave.append(call)
            if !independent || approval { break }
        }
        return wave
    }

    private func continueTools(_ record: inout AskLocalRecord) async throws -> AskConversation {
        _ = try resolveTurn(record)
        while let first = record.conversation.run?.pending.first, isBuiltin(first, record) {
            try Task.checkCancellation()
            let calls = builtinWave(record)
            if calls.isEmpty {
                record.conversation.run?.status = "waiting_tool"
                try save(&record)
                return record.conversation
            }
            record.approvedCloudCallId = nil
            record.conversation.run?.status = "running"
            var admitted: [AskToolCall] = []
            // Admission and compensation happen before the first child exists.
            do {
                for (index, call) in calls.enumerated() where builtinAllowed(call, count: record.cloudCalls + index) {
                    _ = try resolveTurn(record)
                    admitted.append(call)
                    try reserveBudgetTool(record, call: call)
                }
                try save(&record)
                _ = try resolveTurn(record)
                try Task.checkCancellation()
            } catch {
                let admissionError = error
                var accountingError: Error?
                for call in admitted {
                    do { try compensateUnlaunchedBudgetTool(record, callId: call.id) } catch { accountingError = accountingError ?? error }
                }
                if let accountingError { throw accountingError }
                if admissionError is CancellationError { throw admissionError }
                if admissionError is AskBudgetError { return try stopBudget(&record, error: admissionError) }
                throw admissionError
            }
            let original = record
            let host = builtinTools
            let inputs = calls.map { AskBuiltinToolInput(call: $0, conversation: original.conversation,
                                                        budgeted: original.conversation.run?.budgetEnabled == true) }
            let allowed = calls.enumerated().map { builtinAllowed($0.element, count: original.cloudCalls + $0.offset) }
            let flightID = UUID()
            // The coordinator is owned and awaited here. All effects run in
            // structured children; cancellation reaches every request, and the
            // coordinator cannot complete until their cleanup has returned.
            let task = Task {
                await withTaskGroup(of: (Int, AskBuiltinToolOutput).self) { group in
                    for (index, input) in inputs.enumerated() {
                        group.addTask {
                            guard allowed[index] else { return (index, AskBuiltinToolOutput(
                                text: "Web tool limit for this request reached. Answer with the information gathered so far.", isError: true)) }
                            guard !Task.isCancelled else { return (index, AskBuiltinToolOutput(text: "Tool execution cancelled.", isError: true)) }
                            return (index, await host.execute(input))
                        }
                    }
                    var indexed: [Int: AskBuiltinToolOutput] = [:]
                    for await (index, output) in group { indexed[index] = output }
                    return inputs.indices.map { indexed[$0]! }
                }
            }
            builtinFlights[record.conversation.id] = .init(id: flightID, runID: record.conversation.run?.id ?? "", task: task)
            let outputs = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
            if builtinFlights[original.conversation.id]?.id == flightID { builtinFlights[original.conversation.id] = nil }
            // Original-root settlement is independent of replacement/deletion,
            // cancellation, binding validation and content persistence.
            var accountingError: Error?
            for call in admitted {
                do { try settleBudgetTool(original, callId: call.id) } catch { accountingError = accountingError ?? error }
            }
            guard var latest = records[original.conversation.id] else {
                if let accountingError { throw accountingError }
                throw AskLocalError.message(L("ask.local.notFound"))
            }
            _ = try resolveTurn(latest)
            try refreshBudget(&latest)
            guard latest.conversation.run?.id == original.conversation.run?.id,
                  latest.conversation.run?.deviceId == original.conversation.run?.deviceId,
                  latest.conversation.run?.agentBinding == original.conversation.run?.agentBinding,
                  latest.conversation.run?.status == "running",
                  Array((latest.conversation.run?.pending ?? []).prefix(calls.count)) == calls else {
                if let accountingError { throw accountingError }
                return latest.conversation
            }
            record = latest
            for (call, result) in zip(calls, outputs) {
                if let plan = result.plan { record.conversation.run?.plan = plan }
                record.conversation.messages.append(AskMessage(id: UUID().uuidString, role: "tool", text: result.text,
                    toolCallId: call.id, isError: result.isError, createdAt: now(), runId: record.conversation.run?.id))
                if !["update_plan", "read_conversation_history"].contains(call.function.name) { record.cloudCalls += 1 }
            }
            record.conversation.run?.pending.removeFirst(calls.count)
            // Keep completion in memory if disk persistence fails, preventing
            // a duplicate receipt from invoking a completed wave again.
            records[record.conversation.id] = record
            do { try save(&record) } catch {
                record.conversation.run?.recovery = .init(state: "unknown_outcome", sequence: record.conversation.revision)
                records[record.conversation.id] = record
                throw error
            }
            if let accountingError { throw accountingError }
            try Task.checkCancellation()
        }
        if let call = record.conversation.run?.pending.first {
            do { try reserveBudgetTool(record, call: call) } catch { return try stopBudget(&record, error: error) }
            record.conversation.run?.status = "waiting_tool"
            try save(&record)
            return record.conversation
        }
        record.conversation.run?.status = "running"
        return try await step(&record)
    }

    private func builtinAllowed(_ call: AskToolCall, count: Int) -> Bool {
        ["update_plan", "read_conversation_history"].contains(call.function.name) || count < Self.maxBuiltinCalls
    }

    /// Appends the messages waiting for this run. Only at a step boundary, so a user
    /// message never lands between a tool call and its result.
    @discardableResult
    private func deliverSteering(_ record: inout AskLocalRecord) -> Bool {
        guard let run = record.conversation.run, run.pending.isEmpty, let waiting = record.steering, !waiting.isEmpty else { return false }
        for var message in waiting where !record.conversation.messages.contains(where: { $0.id == message.id }) {
            message.createdAt = now()
            message.runId = run.id
            record.conversation.messages.append(message)
        }
        record.steering = nil
        record.conversation.run?.extraSteps = min((run.extraSteps ?? 0) + Self.steeringStepBonus * waiting.count, Self.maxExtraSteps)
        return true
    }

    func fail(_ record: inout AskLocalRecord, _ reason: String) throws -> AskConversation {
        _ = try resolveTurn(record)
        keepPartial(&record)
        closePending(&record, reason: reason)
        record.conversation.run?.status = "failed"
        record.conversation.run?.error = reason
        record.conversation.run?.previewTools = nil
        try save(&record)
        return record.conversation
    }

    /// Visible partial output stays in the history as an interrupted reply.
    private func keepPartial(_ record: inout AskLocalRecord) {
        guard let run = record.conversation.run else { return }
        let text = run.preview ?? "", reasoning = run.reasoning ?? ""
        if !text.isEmpty || !reasoning.isEmpty {
            let id = run.assistantId ?? UUID().uuidString.lowercased()
            if !record.conversation.messages.contains(where: { $0.id == id }) {
                record.conversation.messages.append(AskMessage(id: id, role: "assistant", text: text, isError: true, createdAt: now(),
                                                               reasoning: reasoning.isEmpty ? nil : reasoning, runId: run.id))
            }
        }
        record.conversation.run?.assistantId = nil
        record.conversation.run?.preview = nil
        record.conversation.run?.reasoning = nil
        record.conversation.run?.previewTools = nil
    }

    private func closePending(_ record: inout AskLocalRecord, reason: String, status: AskExecutionStatus = .unknown) {
        record.closeUsage()
        for call in record.conversation.run?.pending ?? [] {
            let request = AskToolResultRequest(runId: record.conversation.run?.id ?? "",
                                               deviceId: record.conversation.run?.deviceId ?? "", toolCallId: call.id,
                                               content: reason, isError: true,
                                               harness: .init(version: 1, outcome: .init(status: status.rawValue)))
            record.conversation.messages.append(request.message(step: record.conversation.run?.steps ?? 0, now: now()))
        }
        record.conversation.run?.pending = []
        record.conversation.run?.inference = nil
    }

    private func admitSettlement(_ record: AskLocalRecord, request: AskInferenceResult) throws {
        guard record.localUsage?.contains(request) == true else { throw conflict() }
        switch AskRunRouteArchive.lookup(archive: record.agentRoutes, current: record.conversation.run, runID: request.runId) {
        case let .found(route, _):
            guard route.deviceID == request.deviceId, AskAgentBinding(raw: route.binding).isWellFormed else { throw conflict() }
        case .unrecorded:
            // Trusted pre-C5 invocation evidence is the only legacy settlement fallback.
            break
        case .unavailable: throw AskLocalError.implementationUnavailable
        }
    }

    private func sanitizedPrompt(_ value: AskRouteJSON) -> AskRouteJSON {
        switch value {
        case let .object(fields): return .object(fields.filter { !["provider_context", "thought_signature"].contains($0.key) }.mapValues(sanitizedPrompt))
        case let .array(items): return .array(items.map(sanitizedPrompt))
        default: return value
        }
    }

    private func modelPayload(_ prompt: AskRouteJSON, purpose: String, prepared: [String: Any]) throws -> [String: Any] {
        guard ["main", "summary"].contains(purpose), try prompt.encodeRaw().count <= 20 * 1024 * 1024 else { throw AskLocalError.implementationUnavailable }
        let original = try AskRouteJSON.decodeRaw(JSONSerialization.data(withJSONObject: prepared))
        if prompt == sanitizedPrompt(original) {
            guard purpose == "summary" else { return prepared }
            var payload = prepared
            payload.removeValue(forKey: "tools"); payload.removeValue(forKey: "tool_choice")
            return payload
        }
        guard case let .object(fields) = prompt, fields.count == 1, case let .array(messages) = fields["messages"],
              !messages.isEmpty, messages.count <= 500 else { throw AskLocalError.implementationUnavailable }
        for message in messages {
            guard case let .object(fields) = message, case let .string(role) = fields["role"],
                  ["system", "user", "assistant", "tool"].contains(role),
                  Set(fields.keys).isSubset(of: ["role", "content", "name", "tool_calls", "tool_call_id"]),
                  sanitizedPrompt(message) == message else { throw AskLocalError.implementationUnavailable }
        }
        var payload = prepared
        payload["messages"] = try JSONSerialization.jsonObject(with: AskRouteJSON.array(messages).encodeRaw())
        if purpose == "summary" { payload.removeValue(forKey: "tools"); payload.removeValue(forKey: "tool_choice") }
        return payload
    }

    private func stateEnvelope(_ record: AskLocalRecord, sequence: Int, payload: AskRouteJSON) -> AskRouteJSON {
        .object(["version": .number(.init("1")), "run_id": .string(record.conversation.run?.id ?? ""),
                 "binding": (record.conversation.run?.agentBinding ?? .default).routeEvidence,
                 "turn_sequence": .number(.init(String(sequence))), "payload": payload])
    }

    private func turnState(_ record: AskLocalRecord) throws -> (Int, AskRouteJSON?) {
        guard let run = record.conversation.run else { return (0, nil) }
        guard let raw = record.agentState else {
            guard run.agentBinding == nil || run.agentBinding == .default else { throw AskLocalError.implementationUnavailable }
            return (0, nil)
        }
        guard case let .object(fields) = raw, fields["version"] == .number(.init("1")),
              fields["run_id"] == .string(run.id), fields["binding"] == (run.agentBinding ?? .default).routeEvidence,
              case let .number(number) = fields["turn_sequence"], let sequence = number.integer,
              sequence >= 0, let payload = fields["payload"] else { throw AskLocalError.implementationUnavailable }
        return (sequence, payload)
    }

    @discardableResult
    private func resolveTurn(_ record: AskLocalRecord) throws -> AskAgentBinding {
        guard turnOwnershipAvailable, turnPolicy.acceptsDirectory(directory) else { throw AskLocalError.implementationUnavailable }
        guard record.conversation.run != nil else { return .default }
        let binding = record.conversation.run?.agentBinding ?? .default
        _ = try turnPolicy.resolve(binding, operations: Set(AskAgentOperation.allCases))
        _ = try turnState(record)
        if let run = record.conversation.run {
            let lookup = AskRunRouteArchive.lookup(archive: records[record.conversation.id]?.agentRoutes ?? record.agentRoutes, current: run, runID: run.id)
            guard case let .found(route, _) = lookup, route.deviceID == run.deviceId, route.binding == binding.routeEvidence else { throw AskLocalError.implementationUnavailable }
        }
        return binding
    }

    private struct AgentTurnScope {
        let runID: String
        let deviceID: String
        let revision: Int64
        let binding: AskAgentBinding
        let sequence: Int
    }

    private func decideTurn(_ record: inout AskLocalRecord, payload: [String: Any]?, previous: AskAgentTurnOutcome?) async throws -> AskAgentDecision {
        let binding = try resolveTurn(record)
        guard let run = record.conversation.run else { throw conflict() }
        let (sequence, state) = try turnState(record)
        let scope = AgentTurnScope(runID: run.id, deviceID: run.deviceId, revision: record.conversation.revision, binding: binding, sequence: sequence)
        let adapter = try turnPolicy.resolve(binding, operations: Set(AskAgentOperation.allCases))
        let hostPayload = payload ?? promptBuilder.conversation(promptInput(record.conversation, record))
        let prepared = try sanitizedPrompt(AskRouteJSON.decodeRaw(JSONSerialization.data(withJSONObject: hostPayload)))
        let messages = record.conversation.messages.map { AskAgentTurnMessage(role: $0.role, content: $0.text, callID: $0.toolCallId) }
        let outcome = previous ?? (messages.last?.role == "tool" ? .tools(Array(messages.reversed().prefix { $0.role == "tool" }.reversed())) : nil)
        let decision: AskAgentDecision
        do {
            decision = try await adapter.next(.init(runID: run.id, binding: binding, turnSequence: sequence, messages: messages,
                preparedPrompt: prepared, modelReference: run.modelRef ?? "", previous: outcome, state: state))
        } catch {
            try Task.checkCancellation()
            throw AskLocalError.implementationUnavailable
        }
        try Task.checkCancellation()
        guard let latest = records[record.conversation.id], latest.conversation.revision == scope.revision,
              latest.agentState == record.agentState,
              latest.conversation.run?.id == scope.runID, latest.conversation.run?.deviceId == scope.deviceID,
              latest.conversation.run?.status != "cancelled", latest.conversation.run?.status != "failed",
              try resolveTurn(latest) == scope.binding else { throw conflict() }
        if case let .requestModel(prompt, purpose, _) = decision {
            _ = try modelPayload(prompt, purpose: purpose, prepared: hostPayload)
        }
        guard (try decision.state?.encodeRaw().count ?? 0) <= 65536, sequence < Int.max else { throw AskLocalError.implementationUnavailable }
        record.agentState = stateEnvelope(record, sequence: scope.sequence + 1, payload: decision.state ?? .null)
        return decision
    }

    private func applyDecision(_ record: inout AskLocalRecord, decision: AskAgentDecision, originalCalls: [AskToolCall]) async throws -> AskConversation {
        let content: String
        let calls: [AskToolCall]
        switch decision {
        case let .finish(answer, reasoning, _):
            content = answer; calls = []
            if let reasoning { record.conversation.run?.reasoning = reasoning }
        case let .proposeTools(intents, text, _):
            content = text
            calls = intents.map { intent in
                originalCalls.first { $0.id == intent.callID && $0.function.name == intent.name && $0.function.arguments == intent.arguments }
                    ?? AskToolCall(id: intent.callID, type: "function", function: .init(name: intent.name, arguments: intent.arguments))
            }
        case .suspend:
            record.conversation.run?.status = "waiting_tool"
            try save(&record)
            return record.conversation
        case let .requestModel(prompt, purpose, _):
            guard let run = record.conversation.run, run.steps < (run.maxSteps ?? Self.maxSteps) + (run.extraSteps ?? 0) else { return try fail(&record, L("ask.local.stepLimit")) }
            let prepared = promptBuilder.conversation(promptInput(record.conversation, record))
            return try queue(&record, payload: modelPayload(prompt, purpose: purpose, prepared: prepared), summaryThrough: nil)
        }
        guard content.utf8.count <= 256000, calls.count <= Self.maxToolCalls,
              !calls.isEmpty || !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AskLocalError.implementationUnavailable }
        let known = Set(allTools(record).map(\.name))
        var seen = Set(record.conversation.messages.flatMap { $0.toolCalls ?? [] }.map(\.id))
        for call in calls {
            guard !call.id.isEmpty, call.id.count <= 200, seen.insert(call.id).inserted, known.contains(call.function.name),
                  call.function.arguments.utf8.count <= 64000,
                  (try? JSONSerialization.jsonObject(with: Data(call.function.arguments.utf8))) is [String: Any] else { throw AskLocalError.implementationUnavailable }
        }
        return try await applyDecisionCompletion(&record, content: content, calls: calls)
    }

    // MARK: - Plan

    static let planTool = AskBuiltinPlan.definition

    static func parsePlan(_ arguments: String) throws -> [AskPlanItem] {
        try AskBuiltinPlan.parse(arguments)
    }
}

extension AskLocalRecord {
    private enum CodingKeys: String, CodingKey {
        case agentRoutes, agentState, summaryFallback, summaryUnavailable, contextLimits, typedContentEnabled, conversation
        case timeZone, locale, localDate, builtinTools, lastInferenceId, localUsage, cloudCalls, approvedCloudCallId, steering
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        agentState = try values.decodeIfPresent(AskRouteJSON.self, forKey: .agentState)
        agentRoutes = values.contains(.agentRoutes) ? try values.decode(AskRunRouteArchive.self, forKey: .agentRoutes) : nil
        summaryFallback = try values.decodeIfPresent(Bool.self, forKey: .summaryFallback)
        summaryUnavailable = try values.decodeIfPresent(Bool.self, forKey: .summaryUnavailable)
        contextLimits = try values.decodeIfPresent(AskContextLimits.self, forKey: .contextLimits)
        typedContentEnabled = try values.decodeIfPresent(Bool.self, forKey: .typedContentEnabled)
        conversation = try values.decode(AskConversation.self, forKey: .conversation)
        timeZone = try values.decodeIfPresent(String.self, forKey: .timeZone)
        locale = try values.decodeIfPresent(String.self, forKey: .locale)
        localDate = try values.decodeIfPresent(String.self, forKey: .localDate)
        builtinTools = try values.decode([AskToolDefinition].self, forKey: .builtinTools)
        lastInferenceId = try values.decodeIfPresent(String.self, forKey: .lastInferenceId)
        localUsage = try values.decodeIfPresent(AskLocalUsage.self, forKey: .localUsage)
        cloudCalls = try values.decode(Int.self, forKey: .cloudCalls)
        approvedCloudCallId = try values.decodeIfPresent(String.self, forKey: .approvedCloudCallId)
        steering = try values.decodeIfPresent([AskMessage].self, forKey: .steering)
    }
}
