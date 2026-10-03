// swiftlint:disable file_length
import Foundation

/// Engine-only state stored next to a local conversation.
struct AskLocalRecord: Codable, Equatable, Sendable {
    var typedContentEnabled: Bool?
    var conversation: AskConversation
    var timeZone: String?
    var locale: String?
    /// The user's calendar date when the run started; pinning it keeps the prompt prefix stable.
    var localDate: String?
    /// Built-in tools of the current run, executed by the engine instead of the device.
    var builtinTools: [AskToolDefinition] = []
    var lastInferenceId: String?
    var cloudCalls = 0
    /// Messages sent into the running run that the model has not read yet.
    var steering: [AskMessage]?
}

/// Runs Ask conversations entirely on this Mac with the user's own models, for
/// people who are not signed in or keep Ask local. It implements the same API as
/// the Cloud service and mirrors its state machine: every model step becomes an
/// on-device inference (`waiting_inference`) that the conversation model already
/// knows how to run, device tools use the usual approval flow, and conversations
/// are stored as JSON files under Application Support.
actor AskLocalEngine: AskAPI {
    static let maxSteps = 24
    static let maxMessages = 500
    static let maxToolCalls = 8
    static let maxBuiltinCalls = 16
    static let maxSteering = 5
    static let steeringStepBonus = 4
    static let maxExtraSteps = 12
    static let summarizeAfter = 28
    static let keepRecent = 12
    static let staleAfter: TimeInterval = 10 * 60

    let directory: URL
    private let typedContentEnabled: Bool
    private let webTools: AskLocalWebTools
    private let now: @Sendable () -> Date
    private var records: [String: AskLocalRecord] = [:]
    private var loaded = false

    init(directory: URL = AskLocalEngine.defaultDirectory, webTools: AskLocalWebTools = AskLocalWebTools(),
         now: @escaping @Sendable () -> Date = Date.init, typedContentEnabled: Bool = false) {
        self.typedContentEnabled = typedContentEnabled
        self.directory = directory
        self.webTools = webTools
        self.now = now
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Typeflux/AskLocal", isDirectory: true)
    }

    // MARK: - Storage

    private func loadAll() {
        guard !loaded else { return }
        loaded = true
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = AskCoding.decoder()
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file), let record = try? decoder.decode(AskLocalRecord.self, from: data) {
                records[record.conversation.id] = record
            }
        }
    }

    private func file(_ id: String) -> URL { directory.appendingPathComponent(id + ".json") }

    /// Conversation IDs become file names, so only plain identifiers are accepted.
    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "_" }
    }

    private func save(_ record: inout AskLocalRecord) throws {
        record.conversation.revision += 1
        record.conversation.updatedAt = now()
        record.conversation.run?.updatedAt = now()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try AskCoding.encoder().encode(record).write(to: file(record.conversation.id), options: [.atomic, .completeFileProtection])
        records[record.conversation.id] = record
    }

    private func record(_ id: String) throws -> AskLocalRecord {
        loadAll()
        let id = AskConversationID.canonical(id)
        guard Self.validID(id), var record = records[id] else { throw AskLocalError.message(L("ask.local.notFound")) }
        record.conversation.memory = record.conversation.memory?.usable(at: now())
        if record.conversation.memory == nil, let payload = record.conversation.run?.inference?.payload {
            record.conversation.run?.inference?.payload = AskMemory.removingInjection(from: payload)
        }
        // An interrupted inference or engine step must not strand the conversation.
        if let run = record.conversation.run, run.isActive, run.status != "waiting_tool",
           now().timeIntervalSince(run.updatedAt) > Self.staleAfter {
            keepPartial(&record)
            closePending(&record, reason: "The previous execution expired. It was not replayed.")
            record.conversation.run?.status = "failed"
            record.conversation.run?.error = L("ask.local.expired")
            try save(&record)
        }
        return record
    }

    // MARK: - AskAPI

    func list(token _: String, offset: Int) async throws -> [AskConversationSummary] {
        loadAll()
        return records.values.map(\.conversation).sorted { $0.updatedAt > $1.updatedAt }
            .dropFirst(max(0, offset)).prefix(50)
            .map { AskConversationSummary(id: $0.id, title: $0.title, updatedAt: $0.updatedAt) }
    }

    func conversation(id: String, token _: String) async throws -> AskConversation {
        try record(id).conversation
    }

    func models(token _: String) async throws -> [AskCloudModel] { [] }
    func models(token _: String, scenario _: String) async throws -> [AskCloudModel] { [] }

    func delete(conversationId: String, token _: String) async throws {
        loadAll()
        let id = AskConversationID.canonical(conversationId)
        guard Self.validID(id) else { return }
        records[id] = nil
        try? FileManager.default.removeItem(at: file(id))
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

    func send(conversationId: String, request: AskSendRequest, token _: String) async throws -> AskConversation {
        loadAll()
        let id = AskConversationID.canonical(conversationId)
        guard Self.validID(id) else { throw AskLocalError.message(L("ask.local.notFound")) }
        let hasQuestion = !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (request.references ?? []).contains { !$0.question.trimmingCharacters(in: .whitespaces).isEmpty }
            || !(request.attachments ?? []).isEmpty
        guard hasQuestion else { throw AskLocalError.message(L("ask.local.emptyQuestion")) }
        var record = records[id] ?? AskLocalRecord(conversation: AskConversation(
            id: id, title: String(Self.title(request).prefix(50)),
            revision: 0, updatedAt: now(), messages: []))
        if record.conversation.messages.contains(where: { $0.id == request.id }) { return record.conversation }
        if record.conversation.run?.isActive == true { throw AskLocalError.message(L("ask.local.busy")) }
        guard record.conversation.messages.count < Self.maxMessages else { throw AskLocalError.message(L("ask.local.full")) }
        let modelRef = try Self.localModel(request.modelRef)
        var c = record.conversation
        if c.messages.isEmpty { c.memory = request.memory?.usable(at: now()) }
        c.memoryOff = c.memory != nil && request.memoryOff == true ? true : nil
        if let zone = request.timeZone, TimeZone(identifier: zone) != nil { record.timeZone = zone }
        if let locale = request.locale, !locale.isEmpty, locale.count <= 35 { record.locale = locale }
        c.messages.append(AskMessage(id: request.id, role: "user", text: request.text, selection: request.selection, source: request.source,
                                     image: request.image, createdAt: now(), reasoningEffort: request.reasoningEffort, references: request.references,
                                     attachments: request.attachments, skills: request.skills, mcpServers: request.mcpServers))
        c.modelRef = modelRef
        c.run = AskRun(id: UUID().uuidString.lowercased(), deviceId: request.deviceId, status: "running", steps: 0, updatedAt: now(),
                       tools: request.tools, pending: [], modelRef: modelRef, reasoningEffort: request.reasoningEffort)
        record.conversation = c
        prepareRun(&record)
        return try await step(&record)
    }

    func result(conversationId: String, request: AskToolResultRequest, token _: String) async throws -> AskConversation {
        var record = try record(conversationId)
        guard let run = record.conversation.run, run.id == request.runId, run.deviceId == request.deviceId else { throw conflict() }
        if record.conversation.messages.contains(where: { $0.role == "tool" && $0.toolCallId == request.toolCallId }) { return record.conversation }
        guard run.status == "waiting_tool", run.pending.first?.id == request.toolCallId else { throw conflict() }
        record.conversation.messages.append(request.message(step: run.steps, now: now()))
        record.conversation.run?.pending.removeFirst()
        return try await continueTools(&record)
    }

    func inferenceResult(conversationId: String, request: AskInferenceResult, token _: String) async throws -> AskConversation {
        var record = try record(conversationId)
        guard let run = record.conversation.run, run.id == request.runId, run.deviceId == request.deviceId else { throw conflict() }
        if record.lastInferenceId == request.inferenceId { return record.conversation }
        guard run.status == "waiting_inference", let inference = run.inference, inference.id == request.inferenceId else { throw conflict() }
        record.lastInferenceId = request.inferenceId
        record.conversation.run?.inference = nil
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
            return try await step(&record)
        }
        record.conversation.run?.reasoning = request.reasoning
        record.conversation.run?.reasoningMilliseconds = request.reasoningMilliseconds
        return try await applyCompletion(&record, content: request.content, calls: request.toolCalls, finishReason: request.finishReason)
    }

    func cancel(conversationId: String, runId: String, token: String) async throws -> AskConversation {
        try await cancel(conversationId: conversationId, runId: runId, partial: nil, token: token)
    }

    func cancel(conversationId: String, runId: String, partial: AskInferenceResult?, token _: String) async throws -> AskConversation {
        var record = try record(conversationId)
        guard let run = record.conversation.run, run.id == runId else { throw conflict() }
        guard run.isActive else { return record.conversation }
        if let partial, run.status == "waiting_inference", run.inference?.id == partial.inferenceId, partial.deviceId == run.deviceId {
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
    func steer(conversationId: String, request: AskSteerRequest, token _: String) async throws -> AskConversation {
        var record = try record(conversationId)
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

    func retry(conversationId: String, runId: String, deviceId: String, modelRef: String?, token _: String) async throws -> AskConversation {
        var record = try record(conversationId)
        guard let run = record.conversation.run, run.id == runId, run.deviceId == deviceId else { throw conflict() }
        if run.isActive || run.status == "completed" { return record.conversation }
        let model = try Self.localModel(modelRef ?? run.modelRef)
        record.conversation.modelRef = model
        record.conversation.run = AskRun(id: UUID().uuidString.lowercased(), deviceId: deviceId, status: "running", steps: 0, updatedAt: now(),
                                         tools: run.tools, pending: [], modelRef: model,
                                         reasoningEffort: model == run.modelRef ? run.reasoningEffort : nil)
        prepareRun(&record)
        return try await step(&record)
    }

    func regenerate(conversationId: String, request: AskRegenerateRequest, token _: String) async throws -> AskConversation {
        var record = try record(conversationId)
        var c = record.conversation
        if c.run?.isActive == true { throw conflict() }
        guard let index = c.messages.firstIndex(where: { $0.id == request.messageId && $0.role == "assistant" }),
              !c.messages[(index + 1)...].contains(where: { $0.role == "user" }) else { throw AskLocalError.message(L("ask.local.regenerateLatest")) }
        var cut = index
        while cut > 0, c.messages[cut - 1].role != "user" { cut -= 1 }
        guard cut > 0 else { throw AskLocalError.message(L("ask.local.regenerateLatest")) }
        let prompt = c.messages[cut - 1]
        let model = try Self.localModel(request.modelRef ?? c.modelRef)
        c.messages = Array(c.messages.prefix(cut))
        if let through = c.summaryThrough, through > c.messages.count { c.summaryThrough = c.messages.count }
        c.modelRef = model
        c.run = AskRun(id: UUID().uuidString.lowercased(), deviceId: request.deviceId, status: "running", steps: 0, updatedAt: now(),
                       tools: request.tools ?? c.run?.tools ?? [], pending: [], modelRef: model, reasoningEffort: prompt.reasoningEffort)
        record.conversation = c
        prepareRun(&record)
        return try await step(&record)
    }

    // MARK: - Run

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

    private func conflict() -> AskLocalError { .message(L("ask.local.conflict")) }

    private func prepareRun(_ record: inout AskLocalRecord) {
        record.typedContentEnabled = typedContentEnabled
        // Messages left from an earlier run were taken back by the device.
        record.steering = nil
        record.builtinTools = [Self.planTool] + webTools.definitions()
        record.cloudCalls = 0
        let zone = record.timeZone.flatMap(TimeZone.init(identifier:)) ?? TimeZone(identifier: "UTC")!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd (EEEE)"
        record.localDate = formatter.string(from: now())
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
    private func step(_ record: inout AskLocalRecord) async throws -> AskConversation {
        if record.conversation.run?.status == "running" { deliverSteering(&record) }
        guard let run = record.conversation.run else { return record.conversation }
        guard run.steps < Self.maxSteps + (run.extraSteps ?? 0) else { return try fail(&record, L("ask.local.stepLimit")) }
        let c = record.conversation
        let through = c.summaryThrough ?? 0
        if c.messages.count - through > Self.summarizeAfter {
            var cut = c.messages.count - Self.keepRecent
            while cut > through, c.messages[cut].role != "user" { cut -= 1 }
            if cut > through {
                return try queue(&record, payload: AskLocalPrompt.summaryPayload(conversation: c, through: cut), summaryThrough: cut)
            }
        }
        record.conversation.run?.assistantId = UUID().uuidString.lowercased()
        record.conversation.run?.preview = nil
        record.conversation.run?.reasoning = nil
        record.conversation.run?.reasoningMilliseconds = nil
        return try queue(&record, payload: AskLocalPrompt.payload(conversation: record.conversation, record: record, tools: allTools(record)),
                         summaryThrough: nil)
    }

    private func queue(_ record: inout AskLocalRecord, payload: [String: Any], summaryThrough: Int?) throws -> AskConversation {
        record.conversation.run?.status = "waiting_inference"
        record.conversation.run?.inference = AskInference(id: UUID().uuidString.lowercased(), payload: AskLocalPrompt.json(payload),
                                                         summaryThrough: summaryThrough)
        try save(&record)
        return record.conversation
    }

    private func applyCompletion(_ record: inout AskLocalRecord, content: String, calls: [AskToolCall], finishReason: String?) async throws -> AskConversation {
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
    private func continueTools(_ record: inout AskLocalRecord) async throws -> AskConversation {
        while let call = record.conversation.run?.pending.first, isBuiltin(call, record) {
            record.conversation.run?.status = "running"
            try save(&record)
            let runId = record.conversation.run?.id
            let result = await executeBuiltin(call, cloudCalls: record.cloudCalls)
            guard let latest = records[record.conversation.id] else {
                throw AskLocalError.message(L("ask.local.notFound"))
            }
            // Cancellation or a replacement run wins over a late tool result.
            guard latest.conversation.run?.id == runId,
                  latest.conversation.run?.status == "running", latest.conversation.run?.pending.first?.id == call.id else {
                return latest.conversation
            }
            // Apply only the tool's delta to current state. In particular, never
            // write memory from the snapshot taken before a concurrent purge.
            record = latest
            if let plan = result.plan { record.conversation.run?.plan = plan }
            record.conversation.messages.append(AskMessage(id: UUID().uuidString, role: "tool", text: result.text,
                                                           toolCallId: call.id, isError: result.isError, createdAt: now()))
            record.conversation.run?.pending.removeFirst()
            record.cloudCalls += 1
        }
        if record.conversation.run?.pending.isEmpty == false {
            record.conversation.run?.status = "waiting_tool"
            try save(&record)
            return record.conversation
        }
        record.conversation.run?.status = "running"
        return try await step(&record)
    }

    private struct BuiltinResult {
        var text: String
        var isError: Bool
        var plan: [AskPlanItem]?
    }

    private func executeBuiltin(_ call: AskToolCall, cloudCalls: Int) async -> BuiltinResult {
        guard cloudCalls < Self.maxBuiltinCalls else {
            return BuiltinResult(
                text: "Web tool limit for this request reached. Answer with the information gathered so far.",
                isError: true)
        }
        if call.function.name == "update_plan" {
            do {
                return BuiltinResult(text: "Plan updated.", isError: false,
                                     plan: try Self.parsePlan(call.function.arguments))
            } catch { return BuiltinResult(text: error.localizedDescription, isError: true) }
        }
        let (text, failed) = await webTools.execute(name: call.function.name, arguments: call.function.arguments)
        return BuiltinResult(text: text, isError: failed)
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

    private func fail(_ record: inout AskLocalRecord, _ reason: String) throws -> AskConversation {
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

    // MARK: - Plan

    static let planTool = AskToolDefinition(
        name: "update_plan",
        description: "Record the plan for a multi-step task so the user can follow progress. Send the complete list every time; mark at most one step in_progress.",
        parameters: JSONValue(data: try! JSONSerialization.data(withJSONObject: [
            "type": "object", "required": ["items"], "additionalProperties": false,
            "properties": ["items": ["type": "array", "minItems": 1, "maxItems": 20, "items": [
                "type": "object", "required": ["step", "status"], "additionalProperties": false,
                "properties": ["step": ["type": "string"], "status": ["type": "string", "enum": ["pending", "in_progress", "completed"]]]
            ]]]
        ], options: .sortedKeys)))

    static func parsePlan(_ arguments: String) throws -> [AskPlanItem] {
        let args = try AskLocalTools.jsonArguments(arguments)
        guard let raw = args["items"] as? [[String: Any]], (1 ... 20).contains(raw.count) else {
            throw AskLocalError.message("items must list 1 to 20 steps")
        }
        var active = 0
        let items = try raw.map { item -> AskPlanItem in
            let step = (item["step"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let status = item["status"] as? String ?? ""
            guard !step.isEmpty, step.count <= 300 else { throw AskLocalError.message("Each step needs 1 to 300 characters") }
            guard ["pending", "in_progress", "completed"].contains(status) else {
                throw AskLocalError.message("status must be pending, in_progress or completed")
            }
            if status == "in_progress" { active += 1 }
            return AskPlanItem(step: step, status: status)
        }
        guard active <= 1 else { throw AskLocalError.message("Mark at most one step in_progress") }
        return items
    }
}
