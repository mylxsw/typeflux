import AppKit
import Combine

@MainActor
final class AskConversationModel: ObservableObject {
    let voiceInput = AskVoiceInput()
    @Published var reasoningEffort: AskReasoningEffort = .providerDefault
    let modelLibrary: AskModelLibrary
    private var inferenceReceipts: [String: AskInferenceResult] = [:]
    var customInference = AskCustomInference()
    @Published private(set) var inferenceProgress: [String: AskStreamProgress] = [:]
    private var progressInferenceIDs: [String: String] = [:]

    func liveProgress(_ value: AskConversation) -> AskStreamProgress? {
        guard let run = value.run else { return nil }
        if run.inference?.id == progressInferenceIDs[value.id], let progress = inferenceProgress[value.id] { return progress }
        if !(run.preview ?? "").isEmpty || !(run.reasoning ?? "").isEmpty || !(run.previewTools ?? []).isEmpty {
            return .init(text: run.preview ?? "", reasoning: run.reasoning ?? "", toolCalls: run.previewTools ?? [], reasoningMilliseconds: run.reasoningMilliseconds ?? 0)
        }
        return nil
    }


    func modelReference(launcher: Bool) -> String {
        if launcher { return launcherDraft.modelRef ?? modelLibrary.defaultReference }
        return draft.modelRef ?? selected.map { $0.modelRef ?? "cloud:default" } ?? modelLibrary.defaultReference
    }
    func requiresVision(launcher: Bool) -> Bool {
        let current = launcher ? launcherDraft : draft
        return (current.includeScreenshot && current.screenshot != nil)
            || (!launcher && selected?.messages.contains(where: { $0.image != nil }) == true)
    }

    @Published var launcherDraft = AskDraft()
    @Published var referenceLocation: String?
    @Published var draft = AskDraft.followUp
    @Published private(set) var conversations: [AskConversationSummary] = []
    @Published private(set) var selected: AskConversation?
    @Published private(set) var selectedId: String?
    @Published private(set) var isLoadingSelection = false
    @Published private(set) var selectionLoadFailed = false
    private var snapshots: [String: AskConversation] = [:]
    var transcriptPositions: [String: String] = [:]
    private var drafts: [String: AskDraft] = [:]
    private var historyGeneration = UUID()
    private var historyOffset = 0
    @Published private(set) var pendingApprovals: [String: AskToolCall] = [:]
    @Published private(set) var busyIds: Set<String> = []
    @Published private(set) var capturing = false
    @Published var error: String?
    @Published var captureWarning: String?
    @Published private(set) var isRefreshingHistory = false
    @Published private(set) var historyRefreshError: String?
    private var pullRefreshID: UUID?
    private var historyErrorTask: Task<Void, Never>?
    @Published var historyHasMore = false
    @Published var controllingConversationId: String?

    var onShowConversation: (() -> Void)?
    var onOpenSettings: (() -> Void)?
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
    private var operationErrors: [String: String] = [:]
    private var pendingSends: [String: AskSendRequest] = [:]
    // Local consent for the latest submission, retained for retries but never restored from history.
    private var screenshotConsent: [String: String] = [:]
    private var captureGeneration = UUID()
    private var selectionGeneration = UUID()
    private var selectionObservation: Task<Void, Never>?
    private var draftSave: Task<Void, Never>?
    private var authObserver: AnyCancellable?

    init(api: any AskAPI, cache: any AskCaching, tools: any AskToolExecuting,
         capture: any AskContextCapturing, deviceId: String, modelLibrary: AskModelLibrary? = nil,
         session: @escaping () -> (owner: String, token: String)?) {
        self.modelLibrary = modelLibrary ?? .shared
        self.api = api; self.cache = cache; self.tools = tools; self.capture = capture
        self.deviceId = deviceId; self.session = session
        authObserver = NotificationCenter.default.publisher(for: .authDidLogout).sink { [weak self] _ in
            Task { @MainActor in self?.resetSession() }
        }
    }

    var isBusy: Bool { selected.map { busyIds.contains($0.id) || $0.run?.isActive == true } ?? false }
    var canSend: Bool { !isLoadingSelection && (selectedId == nil || selected != nil) && draft.canSend && !isBusy && (selected.map { pendingSends[$0.id] == nil && !($0.run == nil && $0.messages.last?.role == "user") } ?? true) && !capturing && !recordingIsActive() && !voiceInput.isOccupied }
    var canSendLauncher: Bool { launcherDraft.canSend && !capturing && !recordingIsActive() && !voiceInput.isOccupied }

    private func credentials() -> (owner: String, token: String)? {
        guard let current = session() else { error = L("ask.loginRequired"); return nil }
        if owner != current.owner { resetSession(); owner = current.owner }
        return current
    }

    func resetSession() {
        voiceInput.cancel()
        historyErrorTask?.cancel(); historyRefreshError = nil
        pullRefreshID = nil; isRefreshingHistory = false
        operations.values.forEach { $0.cancel() }; operations = [:]; operationIds = [:]
        approvals.values.forEach { $0.resume(returning: false) }; approvals = [:]
        inferenceReceipts = [:]
        pendingApprovals = [:]; busyIds = []; pendingSends = [:]; operationErrors = [:]
        screenshotConsent = [:]
        draftSave?.cancel(); captureGeneration = UUID(); selectionGeneration = UUID()
        selectionObservation?.cancel(); selectionObservation = nil
        inferenceProgress = [:]; progressInferenceIDs = [:]
        selected = nil; selectedId = nil; isLoadingSelection = false; selectionLoadFailed = false
        snapshots = [:]; drafts = [:]; transcriptPositions = [:]
        historyGeneration = UUID(); historyOffset = 0; conversations = []
        launcherDraft = AskDraft(); draft = .followUp
        capturing = false; controllingConversationId = nil; onControlChanged?(false); owner = ""
    }

    func prepareLauncher() async {
        guard !Task.isCancelled else { return }
        captureWarning = nil
        if let current = session(), owner != current.owner { resetSession(); owner = current.owner }
        let expectedOwner = owner
        if launcherDraft.text.isEmpty, let cached = try? await cache.draft(key: "launcher", owner: owner) {
            guard !Task.isCancelled, owner == expectedOwner else { return }
            launcherDraft = cached
        }
        guard !Task.isCancelled else { return }
        // Restore an unfinished question without silently replacing its context.
        if !launcherDraft.text.isEmpty { return }
        capturing = true
        let generation = UUID(); captureGeneration = generation
        defer { if generation == captureGeneration { capturing = false } }
        let context = await capture.capture(includeScreenshot: launcherDraft.includeScreenshot)
        guard !Task.isCancelled, generation == captureGeneration else { return }
        launcherDraft.selection = context.selection
        launcherDraft.source = context.source
        launcherDraft.screenshot = context.screenshot
        launcherDraft.capturedAt = context.capturedAt
        captureWarning = context.warning
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
        let launcher = launcherDraft, followUp = draft, id = isLoadingSelection ? nil : selectedId, owner = owner
        if let id, !isLoadingSelection { drafts[id] = followUp }
        draftSave = Task { [cache] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                try await cache.saveDraft(launcher, key: "launcher", owner: owner)
                if let id { try await cache.saveDraft(followUp, key: id, owner: owner) }
            } catch is CancellationError {} catch { self.error = L("ask.cache.failed") }
        }
    }

    func pullToRefreshHistory() async {
        guard !isRefreshingHistory else { return }
        let refreshID = UUID(); pullRefreshID = refreshID
        isRefreshingHistory = true; historyRefreshError = nil; historyErrorTask?.cancel()
        defer { if pullRefreshID == refreshID { isRefreshingHistory = false; pullRefreshID = nil } }
        await refreshHistory(inlineError: true)
        guard pullRefreshID == refreshID else { return }
        if historyRefreshError != nil {
            historyErrorTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.historyRefreshError = nil
            }
        }
    }

    func refreshHistory(loadMore: Bool = false, inlineError: Bool = false) async {
        guard let current = credentials() else { return }
        let generation = UUID(); historyGeneration = generation
        if !loadMore, conversations.isEmpty {
            let cached = (try? await cache.list(owner: current.owner)) ?? []
            guard owner == current.owner, generation == historyGeneration else { return }
            conversations = Self.unique(cached)
        }
        do {
            let offset = loadMore ? historyOffset : 0
            let items = try await api.list(token: current.token, offset: offset)
            guard owner == current.owner, generation == historyGeneration else { return }
            // Retain row positions while reading. Polling must never remove and
            // reinsert the selected row, and pagination uses server rows, not UI count.
            let incoming = Self.unique(items)
            let byId = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })
            var merged = conversations.compactMap { item -> AskConversationSummary? in
                if let updated = byId[item.id] { return updated.updatedAt >= item.updatedAt ? updated : item }
                return loadMore || busyIds.contains(item.id) || pendingSends[item.id] != nil || selectedId == item.id ? item : nil
            }
            let existing = Set(merged.map(\.id))
            merged.append(contentsOf: incoming.filter { !existing.contains($0.id) })
            conversations = Self.unique(merged)
            historyOffset = offset + items.count
            historyHasMore = items.count == 50
        } catch {
            if owner == current.owner, generation == historyGeneration {
                if inlineError { historyRefreshError = L("ask.history.refreshFailed") }
                else { self.error = error.localizedDescription }
            }
        }
    }

    private static func unique(_ items: [AskConversationSummary]) -> [AskConversationSummary] {
        var result: [AskConversationSummary] = []
        for item in items {
            if let index = result.firstIndex(where: { $0.id == item.id }) {
                if result[index].updatedAt < item.updatedAt { result[index] = item }
            } else { result.append(item) }
        }
        return result
    }

    func select(_ rawId: String, reload: Bool = false) async {
        guard let current = credentials() else { return }
        let id = AskConversationID.canonical(rawId)
        if selectedId == id, isLoadingSelection || (!reload && selected != nil && !selectionLoadFailed) { return }
        voiceInput.cancel()
        selectionObservation?.cancel(); selectionObservation = nil
        let generation = UUID(); selectionGeneration = generation
        let oldId = selectedId, oldDraft = draft
        if let oldId, !isLoadingSelection { drafts[oldId] = oldDraft }
        // Commit navigation synchronously, before the first cache/network await.
        selectedId = id; selected = snapshots[id]; isLoadingSelection = true; selectionLoadFailed = false
        draft = drafts[id] ?? .followUp; error = nil; captureWarning = nil
        captureGeneration = UUID(); capturing = false
        if let oldId, let saved = drafts[oldId] { try? await cache.saveDraft(saved, key: oldId, owner: current.owner) }
        let cached = try? await cache.load(id: id, owner: current.owner)
        let savedDraft = try? await cache.draft(key: id, owner: current.owner)
        guard generation == selectionGeneration, owner == current.owner else { return }
        if let cached, (selected?.revision ?? -1) <= cached.revision { selected = cached; snapshots[id] = cached }
        draft = drafts[id] ?? savedDraft ?? .followUp
        do {
            let value = try await api.conversation(id: id, token: current.token)
            guard owner == current.owner else { return }
            let hasUnconfirmedMessage = pendingSends[id].map { pending in !value.messages.contains { $0.id == pending.id } } ?? false
            if !hasUnconfirmedMessage { try await cache.save(value, owner: current.owner) }
            let latest = try await cache.load(id: id, owner: current.owner) ?? value
            guard owner == current.owner else { return }
            if (snapshots[id]?.revision ?? -1) <= latest.revision { snapshots[id] = latest }
            guard generation == selectionGeneration else { return }
            selected = latest; isLoadingSelection = false; error = operationErrors[id]
            // Observe active runs without resuming desktop tools or inference.
            if latest.run?.isActive == true, !busyIds.contains(id) {
                selectionObservation = monitorConversation(id: id, current: current)
            }
            // Loading a conversation never resumes desktop tools automatically.
        } catch {
            if generation == selectionGeneration, owner == current.owner {
                isLoadingSelection = false; selectionLoadFailed = true; self.error = error.localizedDescription
            }
        }
    }

    func retrySelection() {
        guard let id = selectedId else { return }
        Task { await select(id, reload: true) }
    }

    func newConversation() {
        selectionObservation?.cancel(); selectionObservation = nil
        voiceInput.cancel()
        persistDrafts()
        selectionGeneration = UUID(); selected = nil; selectedId = nil
        isLoadingSelection = false; selectionLoadFailed = false
        captureGeneration = UUID(); capturing = false
        draft = AskDraft(); error = nil; captureWarning = nil
    }

    func submitLauncher() {
        guard canSendLauncher else { return }
        submit(launcherDraft, newConversation: true)
    }
    func addReference(_ reference: AskReference) {
        var updated = draft
        updated.references = (updated.references ?? []) + [reference]
        guard updated.referencesWithinLimit else { error = L("ask.input.tooLarge"); return }
        draft = updated
    }

    func submitDraft() {
        guard canSend else { return }
        submit(draft, newConversation: selectedId == nil)
    }

    private func submit(_ submitted: AskDraft, newConversation: Bool) {
        guard submitted.referencesWithinLimit, submitted.text.utf8.count <= 32000, (submitted.selection?.utf8.count ?? 0) <= 64000,
              (submitted.source?.utf8.count ?? 0) <= 1000 else {
            error = L("ask.input.tooLarge"); return
        }
        guard let current = credentials() else { return }
        guard newConversation || selected != nil else { return }
        let id = newConversation ? UUID().uuidString.lowercased() : selected!.id
        guard !busyIds.contains(id) else { return }
        error = nil; operationErrors[id] = nil; busyIds.insert(id)
        if newConversation { tools.bindConversation(id) }
        var value = newConversation ? AskConversation(id: id, title: String(submitted.text.prefix(50)), revision: 0, updatedAt: Date(), messages: []) : selected!
        let messageId = UUID().uuidString
        var request = submitted.request(deviceId: deviceId, tools: [], id: messageId)
        request.modelRef = submitted.modelRef ?? (newConversation ? modelLibrary.defaultReference : (value.modelRef ?? "cloud:default"))
        request.reasoningEffort = reasoningEffort.requestValue(for: request.modelRef.flatMap { modelLibrary.registry.resolve($0)?.1 })
        value.modelRef = request.modelRef
        pendingSends[id] = request
        screenshotConsent[id] = submitted.includeScreenshot ? messageId : nil
        value.messages.append(.init(id: messageId, role: "user", text: request.text, selection: request.selection, source: request.source, image: request.image, createdAt: Date(), reasoningEffort: request.reasoningEffort, references: request.references))
        selectedId = id; selected = value; isLoadingSelection = false; selectionGeneration = UUID(); draft = .followUp
        snapshots[id] = value; selectionLoadFailed = false
        updateSummary(value)
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
                do {
                    try await validateModel(
                        request.modelRef, token: current.token,
                        hasImage: request.image != nil || value.messages.contains(where: { $0.image != nil })
                    )
                } catch {
                    // No message was sent. Restore the editable draft so another model can be selected.
                    guard owner == current.owner else { throw CancellationError() }
                    pendingSends[id] = nil
                    var unsent = value
                    unsent.messages.removeAll { $0.id == messageId }
                    snapshots[id] = unsent
                    drafts[id] = submitted
                    if selectedId == id { selected = unsent; draft = submitted }
                    try await cache.save(unsent, owner: current.owner)
                    throw error
                }
                try Task.checkCancellation()
                pendingSends[id] = request
                let response = try await api.send(conversationId: id, request: request, token: current.token)
                pendingSends[id] = nil
                try await drive(response, current: current, screenshotConsentMessageID: submitted.includeScreenshot ? messageId : nil)
            } catch is CancellationError {} catch { reportOperationError(error, id: id, owner: current.owner) }
        }
    }

    private func validateModel(_ reference: String?, token: String, hasImage: Bool = false) async throws {
        let reference = reference ?? "cloud:default"
        if reference != "cloud:default" {
            let catalog = try await api.models(token: token)
            if reference.hasPrefix("cloud:"),
               !catalog.contains(where: { $0.reference == reference }) {
                throw modelLibrary.unavailable()
            }
        }
        guard let (provider, model) = modelLibrary.registry.resolve(reference) else {
            throw modelLibrary.unavailable()
        }
        if provider.isOllama {
            await modelLibrary.probeOllama()
        }
        if let reason = modelLibrary.selectionReason(model, provider: provider, hasImage: hasImage, loggedIn: true) {
            throw AskLocalError.message(reason)
        }
    }

    func resume() {
        selectionObservation?.cancel(); selectionObservation = nil
        guard let current = credentials(), let value = selected, !busyIds.contains(value.id) else { return }
        let id = value.id
        let retryModelRef = modelReference(launcher: false)
        busyIds.insert(id); error = nil; operationErrors[id] = nil
        let operationId = UUID(); operationIds[id] = operationId
        operations[id] = Task { [weak self] in
            guard let self else { return }; defer { finishOperation(id, operationId: operationId) }
            let monitor = monitorConversation(id: id, current: current)
            defer { monitor.cancel() }
            do {
                _ = await tools.definitions()
                let response: AskConversation
                if let request = pendingSends[id] {
                    try await validateModel(
                        request.modelRef, token: current.token,
                        hasImage: request.image != nil || value.messages.contains(where: { $0.image != nil })
                    )
                    response = try await api.send(conversationId: id, request: request, token: current.token)
                    pendingSends[id] = nil
                } else if value.run == nil, let message = value.messages.last, message.role == "user" {
                    let request = AskSendRequest(id: message.id, deviceId: deviceId, text: message.text,
                                                 selection: message.selection, source: message.source, image: message.image,
                                                 tools: await tools.definitions(), modelRef: value.modelRef, reasoningEffort: message.reasoningEffort, references: message.references)
                    try await validateModel(
                        request.modelRef, token: current.token,
                        hasImage: request.image != nil || value.messages.contains(where: { $0.image != nil })
                    )
                    response = try await api.send(conversationId: id, request: request, token: current.token)
                } else if let run = value.run, ["failed", "cancelled"].contains(run.status) {
                    try await validateModel(
                        retryModelRef, token: current.token,
                        hasImage: value.messages.contains(where: { $0.image != nil })
                    )
                    response = try await api.retry(conversationId: id, runId: run.id, deviceId: deviceId, modelRef: retryModelRef, token: current.token)
                } else {
                    response = try await api.conversation(id: id, token: current.token)
                }
                try await drive(response, current: current, screenshotConsentMessageID: screenshotConsent[id])
            } catch is CancellationError {} catch { reportOperationError(error, id: id, owner: current.owner) }
        }
    }

    private func accept(_ value: AskConversation, owner expectedOwner: String) async throws {
        try Task.checkCancellation()
        guard owner == expectedOwner else { throw CancellationError() }
        if let previous = snapshots[value.id], previous.revision >= value.revision { return }
        // Persist meaningful message/state changes, not every transient preview.
        if snapshots[value.id]?.messages != value.messages || snapshots[value.id]?.run?.status != value.run?.status {
            try await cache.save(value, owner: expectedOwner)
        }
        guard owner == expectedOwner else { throw CancellationError() }
        // A second snapshot delivery or a new optimistic send can arrive while
        // the cache write suspends. Do not overwrite that same-revision draft.
        if let latest = snapshots[value.id], latest.revision >= value.revision { return }
        if (snapshots[value.id]?.revision ?? -1) <= value.revision { snapshots[value.id] = value }
        if selected?.id == value.id, (selected?.revision ?? -1) <= value.revision { selected = value }
        if let inferenceID = progressInferenceIDs[value.id], value.run?.inference?.id != inferenceID {
            inferenceProgress[value.id] = nil; progressInferenceIDs[value.id] = nil
        }
        updateSummary(value)
    }

    private func updateSummary(_ value: AskConversation) {
        let summary = AskConversationSummary(id: value.id, title: value.title, updatedAt: value.updatedAt)
        if let index = conversations.firstIndex(where: { $0.id == value.id }) {
            if conversations[index] != summary, conversations[index].updatedAt <= summary.updatedAt {
                conversations[index] = summary
            }
        } else { conversations.insert(summary, at: 0) }
    }

    private func drive(_ initial: AskConversation, current: (owner: String, token: String),
                       screenshotConsentMessageID: String?) async throws {
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
            if run.status == "waiting_inference", let inference = run.inference {
                guard let reference = run.modelRef,
                      let (provider, model) = modelLibrary.registry.resolve(reference) else {
                    value = try await api.inferenceResult(conversationId: value.id, request: AskInferenceResult(runId: run.id, deviceId: deviceId, inferenceId: inference.id, content: "", failed: true), token: current.token)
                    try await accept(value, owner: current.owner)
                    throw AskLocalError.message(L("ask.models.unavailable"))
                }
                var receipt = inferenceReceipts[inference.id]
                if receipt == nil {
                    do {
                        let hasImage = inference.payload.contains("image_url")
                        if let reason = modelLibrary.selectionReason(
                            model, provider: provider, hasImage: hasImage, loggedIn: true
                        ) {
                            throw AskLocalError.message(reason)
                        }
                        progressInferenceIDs[value.id] = inference.id
                        inferenceProgress[value.id] = AskStreamProgress()
                        let conversationID = value.id
                        let (text, calls) = try await customInference.complete(provider: provider,
                            connection: modelLibrary.connection(provider, model: model), payload: inference.payload,
                            onProgress: { [weak self] progress in
                                await self?.updateInferenceProgress(progress, id: conversationID, inferenceID: inference.id, owner: current.owner, visible: inference.summaryThrough == nil || inference.summaryThrough == 0)
                            })
                        let progress = inferenceProgress[value.id]
                        receipt = AskInferenceResult(runId: run.id, deviceId: deviceId, inferenceId: inference.id, content: text, toolCalls: calls, reasoning: progress?.reasoning, reasoningMilliseconds: progress?.reasoningMilliseconds)
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        let progress = inferenceProgress[value.id]
                        receipt = AskInferenceResult(runId: run.id, deviceId: deviceId, inferenceId: inference.id, content: progress?.text ?? "", failed: true, reasoning: progress?.reasoning, reasoningMilliseconds: progress?.reasoningMilliseconds)
                    }
                    try Task.checkCancellation()
                    guard owner == current.owner else { throw CancellationError() }
                    inferenceReceipts[inference.id] = receipt
                }
                value = try await api.inferenceResult(conversationId: value.id, request: receipt!, token: current.token)
                inferenceReceipts[inference.id] = nil
                continue
            }
            guard let call = run.pending.first else { return }
            let journalKey = run.id + "/" + call.id
            try await cache.associateTool(id: journalKey, conversationId: value.id, owner: current.owner)
            var result = try await cache.toolResult(id: journalKey, owner: current.owner)
            if result == nil {
                // Consent comes from the submitted draft, never from historical images or live UI state.
                let isScreenshot = call.function.name == "computer"
                    && (try? AskLocalTools.arguments(call.function.arguments)["action"] as? String) == "screenshot"
                let approved: Bool
                let screenshotApproved = screenshotConsentMessageID != nil
                    && value.messages.last(where: { $0.role == "user" })?.id == screenshotConsentMessageID
                if screenshotApproved && isScreenshot {
                    approved = true
                } else {
                    pendingApprovals[value.id] = call
                    approved = await withCheckedContinuation { approvals[value.id] = $0 }
                    pendingApprovals[value.id] = nil
                }
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
                var partial: AskInferenceResult?
                if let inference = run.inference, inference.id == progressInferenceIDs[id],
                   let progress = inferenceProgress[id], run.deviceId == deviceId {
                    partial = AskInferenceResult(runId: run.id, deviceId: deviceId, inferenceId: inference.id,
                                                 content: progress.text, reasoning: progress.reasoning,
                                                 reasoningMilliseconds: progress.reasoningMilliseconds)
                }
                let stopped = try await api.cancel(conversationId: id, runId: run.id, partial: partial, token: current.token)
                if owner == current.owner { pendingSends[id] = nil }
                try await accept(stopped, owner: current.owner)
            } catch { reportOperationError(error, id: id, owner: current.owner) }
        }
    }

    func delete(_ id: String) async {
        guard let current = credentials(), !busyIds.contains(id) else { return }
        do {
            try await api.delete(conversationId: id, token: current.token)
            try await cache.delete(id: id, owner: current.owner)
            guard owner == current.owner else { return }
            conversations.removeAll { $0.id == id }
            drafts[id] = nil; snapshots[id] = nil; operationErrors[id] = nil; transcriptPositions[id] = nil
            screenshotConsent[id] = nil
            if selectedId == id { selectedId = nil; newConversation() }
        } catch { self.error = error.localizedDescription }
    }

    private func reportOperationError(_ error: Error, id: String, owner expectedOwner: String) {
        guard owner == expectedOwner else { return }
        operationErrors[id] = error.localizedDescription
        if selectedId == id { self.error = error.localizedDescription }
    }

    private func finishOperation(_ id: String, operationId: UUID) {
        guard operationIds[id] == operationId else { return }
        operationIds[id] = nil
        busyIds.remove(id); operations[id] = nil; pendingApprovals[id] = nil
        if controllingConversationId == id { controllingConversationId = nil; onControlChanged?(false) }
    }

    private func updateInferenceProgress(_ progress: AskStreamProgress, id: String, inferenceID: String, owner expectedOwner: String, visible: Bool) {
        guard owner == expectedOwner, progressInferenceIDs[id] == inferenceID, visible else { return }
        inferenceProgress[id] = progress
    }

    private func monitorConversation(id: String, current: (owner: String, token: String)) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let self, owner == current.owner else { return }
                    try await api.observe(id: id, token: current.token) { [weak self] value in
                        guard let self else { throw CancellationError() }
                        try await self.acceptObserved(value, current: current)
                    }
                } catch is CancellationError { return }
                catch {
                    // Compatibility with an older server, and recovery after transport loss.
                    if let self, let value = try? await api.conversation(id: id, token: current.token) {
                        try? await acceptObserved(value, current: current)
                    }
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func acceptObserved(_ value: AskConversation, current: (owner: String, token: String)) async throws {
        guard owner == current.owner else { throw CancellationError() }
        if let pending = pendingSends[value.id], !value.messages.contains(where: { $0.id == pending.id }) { return }
        try await accept(value, owner: current.owner)
        if value.run?.isActive == false {
            approve(conversationId: value.id, allowed: false)
            throw CancellationError()
        }
    }
}
