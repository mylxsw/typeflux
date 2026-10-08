import Foundation

/// The workflow assistant: one Ask conversation per workflow, run through the same
/// routed API as the Ask window (Typeflux Cloud when signed in, the on-device engine
/// otherwise), with only the workflow tools and the author skill. It executes the
/// tool calls itself against its host. See `docs/design/ask-workflow-editor.md` §10.
@MainActor
final class AskWorkflowAssistant: ObservableObject {
    enum Item: Identifiable, Equatable {
        case user(id: String, text: String)
        case reply(id: String, text: String)
        case tool(id: UUID, summary: String, failed: Bool)
        case proposal(UUID)
        case notice(id: UUID, text: String)

        var id: String {
            switch self {
            case let .user(id, _), let .reply(id, _): id
            case let .tool(id, _, _), let .notice(id, _): id.uuidString
            case let .proposal(id): "proposal-" + id.uuidString
            }
        }
    }

    struct Dependencies {
        var api: any AskAPI
        /// The signed-in Cloud session, or the local one with an empty token.
        var session: () -> (owner: String, token: String)
        var deviceId: String
        var modelLibrary: AskModelLibrary
        var inference = AskCustomInference()
        /// New conversations stay on this Mac by the user's choice.
        var prefersLocal: () -> Bool = { false }
        var defaults: UserDefaults = .standard
    }

    /// Tool calls one message may make before the assistant is told to stop and summarize.
    static let toolCallLimit = 40
    static let conversationsKey = "ask.workflows.assistant"

    @Published private(set) var items: [Item] = []
    @Published private(set) var isBusy = false
    /// What the model is writing right now.
    @Published private(set) var preview = ""
    @Published var error: String?
    private(set) var conversationID: String?
    private(set) var isLocal = false

    weak var host: AskWorkflowAuthoringHost?
    var tools = AskWorkflowAuthorTools()
    private let dependencies: Dependencies
    private var task: Task<Void, Never>?
    /// The send whose run is current; a cancelled one must not touch the next one's state.
    private var generation = UUID()
    private var runID: String?
    private var seenMessages = Set<String>()
    /// Which workflow the conversation is remembered under.
    private var workflowKey: String?

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    // MARK: - Sending

    /// The model a new message runs on: the Ask default, or for a conversation kept on
    /// this Mac the first of the user's own models. Nil when there is none to use.
    func modelReference(local: Bool) -> String? {
        let library = dependencies.modelLibrary
        let reference = library.defaultReference
        guard local, reference.hasPrefix("cloud:") else { return reference }
        return library.firstLocalReference(hasImage: false) ?? library.firstLocalReference(
            hasImage: false,
            confirmedVision: false
        )
    }

    /// The model a message would go to, by name: "Typeflux Cloud", "gpt-4.1".
    var modelName: String {
        let local = conversationID == nil ? (dependencies.session().token.isEmpty || dependencies.prefersLocal()) :
            isLocal
        return modelReference(local: local).map { dependencies.modelLibrary.name(for: $0) } ?? ""
    }

    /// Where the conversation is kept: on this Mac, or in Typeflux Cloud.
    var keepsLocally: Bool {
        conversationID == nil ? (dependencies.session().token.isEmpty || dependencies.prefersLocal()) : isLocal
    }

    /// Sends `text`; the conversation shows `shown` instead when the message carries
    /// instructions the user did not type.
    func send(_ text: String, shown: String? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        error = nil
        if conversationID == nil {
            let session = dependencies.session()
            isLocal = session.token.isEmpty || dependencies.prefersLocal()
            conversationID = UUID().uuidString.lowercased()
        }
        let token = isLocal ? "" : dependencies.session().token
        guard isLocal || !token.isEmpty else {
            error = L("ask.workflow.assistant.signedOut")
            return
        }
        guard let model = modelReference(local: isLocal) else {
            error = L("ask.workflow.assistant.noModel")
            return
        }
        let messageID = UUID().uuidString.lowercased()
        seenMessages.insert(messageID)
        items.append(.user(id: messageID, text: shown ?? text))
        remember()
        let request = AskSendRequest(
            id: messageID,
            deviceId: dependencies.deviceId,
            text: text,
            selection: nil,
            source: nil,
            image: nil,
            tools: AskWorkflowAuthorTools.definitions,
            modelRef: model,
            skills: [AskWorkflowAuthorSkill.use]
        )
        let conversation = conversationID ?? ""
        isBusy = true
        let current = UUID()
        generation = current
        task = Task { [weak self] in
            await self?.run(conversation: conversation, token: token, generation: current) { api in
                try await api.send(conversationId: conversation, request: request, token: token)
            }
        }
    }

    /// Stops the current answer; the run is cancelled on the server too.
    func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        if isBusy, let conversationID, let runID {
            let token = isLocal ? "" : dependencies.session().token
            Task { [api = dependencies.api] in _ = try? await api.cancel(
                conversationId: conversationID,
                runId: runID,
                token: token
            ) }
        }
        isBusy = false
        preview = ""
        runID = nil
    }

    private func run(conversation: String, token: String, generation current: UUID,
                     start: @escaping (any AskAPI) async throws -> AskConversation) async {
        defer {
            if generation == current {
                isBusy = false
                preview = ""
                runID = nil
            }
        }
        do {
            var value = try await start(dependencies.api)
            var calls = 0
            while true {
                try checkCurrent(current)
                accept(value)
                guard let run = value.run, run.isActive else {
                    if let failure = value.run?.error, value.run?.status == "failed" {
                        error = failure
                    }
                    return
                }
                value = try await advance(
                    run,
                    conversation: conversation,
                    token: token,
                    calls: &calls,
                    generation: current
                )
            }
        } catch is CancellationError {
        } catch {
            if generation == current {
                self.error = error.localizedDescription
            }
        }
    }

    /// One step of an active run: wait for the server, run the model here, or run a tool.
    private func advance(_ run: AskRun, conversation: String, token: String,
                         calls: inout Int, generation current: UUID) async throws -> AskConversation {
        let api = dependencies.api
        runID = run.id
        if run.needsRecoveryInspection {
            throw AskLocalError.message(L("ask.workflow.assistant.interrupted"))
        }
        if run.isPausedForCredits {
            throw CloudCreditsExhaustedError(details: nil)
        }
        if run.status == "running" {
            preview = run.preview ?? preview
        }
        if run.status != "running" {
            guard run.deviceId == dependencies.deviceId else { throw AskLocalError.message(L("ask.tool.otherDevice")) }
            if run.status == "waiting_inference", let inference = run.inference {
                return try await infer(
                    inference,
                    run: run,
                    conversation: conversation,
                    token: token,
                    generation: current
                )
            }
            if run.status == "waiting_tool", let call = run.pending.first {
                calls += 1
                let output = try await execute(call, count: calls, generation: current)
                try Task.checkCancellation()
                let result = AskToolResultRequest(runId: run.id, deviceId: dependencies.deviceId, toolCallId: call.id,
                                                  content: output.content, isError: output.isError)
                return try await api.result(conversationId: conversation, request: result, token: token)
            }
        }
        try await Task.sleep(for: .milliseconds(700))
        return try await api.conversation(id: conversation, token: token)
    }

    private func execute(_ call: AskToolCall, count: Int, generation current: UUID) async throws
        -> AskWorkflowAuthorTools.Output {
        guard AskWorkflowAuthorTools.names.contains(call.function.name) else {
            return .init(
                content: "This tool is not available here.",
                isError: true,
                summary: L("ask.workflow.assistant.tool.unknown")
            )
        }
        guard count <= Self.toolCallLimit else {
            return .init(
                content: "Tool limit reached for this message. Stop and summarize for the user.",
                isError: true,
                summary: L("ask.workflow.assistant.tool.limit")
            )
        }
        guard let host else {
            return .init(
                content: "The editor was closed.",
                isError: true,
                summary: L("ask.workflow.assistant.tool.unknown")
            )
        }
        preview = ""
        let output = await tools.execute(call, host: host)
        try checkCurrent(current)
        items.append(.tool(id: UUID(), summary: output.summary, failed: output.isError))
        if let proposal = output.proposalID {
            items.append(.proposal(proposal))
        }
        return output
    }

    // Runs one model step on this Mac for a conversation whose model is the user's own.
}

extension AskWorkflowAssistant {
    private func infer(_ inference: AskInference, run: AskRun, conversation: String,
                       token: String, generation current: UUID) async throws -> AskConversation {
        let library = dependencies.modelLibrary
        guard let reference = run.modelRef, let (provider, model) = library.registry.resolve(reference) else {
            throw AskLocalError.message(L("ask.models.unavailable"))
        }
        if let reason = library.selectionReason(model, provider: provider, hasImage: false, loggedIn: !token.isEmpty) {
            throw AskLocalError.message(reason)
        }
        let payload = try AskContextPlanner.devicePayload(
            inference.payload,
            model: model,
            budgeted: run.budgetEnabled == true
        )
        var receipt: AskInferenceResult
        do {
            let (text, calls) = try await dependencies.inference.complete(
                provider: provider, connection: library.connection(provider, model: model), payload: payload,
                onProgress: { [weak self] progress in await self?.showProgress(progress.text, generation: current) }
            )
            receipt = AskInferenceResult(runId: run.id, deviceId: dependencies.deviceId, inferenceId: inference.id,
                                         content: text, toolCalls: calls)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try checkCurrent(current)
            receipt = AskInferenceResult(runId: run.id, deviceId: dependencies.deviceId, inferenceId: inference.id,
                                         content: "", failed: true)
            self.error = error.localizedDescription
        }
        try checkCurrent(current)
        return try await dependencies.api.inferenceResult(conversationId: conversation, request: receipt, token: token)
    }

    private func checkCurrent(_ current: UUID) throws {
        try Task.checkCancellation()
        guard generation == current else { throw CancellationError() }
    }

    private func showProgress(_ text: String, generation current: UUID) {
        guard generation == current, !Task.isCancelled else { return }
        preview = text
    }

    /// Adds the assistant's new replies to the conversation.
    private func accept(_ value: AskConversation) {
        for message in value.messages where !seenMessages.contains(message.id) {
            guard message.role == "assistant" else {
                if message.role == "user" {
                    seenMessages.insert(message.id)
                }
                continue
            }
            seenMessages.insert(message.id)
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                items.append(.reply(id: message.id, text: text))
            }
        }
    }
}

extension AskWorkflowAssistant {
    // MARK: - Conversation per workflow

    /// Switches to the conversation remembered for `workflowID`, or a new one.
    func bind(workflowID: String?) {
        stop()
        workflowKey = workflowID
        items = []
        seenMessages = []
        preview = ""
        error = nil
        conversationID = nil
        guard let workflowID, let saved = Self.saved(dependencies.defaults)[workflowID] else { return }
        let parts = saved.split(separator: "|")
        guard let id = parts.first.map(String.init) else { return }
        conversationID = id
        isLocal = parts.dropFirst().first == "local"
        let token = isLocal ? "" : dependencies.session().token
        guard isLocal || !token.isEmpty else { conversationID = nil; return }
        let current = generation
        task = Task { [weak self, api = dependencies.api] in
            guard let value = try? await api.conversation(id: id, token: token),
                  !Task.isCancelled, self?.generation == current else { return }
            self?.restore(value)
        }
    }

    /// Moves the conversation to another workflow key, e.g. once a generated workflow is installed.
    func rebind(to workflowID: String) {
        workflowKey = workflowID
        remember()
    }

    private func restore(_ value: AskConversation) {
        for message in value.messages where !seenMessages.contains(message.id) {
            seenMessages.insert(message.id)
            if message.role == "user", !message.text.isEmpty {
                items.append(.user(id: message.id, text: message.text))
            }
            if message.role == "assistant", !message.text.isEmpty {
                items.append(.reply(
                    id: message.id,
                    text: message.text
                ))
            }
        }
    }

    private static func saved(_ defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: conversationsKey) as? [String: String] ?? [:]
    }

    private func remember() {
        guard let workflowKey, let conversationID else { return }
        var saved = Self.saved(dependencies.defaults)
        saved[workflowKey] = conversationID + "|" + (isLocal ? "local" : "cloud")
        dependencies.defaults.set(saved, forKey: Self.conversationsKey)
    }

    /// Forgets the conversation of a deleted workflow.
    static func forget(workflowID: String, defaults: UserDefaults = .standard) {
        var saved = saved(defaults)
        saved[workflowID] = nil
        defaults.set(saved, forKey: conversationsKey)
    }

    func appendNotice(_ text: String) {
        items.append(.notice(id: UUID(), text: text))
    }
}
