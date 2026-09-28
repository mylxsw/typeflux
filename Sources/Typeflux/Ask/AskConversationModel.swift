import AppKit
import Combine

@MainActor
final class AskConversationModel: ObservableObject {
    @Published var launcherDraft = AskDraft()
    @Published var draft = AskDraft.followUp
    @Published private(set) var conversations: [AskConversationSummary] = []
    @Published private(set) var selected: AskConversation?
    @Published private(set) var pendingApprovals: [String: AskToolCall] = [:]
    @Published private(set) var busyIds: Set<String> = []
    @Published private(set) var capturing = false
    @Published var error: String?
    @Published var captureWarning: String?
    @Published var historyHasMore = false
    @Published var controllingConversationId: String?

    var onShowConversation: (() -> Void)?
    var onControlChanged: ((Bool) -> Void)?
    var recordingIsActive: () -> Bool = { false }

    private let api: any AskAPI
    private let cache: any AskCaching
    private let tools: any AskToolExecuting
    private let capture: any AskContextCapturing
    private let session: () -> (owner: String, token: String)?
    let deviceId: String
    private var owner = ""
    private var operations: [String: Task<Void, Never>] = [:]
    private var operationIds: [String: UUID] = [:]
    private var approvals: [String: CheckedContinuation<Bool, Never>] = [:]
    private var pendingSends: [String: AskSendRequest] = [:]
    private var captureGeneration = UUID()
    private var selectionGeneration = UUID()
    private var draftSave: Task<Void, Never>?
    private var authObserver: AnyCancellable?

    init(api: any AskAPI, cache: any AskCaching, tools: any AskToolExecuting,
         capture: any AskContextCapturing, deviceId: String,
         session: @escaping () -> (owner: String, token: String)?) {
        self.api = api; self.cache = cache; self.tools = tools; self.capture = capture
        self.deviceId = deviceId; self.session = session
        authObserver = NotificationCenter.default.publisher(for: .authDidLogout).sink { [weak self] _ in
            Task { @MainActor in self?.resetSession() }
        }
    }

    var isBusy: Bool { selected.map { busyIds.contains($0.id) || $0.run?.isActive == true } ?? false }
    var canSend: Bool { draft.canSend && !isBusy && (selected.map { pendingSends[$0.id] == nil && !($0.run == nil && $0.messages.last?.role == "user") } ?? true) && !capturing && !recordingIsActive() }
    var canSendLauncher: Bool { launcherDraft.canSend && !capturing && !recordingIsActive() }

    private func credentials() -> (owner: String, token: String)? {
        guard let current = session() else { error = L("ask.loginRequired"); return nil }
        if owner != current.owner { resetSession(); owner = current.owner }
        return current
    }

    func resetSession() {
        operations.values.forEach { $0.cancel() }; operations = [:]; operationIds = [:]
        approvals.values.forEach { $0.resume(returning: false) }; approvals = [:]
        pendingApprovals = [:]; busyIds = []; pendingSends = [:]
        draftSave?.cancel(); captureGeneration = UUID(); selectionGeneration = UUID()
        selected = nil; conversations = []; launcherDraft = AskDraft(); draft = .followUp
        capturing = false; controllingConversationId = nil; onControlChanged?(false); owner = ""
    }

    func prepareLauncher() async {
        captureWarning = nil
        if let current = session(), owner != current.owner { resetSession(); owner = current.owner }
        let expectedOwner = owner
        if launcherDraft.text.isEmpty, let cached = try? await cache.draft(key: "launcher", owner: owner) {
            guard owner == expectedOwner else { return }
            launcherDraft = cached
        }
        // Restore an unfinished question without silently replacing its context.
        if !launcherDraft.text.isEmpty { return }
        capturing = true
        let generation = UUID(); captureGeneration = generation
        let context = await capture.capture(includeScreenshot: launcherDraft.includeScreenshot)
        guard generation == captureGeneration else { return }
        launcherDraft.selection = context.selection
        launcherDraft.source = context.source
        launcherDraft.screenshot = context.screenshot
        launcherDraft.capturedAt = context.capturedAt
        captureWarning = context.warning; capturing = false
        persistDrafts()
    }

    func refreshScreenshot(launcher: Bool) async {
        let generation = UUID(); captureGeneration = generation; capturing = true
        let selectedId = selected?.id
        let context = await capture.capture(includeScreenshot: true)
        guard captureGeneration == generation else { return }
        defer { capturing = false }
        if launcher { launcherDraft.screenshot = context.screenshot; launcherDraft.capturedAt = context.capturedAt }
        else if selected?.id == selectedId { draft.screenshot = context.screenshot; draft.capturedAt = context.capturedAt }
        captureWarning = context.warning; persistDrafts()
    }

    func persistDrafts() {
        draftSave?.cancel()
        let launcher = launcherDraft, followUp = draft, id = selected?.id, owner = owner
        draftSave = Task { [cache] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                try await cache.saveDraft(launcher, key: "launcher", owner: owner)
                if let id { try await cache.saveDraft(followUp, key: id, owner: owner) }
            } catch is CancellationError {} catch { self.error = L("ask.cache.failed") }
        }
    }

    func refreshHistory(loadMore: Bool = false) async {
        guard let current = credentials() else { return }
        if !loadMore, conversations.isEmpty {
            let cached = (try? await cache.list(owner: current.owner)) ?? []
            guard owner == current.owner else { return }
            conversations = cached
        }
        do {
            let items = try await api.list(token: current.token, offset: loadMore ? conversations.count : 0)
            guard owner == current.owner else { return }
            conversations = loadMore ? conversations + items.filter { item in !conversations.contains { $0.id == item.id } } : items
            historyHasMore = items.count == 50
        } catch { if owner == current.owner { self.error = error.localizedDescription } }
    }

    func select(_ id: String) async {
        guard let current = credentials() else { return }
        let generation = UUID(); selectionGeneration = generation
        if let old = selected { try? await cache.saveDraft(draft, key: old.id, owner: current.owner) }
        let cached = try? await cache.load(id: id, owner: current.owner)
        let savedDraft = try? await cache.draft(key: id, owner: current.owner)
        guard generation == selectionGeneration, owner == current.owner else { return }
        selected = cached
        draft = savedDraft ?? .followUp
        do {
            let value = try await api.conversation(id: id, token: current.token)
            guard generation == selectionGeneration, owner == current.owner else { return }
            selected = value
            try await cache.save(value, owner: current.owner)
            // Resuming requires a deliberate user action so reconnect never
            // silently approves or replays a desktop operation.
        } catch { if generation == selectionGeneration { self.error = error.localizedDescription } }
    }

    func newConversation() {
        persistDrafts(); selectionGeneration = UUID(); selected = nil; draft = AskDraft(); error = nil; captureWarning = nil
    }

    func submitLauncher() {
        guard canSendLauncher else { return }
        submit(launcherDraft, newConversation: true)
    }
    func submitDraft() {
        guard canSend else { return }
        submit(draft, newConversation: selected == nil)
    }

    private func submit(_ submitted: AskDraft, newConversation: Bool) {
        guard submitted.text.utf8.count <= 32000, (submitted.selection?.utf8.count ?? 0) <= 64000,
              (submitted.source?.utf8.count ?? 0) <= 1000 else {
            error = L("ask.input.tooLarge"); return
        }
        guard let current = credentials() else { return }
        guard newConversation || selected != nil else { return }
        let id = newConversation ? UUID().uuidString : selected!.id
        guard !busyIds.contains(id) else { return }
        error = nil; busyIds.insert(id)
        if newConversation { tools.bindConversation(id) }
        var value = newConversation ? AskConversation(id: id, title: String(submitted.text.prefix(50)), revision: 0, updatedAt: Date(), messages: []) : selected!
        let messageId = UUID().uuidString
        let request = submitted.request(deviceId: deviceId, tools: [], id: messageId)
        pendingSends[id] = request
        value.messages.append(.init(id: messageId, role: "user", text: request.text, selection: request.selection, source: request.source, image: request.image, createdAt: Date()))
        selected = value; selectionGeneration = UUID(); draft = .followUp
        if newConversation { launcherDraft = AskDraft() }
        onShowConversation?(); persistDrafts()
        let operationId = UUID(); operationIds[id] = operationId
        operations[id] = Task { [weak self] in
            guard let self else { return }
            defer { finishOperation(id, operationId: operationId) }
            let monitor = monitorConversation(id: id, current: current)
            defer { monitor.cancel() }
            do {
                try await cache.save(value, owner: current.owner)
                var request = request
                request.tools = await tools.definitions()
                try Task.checkCancellation()
                pendingSends[id] = request
                let response = try await api.send(conversationId: id, request: request, token: current.token)
                pendingSends[id] = nil
                try await drive(response, current: current)
            } catch is CancellationError {} catch { if owner == current.owner { self.error = error.localizedDescription } }
        }
    }

    func resume() {
        guard let current = credentials(), let value = selected, !busyIds.contains(value.id) else { return }
        let id = value.id
        busyIds.insert(id); error = nil
        let operationId = UUID(); operationIds[id] = operationId
        operations[id] = Task { [weak self] in
            guard let self else { return }; defer { finishOperation(id, operationId: operationId) }
            let monitor = monitorConversation(id: id, current: current)
            defer { monitor.cancel() }
            do {
                _ = await tools.definitions()
                let response: AskConversation
                if let request = pendingSends[id] {
                    response = try await api.send(conversationId: id, request: request, token: current.token)
                    pendingSends[id] = nil
                } else if value.run == nil, let message = value.messages.last, message.role == "user" {
                    let request = AskSendRequest(id: message.id, deviceId: deviceId, text: message.text,
                                                 selection: message.selection, source: message.source, image: message.image,
                                                 tools: await tools.definitions())
                    response = try await api.send(conversationId: id, request: request, token: current.token)
                } else if let run = value.run, ["failed", "cancelled"].contains(run.status) {
                    response = try await api.retry(conversationId: id, runId: run.id, deviceId: deviceId, token: current.token)
                } else {
                    response = try await api.conversation(id: id, token: current.token)
                }
                try await drive(response, current: current)
            } catch is CancellationError {} catch { if owner == current.owner { self.error = error.localizedDescription } }
        }
    }

    private func accept(_ value: AskConversation, owner expectedOwner: String) async throws {
        try Task.checkCancellation()
        guard owner == expectedOwner else { throw CancellationError() }
        try await cache.save(value, owner: expectedOwner)
        guard owner == expectedOwner else { throw CancellationError() }
        if selected?.id == value.id, (selected?.revision ?? -1) <= value.revision { selected = value }
        conversations.removeAll { $0.id == value.id }
        conversations.insert(.init(id: value.id, title: value.title, updatedAt: value.updatedAt), at: 0)
    }

    private func drive(_ initial: AskConversation, current: (owner: String, token: String)) async throws {
        var value = initial
        while true {
            try await accept(value, owner: current.owner)
            guard let run = value.run, run.isActive else { return }
            if run.status == "running" {
                try await Task.sleep(for: .seconds(1))
                value = try await api.conversation(id: value.id, token: current.token)
                continue
            }
            guard run.deviceId == deviceId else { throw AskLocalError.message(L("ask.tool.otherDevice")) }
            guard let call = run.pending.first else { return }
            let journalKey = run.id + "/" + call.id
            try await cache.associateTool(id: journalKey, conversationId: value.id, owner: current.owner)
            var result = try await cache.toolResult(id: journalKey, owner: current.owner)
            if result == nil {
                pendingApprovals[value.id] = call
                let approved = await withCheckedContinuation { approvals[value.id] = $0 }
                pendingApprovals[value.id] = nil
                try Task.checkCancellation()
                result = AskToolResultRequest(runId: run.id, deviceId: deviceId, toolCallId: call.id, content: "User denied this tool call. Do not repeat it.", isError: true)
                let latest = try await api.conversation(id: value.id, token: current.token)
                try await accept(latest, owner: current.owner)
                guard latest.run?.id == run.id, latest.run?.status == "waiting_tool",
                      latest.run?.pending.first?.id == call.id else { return }
                if approved {
                    guard try await cache.claimTool(id: journalKey, owner: current.owner) else {
                        result?.content = "A previous execution was interrupted; its outcome is unknown. Do not replay it. Ask the user to inspect the result."
                        try await cache.saveToolResult(result!, owner: current.owner)
                        value = try await api.result(conversationId: value.id, request: result!, token: current.token)
                        continue
                    }
                    do {
                        if call.function.name == "computer" || call.function.name == "browser" {
                            guard controllingConversationId == nil else { throw AskLocalError.message(L("ask.tool.busy")) }
                            controllingConversationId = value.id; onControlChanged?(true)
                        }
                        let output = try await tools.execute(call, conversationId: value.id)
                        try Task.checkCancellation()
                        result?.content = output.content; result?.image = output.image; result?.isError = false
                    } catch is CancellationError { throw CancellationError() }
                    catch { result?.content = error.localizedDescription }
                    if controllingConversationId == value.id { controllingConversationId = nil; onControlChanged?(false) }
                }
                try await cache.saveToolResult(result!, owner: current.owner)
            }
            try Task.checkCancellation()
            value = try await api.result(conversationId: value.id, request: result!, token: current.token)
        }
    }

    func approve(conversationId: String, allowed: Bool) {
        approvals.removeValue(forKey: conversationId)?.resume(returning: allowed)
    }

    func stop(id: String? = nil) {
        guard let current = credentials(), let id = id ?? selected?.id else { return }
        operations[id]?.cancel()
        approve(conversationId: id, allowed: false)
        if controllingConversationId == id { controllingConversationId = nil; onControlChanged?(false) }
        Task {
            do {
                let value = try await api.conversation(id: id, token: current.token)
                guard let run = value.run else { return }
                let stopped = try await api.cancel(conversationId: id, runId: run.id, token: current.token)
                if owner == current.owner { pendingSends[id] = nil }
                try await accept(stopped, owner: current.owner)
            } catch { if owner == current.owner { self.error = error.localizedDescription } }
        }
    }

    func delete(_ id: String) async {
        guard let current = credentials(), !busyIds.contains(id) else { return }
        do {
            try await api.delete(conversationId: id, token: current.token)
            try await cache.delete(id: id, owner: current.owner)
            guard owner == current.owner else { return }
            conversations.removeAll { $0.id == id }
            if selected?.id == id { newConversation() }
        } catch { self.error = error.localizedDescription }
    }

    private func finishOperation(_ id: String, operationId: UUID) {
        guard operationIds[id] == operationId else { return }
        operationIds[id] = nil
        busyIds.remove(id); operations[id] = nil; pendingApprovals[id] = nil
        if controllingConversationId == id { controllingConversationId = nil; onControlChanged?(false) }
    }

    private func monitorConversation(id: String, current: (owner: String, token: String)) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                    guard let self, owner == current.owner else { return }
                    let value = try await api.conversation(id: id, token: current.token)
                    if let pending = pendingSends[id], !value.messages.contains(where: { $0.id == pending.id }) { continue }
                    try await accept(value, owner: current.owner)
                    if value.run?.isActive == false { approve(conversationId: id, allowed: false) }
                } catch is CancellationError { return }
                catch { /* The sending operation presents terminal network errors. */ }
            }
        }
    }
}
