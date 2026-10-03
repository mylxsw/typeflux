import AppKit
import Combine

@MainActor
final class AskConversationModel: ObservableObject {
    func usagePage(id: String, runId: String?, cursor: Int64?) async throws -> AskUsagePage {
        guard let current = credentials() else { throw AuthError.unauthorized }
        let page = try await api.usage(id: id, runId: runId, cursor: cursor, token: current.token)
        try Task.checkCancellation()
        guard owner == current.owner else { throw CancellationError() }
        return page
    }

    var usageContext: AskContextUsage? {
        guard var context = selected?.contextUsage else { return nil }
        let ref = modelReference(launcher: false)
        if ref != context.modelRef {
            context.modelRef = ref
            let entry = modelLibrary.registry.resolve(ref)?.1
            context.capacity = entry?.contextWindowTokens
            context.outputReserve = min(4096, entry?.maxOutputTokens ?? 4096)
        }
        return context
    }

    let voiceInput = AskVoiceInput()
    @Published var reasoningEffort: AskReasoningEffort = .providerDefault
    let modelLibrary: AskModelLibrary
    private var inferenceUsage: [String: AskTokenUsage] = [:]
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
        let reference = launcher
            ? launcherDraft.modelRef ?? modelLibrary.defaultReference
            : draft.modelRef ?? selected.map { $0.modelRef ?? "cloud:default" } ?? modelLibrary.defaultReference
        return localFallback(reference, hasImage: requiresVision(launcher: launcher))
    }

    /// Local conversations run on the user's own models; a Cloud reference falls back to the first one available.
    func localFallback(_ reference: String, hasImage: Bool) -> String {
        guard !cloudAvailable, reference.hasPrefix("cloud:") else { return reference }
        return modelLibrary.firstLocalReference(hasImage: hasImage)
            ?? modelLibrary.firstLocalReference(hasImage: hasImage, confirmedVision: false) ?? reference
    }

    /// False when Ask runs on this Mac: not signed in, or local mode is on.
    var cloudAvailable: Bool { session().map { !$0.token.isEmpty } ?? false }
    func requiresVision(launcher: Bool) -> Bool {
        let current = launcher ? launcherDraft : draft
        return (current.includeScreenshot && current.screenshot != nil)
            || (!launcher && selected?.messages.contains(where: { $0.image != nil }) == true)
    }

    @Published var referenceLocation: String?
    @Published var launcherDraft = AskDraft() {
        didSet {
            if launcherDraft.includeScreenshot, !screenshotCapability(launcher: true).canAttach {
                launcherDraft.includeScreenshot = false
            }
        }
    }
    @Published var draft = AskDraft.followUp {
        didSet {
            if !isLoadingSelection, draft.includeScreenshot, !screenshotCapability(launcher: false).canAttach {
                draft.includeScreenshot = false
            }
        }
    }
    @Published var launcherScreenshotNotice: String?
    /// A local conversation that moved to a vision model; the banner offers the way back.
    @Published var visionSwitch: AskVisionSwitch?
    /// Drafts whose user switched back, so they are not switched again.
    var visionSwitchDeclined: Set<String> = []
    @Published var screenshotNotice: String?
    @Published private(set) var recoveringImages: [String: AskImageRecoveryTarget] = [:]
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
    /// Follow-ups typed while a conversation was working, sent in order afterwards.
    @Published private(set) var sendQueue = AskSendQueue()
    /// Queued messages being handed to a running run.
    @Published private(set) var steeringIds: Set<String> = []
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
    var onOpenSettings: ((StudioSection) -> Void)?
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
    /// Approvals the user extended to a whole conversation: tool name to the highest
    /// risk allowed. Memory only, so grants end with the app session or account.
    private var toolGrants: [String: [String: AskToolRisk]] = [:]
    private var operationErrors: [String: String] = [:]
    private var pendingSends: [String: AskSendRequest] = [:]
    // Local consent for the latest submission, retained for retries but never restored from history.
    private var screenshotConsent: [String: String] = [:]
    private var captureGeneration = UUID()
    private var selectionGeneration = UUID()
    private var selectionObservation: Task<Void, Never>?
    private var draftSave: Task<Void, Never>?
    private var draftSaveConversationID: String?
    private var deletedConversationIDs: Set<String> = []
    private var authObserver: AnyCancellable?
    private var modelObserver: AnyCancellable?
    private var memoryObserver: AnyCancellable?
    private let defaults: UserDefaults
    private var memoryPurgeTask: Task<Void, Never>?
    private var memoryPurgeGeneration = 0
    static let memoryPurgePendingKey = "ask.memory.purgePending"

    init(api: any AskAPI, cache: any AskCaching, tools: any AskToolExecuting,
         capture: any AskContextCapturing, deviceId: String, modelLibrary: AskModelLibrary? = nil,
         defaults: UserDefaults = .standard,
         session: @escaping () -> (owner: String, token: String)?) {
        self.modelLibrary = modelLibrary ?? .shared
        self.api = api; self.cache = cache; self.tools = tools; self.capture = capture
        self.deviceId = deviceId; self.session = session; self.defaults = defaults
        normalizeScreenshotChoices()
        modelObserver = self.modelLibrary.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                normalizeScreenshotChoices()
                objectWillChange.send()
            }
        }
        authObserver = NotificationCenter.default.publisher(for: .authDidLogout).sink { [weak self] _ in
            Task { @MainActor in self?.resetSession() }
        }
        memoryObserver = NotificationCenter.default.publisher(for: .askMemoryDidClear).sink { [weak self] _ in
            Task { @MainActor in self?.clearMemory() }
        }
    }

    /// Drops captured memory and removes the copies pinned to server conversations.
    /// The purge stays pending across launches until the server confirms it.
    func clearMemory() {
        if launcherDraft.memory != nil { launcherDraft.memory = AskMemory() }
        if draft.memory != nil { draft.memory = AskMemory() }
        for (id, value) in drafts where value.memory != nil { drafts[id]?.memory = AskMemory() }
        for (id, value) in snapshots where value.memory != nil { snapshots[id]?.memory = nil }
        selected?.memory = nil
        memoryPurgeGeneration += 1
        defaults.set(true, forKey: Self.memoryPurgePendingKey)
        persistDrafts()
        flushMemoryPurge()
    }

    /// Retries a pending purge; it runs whenever the user is signed in. A clear
    /// that happens while a purge is in flight triggers one more purge afterwards.
    func flushMemoryPurge() {
        guard memoryPurgeTask == nil, defaults.bool(forKey: Self.memoryPurgePendingKey),
              let current = session() else { return }
        let generation = memoryPurgeGeneration
        memoryPurgeTask = Task { [weak self, api] in
            var purged = false
            do {
                try await api.purgeMemory(token: current.token)
                purged = true
            } catch {
                NetworkDebugLogger.logMessage("[Ask Memory] purge failed: \(error.localizedDescription)")
            }
            guard let self else { return }
            memoryPurgeTask = nil
            // A local session cleared its own copies; Cloud copies still need the next signed-in purge.
            guard purged, !current.token.isEmpty else { return }
            if memoryPurgeGeneration == generation {
                defaults.set(false, forKey: Self.memoryPurgePendingKey)
            } else {
                flushMemoryPurge()
            }
        }
    }

    /// Waits for an in-flight purge. Used by tests and before sensitive transitions.
    func waitForMemoryPurge() async {
        await memoryPurgeTask?.value
    }

    var isBusy: Bool { selected.map { busyIds.contains($0.id) || $0.run?.isActive == true } ?? false }
    var hasPendingSubmission: Bool { selectedId.map { pendingSends[$0] != nil } ?? false }
    var canSend: Bool { canSendNow || canQueue || (isEditingQueued && draft.canSend) }
    private var canSendNow: Bool { !isLoadingSelection && (selectedId == nil || selected != nil) && draft.canSend && !isBusy && (selected.map { pendingSends[$0.id] == nil && !($0.run == nil && $0.messages.last?.role == "user") } ?? true) && !capturing && !recordingIsActive() && !voiceInput.isOccupied }
    /// A busy conversation takes the follow-up into its queue instead.
    var canQueue: Bool {
        guard let value = selected, !isLoadingSelection, isBusy, !isEditingQueued else { return false }
        return draft.canSend && sendQueue.canEnqueue(value.id) && !capturing && !recordingIsActive() && !voiceInput.isOccupied
    }
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
        approvals.values.forEach { $0.resume(returning: false) }; approvals = [:]; toolGrants = [:]
        inferenceReceipts = [:]; inferenceUsage = [:]
        pendingApprovals = [:]; busyIds = []; pendingSends = [:]; operationErrors = [:]
        sendQueue = AskSendQueue(); steeringIds = []
        screenshotConsent = [:]
        draftSave?.cancel(); draftSaveConversationID = nil; deletedConversationIDs = []; captureGeneration = UUID(); selectionGeneration = UUID()
        selectionObservation?.cancel(); selectionObservation = nil
        inferenceProgress = [:]; progressInferenceIDs = [:]
        selected = nil; selectedId = nil; isLoadingSelection = false; selectionLoadFailed = false
        snapshots = [:]; drafts = [:]; transcriptPositions = [:]
        historyGeneration = UUID(); historyOffset = 0; conversations = []
        launcherScreenshotNotice = nil; screenshotNotice = nil; recoveringImages = [:]
        launcherDraft = AskDraft(); draft = .followUp
        capturing = false; controllingConversationId = nil; onControlChanged?(false); owner = ""
    }

    func makeLauncherSelectionRequest() -> ReadOnlySelectionRequest { capture.makeSelectionRequest() }

    func prepareLauncher(request: ReadOnlySelectionRequest? = nil) async {
        let request = request ?? makeLauncherSelectionRequest()
        guard !Task.isCancelled else { return }
        flushMemoryPurge()
        captureWarning = nil
        normalizeScreenshotChoices()
        if let current = session(), owner != current.owner { resetSession(); owner = current.owner }
        let expectedOwner = owner
        let typedBefore = !launcherDraft.text.isEmpty
        var restored = false
        if !typedBefore, let cached = try? await cache.draft(key: "launcher", owner: owner) {
            guard !Task.isCancelled, owner == expectedOwner else { return }
            // The panel is already open: never replace anything typed meanwhile.
            if launcherDraft.text.isEmpty, !cached.text.isEmpty { launcherDraft = cached; restored = true }
        }
        guard !Task.isCancelled else { return }
        // Restore an unfinished question without silently replacing its context.
        // Text typed into the just-opened panel still gets this launch's context.
        if typedBefore || restored { return }
        capturing = true
        let generation = UUID(); captureGeneration = generation
        defer { if generation == captureGeneration { capturing = false } }
        let context = await capture.capture(includeScreenshot: launcherDraft.includeScreenshot, includeSelection: true, request: request)
        guard !Task.isCancelled, generation == captureGeneration else { return }
        launcherDraft.selection = context.selection
        launcherDraft.selectionOff = nil
        launcherDraft.source = context.source
        launcherDraft.sourceBundleID = context.sourceBundleID
        launcherDraft.screenshot = context.screenshot
        launcherDraft.capturedAt = context.capturedAt
        launcherDraft.memory = context.memory ?? AskMemory()
        launcherDraft.memoryOff = nil
        captureWarning = context.warning
        persistDrafts()
    }

    func refreshScreenshot(launcher: Bool) async {
        guard screenshotCapability(launcher: launcher).canAttach else { return }
        let generation = UUID(); captureGeneration = generation; capturing = true
        let selectedId = selected?.id
        let context = await capture.capture(includeScreenshot: true, includeSelection: false)
        guard captureGeneration == generation else { return }
        defer { capturing = false }
        if launcher { launcherDraft.screenshot = context.screenshot; launcherDraft.capturedAt = context.capturedAt }
        else if selected?.id == selectedId { draft.screenshot = context.screenshot; draft.capturedAt = context.capturedAt }
        captureWarning = context.warning; persistDrafts()
    }

    func persistDrafts() {
        draftSave?.cancel()
        // While a queued message is open in the composer, the conversation's own draft is the stash.
        let editing = sendQueue.editing.flatMap { $0.conversationId == selectedId ? $0.stash : nil }
        let launcher = launcherDraft, followUp = editing ?? draft, owner = owner
        let id = isLoadingSelection ? nil : selectedId.flatMap { deletedConversationIDs.contains($0) ? nil : $0 }
        if let id, !isLoadingSelection { drafts[id] = followUp }
        draftSaveConversationID = id
        draftSave = Task { [cache] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                try await cache.saveDraft(launcher, key: "launcher", owner: owner)
                try Task.checkCancellation()
                if let id, self.owner == owner, !deletedConversationIDs.contains(id) {
                    try await cache.saveDraft(followUp, key: id, owner: owner)
                }
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
        cancelQueuedEdit(advancing: false)
        selectionObservation?.cancel(); selectionObservation = nil
        let generation = UUID(); selectionGeneration = generation
        let oldId = selectedId, oldDraft = draft
        if let oldId, !isLoadingSelection { drafts[oldId] = oldDraft }
        // Commit navigation synchronously, before the first cache/network await.
        selectedId = id; selected = snapshots[id]; isLoadingSelection = true; selectionLoadFailed = false
        draft = drafts[id] ?? .followUp; error = nil; captureWarning = nil; screenshotNotice = nil; visionSwitch = nil
        captureGeneration = UUID(); capturing = false
        if let oldId, !deletedConversationIDs.contains(oldId), let saved = drafts[oldId] { try? await cache.saveDraft(saved, key: oldId, owner: current.owner) }
        let cached = try? await cache.load(id: id, owner: current.owner)
        let savedDraft = try? await cache.draft(key: id, owner: current.owner)
        guard generation == selectionGeneration, owner == current.owner else { return }
        if let cached {
            let merged = snapshots[id]?.reconciling(cached) ?? cached
            selected = merged; snapshots[id] = merged
        }
        draft = drafts[id] ?? savedDraft ?? .followUp
        do {
            let value = try await api.conversation(id: id, token: current.token)
            guard owner == current.owner else { return }
            let hasUnconfirmedMessage = pendingSends[id].map { pending in !value.messages.contains { $0.id == pending.id } } ?? false
            if !hasUnconfirmedMessage { try await cache.save(value, owner: current.owner) }
            let latest = try await cache.load(id: id, owner: current.owner) ?? value
            guard owner == current.owner else { return }
            snapshots[id] = snapshots[id]?.reconciling(latest) ?? latest
            guard generation == selectionGeneration else { return }
            selected = snapshots[id] ?? latest; isLoadingSelection = false
            switchToVisionModelIfNeeded(launcher: false); normalizeScreenshotChoices(); error = operationErrors[id]
            queueDidSettle(id)
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
        cancelQueuedEdit(advancing: false)
        persistDrafts()
        selectionGeneration = UUID(); selected = nil; selectedId = nil
        isLoadingSelection = false; selectionLoadFailed = false
        captureGeneration = UUID(); capturing = false
        draft = AskDraft(); error = nil; captureWarning = nil; screenshotNotice = nil; visionSwitch = nil
        // No source app is trustworthy here, so only global memory applies.
        draft.memory = capture.globalMemory() ?? AskMemory()
    }

    func submitLauncher() {
        normalizeScreenshotChoices()
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
        normalizeScreenshotChoices()
        if isEditingQueued { saveQueuedEdit(); return }
        if canQueue, let id = selected?.id {
            sendQueue.enqueue(draft, to: id)
            draft = .followUp; persistDrafts()
            return
        }
        guard canSendNow else { return }
        submit(draft, newConversation: selectedId == nil)
    }

    /// `messageId` keeps a queued message's ID; `clearsDraft` is false when the queue
    /// sends on its own, so whatever the user is typing stays in the composer.
    private func submit(_ submitted: AskDraft, newConversation: Bool, messageId queuedId: String? = nil, clearsDraft: Bool = true) {
        guard submitted.referencesWithinLimit, submitted.text.utf8.count <= 32000,
              (submitted.sentSelection?.utf8.count ?? 0) <= 64000,
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
        let messageId = queuedId ?? UUID().uuidString
        var request = submitted.request(deviceId: deviceId, tools: [], id: messageId)
        request.modelRef = localFallback(submitted.modelRef ?? (newConversation ? modelLibrary.defaultReference : (value.modelRef ?? "cloud:default")),
                                         hasImage: request.image != nil || value.messages.contains { $0.image != nil })
        request.reasoningEffort = reasoningEffort.requestValue(for: request.modelRef.flatMap { modelLibrary.registry.resolve($0)?.1 })
        request.memory = newConversation && submitted.memoryOff != true
            ? Self.openingMemory(submitted.memory ?? capture.globalMemory()) : nil
        value.modelRef = request.modelRef
        Self.applyMemoryChoice(submitted, newConversation: newConversation, request: &request, conversation: &value)
        pendingSends[id] = request
        screenshotConsent[id] = submitted.includeScreenshot ? messageId : nil
        value.messages.append(.init(id: messageId, role: "user", text: request.text, selection: request.selection, source: request.source, image: request.image, createdAt: Date(), reasoningEffort: request.reasoningEffort, references: request.references))
        selectedId = id; selected = value; isLoadingSelection = false; selectionGeneration = UUID()
        if clearsDraft { draft = .followUp }
        snapshots[id] = value; selectionLoadFailed = false
        updateSummary(value)
        if newConversation { launcherDraft = AskDraft() }
        // A queued message sending on its own must not bring the window forward.
        if clearsDraft { onShowConversation?() }
        persistDrafts()
        let operationId = UUID(); operationIds[id] = operationId
        operations[id] = Task { [weak self] in
            guard let self else { return }
            defer { finishOperation(id, operationId: operationId) }
            let monitor = monitorConversation(id: id, current: current)
            defer { monitor.cancel() }
            do {
                try await cache.save(value, owner: current.owner)
                var request = request
                request.tools = await tools.definitions(conversationId: id)
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
                    if let queuedId {
                        // The queued message goes back first and waits for the user.
                        sendQueue.putFirst(AskQueuedMessage(id: queuedId, draft: submitted), in: id)
                        sendQueue.pause(id)
                        if selectedId == id { selected = unsent }
                    } else {
                        drafts[id] = submitted
                        if selectedId == id { selected = unsent; draft = submitted }
                    }
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

    /// The server pins memory from the opening message only; empty memory is not sent.
    static func openingMemory(_ memory: AskMemory?) -> AskMemory? {
        guard let memory, !memory.isEmpty else { return nil }
        return memory
    }

    private func validateModel(_ reference: String?, token: String, hasImage: Bool = false) async throws {
        let reference = reference ?? "cloud:default"
        if token.isEmpty, reference.hasPrefix("cloud:") { throw AskLocalError.message(L("ask.local.modelRequired")) }
        if reference.hasPrefix("cloud:"), reference != "cloud:default" {
            let catalog = try await api.models(token: token)
            try Task.checkCancellation()
            try modelLibrary.replaceCloudModels(catalog)
        }
        guard let (provider, model) = modelLibrary.registry.resolve(reference) else {
            throw modelLibrary.unavailable()
        }
        if provider.isOllama {
            await modelLibrary.probeOllama()
        }
        if let reason = modelLibrary.selectionReason(model, provider: provider, hasImage: hasImage, loggedIn: !token.isEmpty) {
            throw AskLocalError.message(reason)
        }
    }

    func refreshImageModels() async {
        // The Cloud catalog only refreshes for Cloud sessions; local mode keeps it untouched.
        guard let current = session(), !current.token.isEmpty else { return }
        await modelLibrary.refresh(api: api, token: current.token)
        guard !Task.isCancelled else { return }
        await modelLibrary.probeOllama()
    }

    func resume() {
        selectionObservation?.cancel(); selectionObservation = nil
        guard let current = credentials(), let value = selected, !busyIds.contains(value.id) else { return }
        let id = value.id
        let retryModelRef = modelReference(launcher: false)
        if pendingSends[id] == nil, let run = value.run, ["failed", "cancelled"].contains(run.status),
           value.messages.contains(where: { $0.image != nil }) {
            guard canResumeImage else {
                error = screenshotCapability(launcher: false).hint ?? L("ask.models.unavailable")
                return
            }
            if let target = imageRecoveryTarget { recoveringImages[id] = target }
        }
        busyIds.insert(id); error = nil; operationErrors[id] = nil
        let operationId = UUID(); operationIds[id] = operationId
        operations[id] = Task { [weak self] in
            guard let self else { return }; defer { finishOperation(id, operationId: operationId) }
            let monitor = monitorConversation(id: id, current: current)
            defer { monitor.cancel() }
            do {
                _ = await tools.definitions(conversationId: id)
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
                                                 tools: await tools.definitions(conversationId: id), modelRef: value.modelRef, reasoningEffort: message.reasoningEffort, references: message.references)
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

    /// Only the latest reply can be regenerated: the server rewinds the whole
    /// turn that produced it, so an older answer could not be replaced without
    /// silently discarding the turns that follow it.
    var regenerableAnswerId: String? {
        guard let value = selected, !isLoadingSelection, !isBusy else { return nil }
        guard pendingSends[value.id] == nil, value.run?.isActive != true else { return nil }
        guard value.messages.last?.role != "user" else { return nil }
        guard let answer = value.messages.last(where: { $0.role == "assistant" }), !answer.text.isEmpty else { return nil }
        return answer.id
    }

    func canRegenerate(_ message: AskMessage) -> Bool {
        message.role == "assistant" && !message.text.isEmpty && regenerableAnswerId == message.id
    }

    /// Answer the same question again in place. Sending it as a new message
    /// would duplicate the question in the transcript and pay for the extra turn.
    func regenerate(_ messageId: String) {
        selectionObservation?.cancel(); selectionObservation = nil
        guard let current = credentials(), let value = selected, !busyIds.contains(value.id) else { return }
        let id = value.id
        let modelRef = modelReference(launcher: false)
        busyIds.insert(id); error = nil; operationErrors[id] = nil
        let operationId = UUID(); operationIds[id] = operationId
        operations[id] = Task { [weak self] in
            guard let self else { return }
            defer { finishOperation(id, operationId: operationId) }
            let monitor = monitorConversation(id: id, current: current)
            defer { monitor.cancel() }
            do {
                let definitions = await tools.definitions(conversationId: id)
                try await validateModel(
                    modelRef, token: current.token,
                    hasImage: value.messages.contains(where: { $0.image != nil })
                )
                let request = AskRegenerateRequest(messageId: messageId, deviceId: deviceId,
                                                   modelRef: modelRef, tools: definitions)
                let response = try await api.regenerate(conversationId: id, request: request, token: current.token)
                try await drive(response, current: current, screenshotConsentMessageID: screenshotConsent[id])
            } catch is CancellationError {} catch { reportOperationError(error, id: id, owner: current.owner) }
        }
    }

    private func accept(_ value: AskConversation, owner expectedOwner: String) async throws {
        try Task.checkCancellation()
        guard owner == expectedOwner else { throw CancellationError() }
        if let previous = snapshots[value.id], !value.isNewer(than: previous) { return }
        var value = snapshots[value.id]?.reconciling(value, preservingEqualRevisionContent: true) ?? value
        // Persist meaningful message/state changes, not every transient preview.
        if snapshots[value.id]?.messages != value.messages || snapshots[value.id]?.run?.status != value.run?.status || snapshots[value.id]?.usage != value.usage {
            try await cache.save(value, owner: expectedOwner)
        }
        guard owner == expectedOwner else { throw CancellationError() }
        // Recheck after the cache write: another delivery or optimistic send
        // may have advanced the state while this task was suspended.
        if let latest = snapshots[value.id], !value.isNewer(than: latest) { return }
        value = snapshots[value.id]?.reconciling(value, preservingEqualRevisionContent: true) ?? value
        snapshots[value.id] = value
        if selected?.id == value.id { selected = selected?.reconciling(value, preservingEqualRevisionContent: true) ?? value }
        if let inferenceID = progressInferenceIDs[value.id], value.run?.inference?.id != inferenceID {
            inferenceProgress[value.id] = nil; progressInferenceIDs[value.id] = nil
        }
        updateSummary(value)
        if value.run?.isActive == false, sendQueue.messages(value.id).isEmpty == false || sendQueue.steeredMessages(value.id).isEmpty == false {
            queueDidSettle(value.id)
        } else {
            sendQueue.noteSettled(value.id, run: value.run)
        }
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
                            model, provider: provider, hasImage: hasImage, loggedIn: !current.token.isEmpty
                        ) {
                            throw AskLocalError.message(reason)
                        }
                        progressInferenceIDs[value.id] = inference.id
                        inferenceProgress[value.id] = AskStreamProgress()
                        let conversationID = value.id
                        let (text, calls) = try await customInference.complete(provider: provider,
                            connection: modelLibrary.connection(provider, model: model), payload: inference.payload,
                            onUsage: { [weak self] usage in await self?.recordInferenceUsage(usage, id: inference.id, owner: current.owner) },
                            onProgress: { [weak self] progress in
                                await self?.updateInferenceProgress(progress, id: conversationID, inferenceID: inference.id, owner: current.owner, visible: inference.summaryThrough == nil || inference.summaryThrough == 0)
                            })
                        let progress = inferenceProgress[value.id]
                        receipt = AskInferenceResult(runId: run.id, deviceId: deviceId, inferenceId: inference.id, content: text, toolCalls: calls, usage: inferenceUsage[inference.id], reasoning: progress?.reasoning, reasoningMilliseconds: progress?.reasoningMilliseconds,
                                                     finishReason: progress?.truncated == true ? "length" : nil)
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        let progress = inferenceProgress[value.id]
                        receipt = AskInferenceResult(runId: run.id, deviceId: deviceId, inferenceId: inference.id, content: progress?.text ?? "", usage: inferenceUsage[inference.id], failed: true, reasoning: progress?.reasoning, reasoningMilliseconds: progress?.reasoningMilliseconds)
                    }
                    try Task.checkCancellation()
                    guard owner == current.owner else { throw CancellationError() }
                    inferenceReceipts[inference.id] = receipt
                }
                value = try await api.inferenceResult(conversationId: value.id, request: receipt!, token: current.token)
                inferenceReceipts[inference.id] = nil; inferenceUsage[inference.id] = nil
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
                } else if isGranted(call, conversationId: value.id) {
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
                        result?.content = output.content; result?.image = output.image; result?.isError = output.isError
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

    func isGranted(_ call: AskToolCall, conversationId: String) -> Bool {
        let risk = tools.risk(of: call)
        if risk == .none { return true }
        guard risk < .destructive, let granted = toolGrants[conversationId]?[call.function.name] else { return false }
        return risk <= granted
    }

    /// The risk tier of the call waiting for approval.
    func approvalRisk(_ conversationId: String) -> AskToolRisk? {
        pendingApprovals[conversationId].map { tools.risk(of: $0) }
    }

    func mcpServerName(of call: AskToolCall) -> String? { tools.mcpServerName(of: call) }

    /// Destructive calls can only be allowed once.
    func canAllowForConversation(_ conversationId: String) -> Bool {
        pendingApprovals[conversationId].map { tools.risk(of: $0) < .destructive } ?? false
    }

    /// Allows the pending call and later calls of the same tool at the same or lower risk.
    func approveForConversation(_ conversationId: String) {
        guard let call = pendingApprovals[conversationId] else { return }
        let risk = tools.risk(of: call)
        guard risk < .destructive else { return }
        let name = call.function.name
        toolGrants[conversationId, default: [:]][name] = max(risk, toolGrants[conversationId]?[name] ?? .read)
        approve(conversationId: conversationId, allowed: true)
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
                                                 content: progress.text, usage: inferenceUsage[inference.id], reasoning: progress.reasoning,
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
            guard owner == current.owner else { return }
            deletedConversationIDs.insert(id)
            // Drain a writer already inside the cache before deleting its draft.
            // New writers check the tombstone immediately before saving.
            if draftSaveConversationID == id {
                let pendingSave = draftSave
                pendingSave?.cancel()
                await pendingSave?.value
            }
            try await cache.delete(id: id, owner: current.owner)
            guard owner == current.owner else { return }
            conversations.removeAll { $0.id == id }
            drafts[id] = nil; snapshots[id] = nil; operationErrors[id] = nil; transcriptPositions[id] = nil
            sendQueue.clear(id)
            screenshotConsent[id] = nil; toolGrants[id] = nil
            if selectedId == id { selectedId = nil; newConversation() }
            else { persistDrafts() }
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
        recoveringImages[id] = nil
        if controllingConversationId == id { controllingConversationId = nil; onControlChanged?(false) }
        queueDidSettle(id)
    }

    private func recordInferenceUsage(_ usage: AskTokenUsage, id: String, owner expectedOwner: String) {
        guard owner == expectedOwner else { return }
        inferenceUsage[id] = usage
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

// MARK: - Send queue

extension AskConversationModel {
    var isEditingQueued: Bool { sendQueue.editing != nil && sendQueue.editing?.conversationId == selectedId }

    /// Messages the selected conversation has queued.
    var queuedMessages: [AskQueuedMessage] { selectedId.map { sendQueue.messages($0) } ?? [] }

    /// Messages sent into the running run that it has not read yet.
    var steeredMessages: [AskQueuedMessage] {
        guard let value = selected else { return [] }
        return sendQueue.steeredMessages(value.id).filter { item in !value.messages.contains { $0.id == item.id } }
    }

    var isQueuePaused: Bool { selectedId.map { sendQueue.isPaused($0) } ?? false }

    /// "Jump the queue" needs a run that is still working.
    var canSteer: Bool { selected?.run?.isActive == true && !isLoadingSelection }

    func removeQueued(_ itemId: String) {
        guard let id = selectedId else { return }
        if sendQueue.isEditing(id, itemId: itemId) { cancelQueuedEdit() }
        sendQueue.remove(itemId, from: id)
    }

    func clearQueue() {
        guard let id = selectedId else { return }
        cancelQueuedEdit(advancing: false)
        sendQueue.clear(id)
    }

    func resumeQueue() {
        guard let id = selectedId else { return }
        sendQueue.resume(id)
        queueDidSettle(id)
    }

    /// Opens a queued message in the composer; what the user was typing is set aside.
    func editQueued(_ itemId: String) {
        guard let id = selectedId, let item = sendQueue.messages(id).first(where: { $0.id == itemId }) else { return }
        if isEditingQueued { saveQueuedEdit(advancing: false) }
        sendQueue.editing = .init(conversationId: id, itemId: itemId, stash: draft)
        draft = item.draft
    }

    func saveQueuedEdit(advancing: Bool = true) {
        guard let editing = sendQueue.editing else { return }
        normalizeScreenshotChoices()
        sendQueue.update(editing.itemId, in: editing.conversationId, draft: draft)
        sendQueue.editing = nil
        if selectedId == editing.conversationId { draft = editing.stash }
        persistDrafts()
        if advancing { queueDidSettle(editing.conversationId) }
    }

    func cancelQueuedEdit(advancing: Bool = true) {
        guard let editing = sendQueue.editing else { return }
        sendQueue.editing = nil
        if selectedId == editing.conversationId { draft = editing.stash }
        if advancing { queueDidSettle(editing.conversationId) }
    }

    /// Hands a queued message to the running run, which reads it at its next step.
    /// A run that already ended gets it as the next turn instead.
    func steerQueued(_ itemId: String) {
        guard let current = credentials(), let value = selected, let run = value.run, run.isActive,
              !steeringIds.contains(itemId), sendQueue.messages(value.id).contains(where: { $0.id == itemId }) else { return }
        if sendQueue.isEditing(value.id, itemId: itemId) { saveQueuedEdit(advancing: false) }
        guard let latest = sendQueue.messages(value.id).first(where: { $0.id == itemId }) else { return }
        let id = value.id
        steeringIds.insert(itemId)
        let request = AskSteerRequest(runId: run.id, message: latest.draft.request(deviceId: deviceId, tools: [], id: latest.id))
        Task { [weak self] in
            guard let self else { return }
            defer { steeringIds.remove(itemId) }
            do {
                let response = try await api.steer(conversationId: id, request: request, token: current.token)
                guard owner == current.owner else { return }
                sendQueue.markSteered(latest, in: id)
                try await accept(response, owner: current.owner)
            } catch {
                guard owner == current.owner else { return }
                // The run ended first: send it ahead of the rest of the queue.
                let refreshed = try? await api.conversation(id: id, token: current.token)
                guard owner == current.owner else { return }
                if let refreshed, refreshed.run?.isActive != true {
                    sendQueue.putFirst(latest, in: id)
                    sendQueue.resume(id)
                    try? await accept(refreshed, owner: current.owner)
                    queueDidSettle(id)
                } else {
                    reportOperationError(error, id: id, owner: current.owner)
                }
            }
        }
    }

    /// Called whenever a conversation may have gone idle: settles jumped messages,
    /// pauses after a failed or stopped run, and otherwise sends the next queued message.
    func queueDidSettle(_ id: String) {
        guard let value = snapshots[id] ?? (selected?.id == id ? selected : nil) else { return }
        sendQueue.reconcile(id, transcript: value.messages, run: value.run)
        guard selectedId == id, selected != nil, !isLoadingSelection, !busyIds.contains(id), pendingSends[id] == nil,
              value.run?.isActive != true, let next = sendQueue.next(for: id), !steeringIds.contains(next.id),
              let item = sendQueue.take(next.id, from: id) else { return }
        submit(item.draft, newConversation: false, messageId: item.id, clearsDraft: false)
    }
}

