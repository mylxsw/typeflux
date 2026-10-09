import AppKit
import Combine

@MainActor
final class AskConversationModel: ObservableObject {
    func usagePage(id: String, runId: String?, cursor: Int64?) async throws -> AskUsagePage {
        guard let current = credentials(for: id) else { throw AuthError.unauthorized }
        let page = try await api.usage(id: id, runId: runId, cursor: cursor, token: current.token)
        try Task.checkCancellation()
        guard owner == current.account else { throw CancellationError() }
        return page
    }

    var hasUsageRecords: Bool {
        guard let selected else { return false }
        return selected.run != nil || (selected.usage?.total.calls ?? 0) > 0
            || selected.messages.contains { $0.runId != nil }
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
    /// Applications the launcher can open; tests supply their own list.
    let quickSearch = AskQuickSearchSession()
    var appIndex: any AskAppSearching = AskAppIndex.shared
    /// Files and folders the launcher can open; tests supply their own.
    var fileIndex: any AskFileSearching = AskFileIndex.shared
    /// Whether a found file is still there; tests decide instead.
    var fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    /// Opens a file in a given application; tests record it instead.
    var openFileWith: (URL, URL) -> Void = { file, application in
        NSWorkspace.shared.open([file], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
    }
    /// Moves a file to the Trash; false when it could not. Tests record it instead.
    var trashFile: (URL) -> Bool = { url in (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil }
    /// Opens an application chosen in the launcher; tests record it instead.
    var openApplication: (URL) -> Void = { url in
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
    /// Opens links, such as a launcher web search; tests record them instead.
    var openURL: (URL) -> Void = { url in NSWorkspace.shared.open(url) }
    /// Opens a workflow in the workflow editor; tests record it instead.
    var editWorkflow: @MainActor (String, String?, Int?) -> Void = { id, path, line in
        AskWorkflowEditorWindowController.shared.show(workflowID: id, path: path, line: line)
    }
    /// Opens the workflow editor and asks its assistant to fix a failed run.
    var fixWorkflow: @MainActor (String, String, String) -> Void = { id, query, error in
        AskWorkflowEditorWindowController.shared.fix(workflowID: id, query: query, error: error)
    }
    /// AI translation with the text-processing model; the window controller supplies it.
    var translationAI: (any AskTranslationEngine)?
    /// AI prompts (`rw`, `sum`) with the text-processing model; the window controller supplies it.
    var promptAI: (any AskTextGenerating)?
    /// The user's workflows (`docs/design/ask-launcher-workflows.md`); the window controller supplies them.
    var workflows: AskWorkflowStore?
    var workflowAuthoring: AskWorkflowAuthoringStore?
    var authoringSession: AskWorkflowAuthoringSession? {
        selectedId.flatMap { workflowAuthoring?.session($0) }
    }
    /// Keeps what the translation plugin looked up; the window controller supplies it.
    var wordBook: AskWordBookRecorder?
    /// Opens the word book dialog on a word; tests record it instead.
    var openWordBook: @MainActor (String?) -> Void = { key in AskWordBookWindowController.shared.show(selecting: key) }
    /// Opens the word book and looks a word up there; tests record it instead.
    var lookUpInWordBook: @MainActor (String) -> Void = { text in
        AskWordBookWindowController.shared.show(lookingUp: text)
    }
    /// Saved AI prompt results; the window controller supplies them (`AskConversationModel+Notes`).
    var notes: (any AskNoteStoring)?
    /// The shown result's text and the note it was saved as, so ⌘S again takes it out.
    var launcherNote: (body: String, id: UUID)?
    /// Opens the notes window on a note; tests record it instead.
    var openNotes: @MainActor (UUID?) -> Void = { id in AskNotesWindowController.shared.show(selecting: id) }
    /// Shows a result moved out of the launcher (⌘O); tests record it instead.
    var presentResultWindow: @MainActor (AskResultDocument) -> Void = { AskResultWindowController.shared.present($0) }
    /// Opens a saved note in a result window; tests record it instead.
    var openNoteWindow: @MainActor (AskNote) -> Void = { AskResultWindowController.shared.open($0) }
    /// What result windows opened from the launcher can do.
    var resultWindowServices: AskResultDocument.Services { AskResultWindowController.shared.services }
    /// The launcher's keyword plugins (`fy` → translate); see `AskConversationModel+Plugins`.
    lazy var plugins: AskPluginSession = {
        let session = AskPluginSession(plugins: makeLauncherPlugins()) { [weak self] in
            self?.launcherKeywords ?? AskPluginRegistry.defaultKeywords
        }
        connectWordBook(to: session)
        connectNotes(to: session)
        session.onActivate = { [weak self] keyword in self?.keywordUsage.record(keyword) }
        return session
    }()
    /// How often each launcher keyword is used, for the launcher's home.
    lazy var keywordUsage = AskKeywordUsageStore(defaults: defaults)
    /// Types text into the app the launcher came from; the window controller supplies it.
    var deliverText: ((String) async throws -> Void)?
    /// Reads text aloud in a language; tests record it instead.
    var speak: @MainActor (String, String) -> Void = { text, language in AskSpeaker.shared.speak(text, language: language) }
    /// Sends a workflow's notification; false when notifications are not allowed. Tests record it instead.
    var notifyUser: @MainActor (String, String) async -> Bool = { title, body in
        await SystemLocalNotificationService.shared.deliverLocalNotification(
            title: title, body: body, identifier: "workflow." + UUID().uuidString
        )
    }
    /// A short note once the launcher has closed (a workflow's bottom-bar note); tests record it instead.
    var passiveNotice: @MainActor (String) -> Void = { text in AskWorkflowNoticePanel.shared.show(text) }
    /// Shows a file in Finder; tests record it instead.
    var revealFile: @MainActor (URL) -> Void = { url in NSWorkspace.shared.activateFileViewerSelecting([url]) }
    /// Opens an application by name or bundle id; false when there is none. Tests record it instead.
    var openApplicationNamed: @MainActor (String) -> Bool = { name in
        AskWorkflowLauncherActionHost.openApplication(name)
    }
    /// Opens a file or folder in an application by name or bundle id; false when there is no
    /// such application. Tests record it instead.
    var openFileInApplication: @MainActor (URL, String) -> Bool = { url, name in
        AskWorkflowLauncherActionHost.open(url, inApplication: name)
    }
    @Published var reasoningEffort: AskReasoningEffort = .providerDefault
    let modelLibrary: AskModelLibrary
    private var inferenceUsage: [String: AskTokenUsage] = [:]
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
        return localFallback(reference, hasImage: requiresVision(launcher: launcher),
                             local: storesLocally(launcher: launcher))
    }

    /// Conversations kept on this Mac run on the user's own models; a Cloud reference
    /// falls back to the first one available.
    func localFallback(_ reference: String, hasImage: Bool, local: Bool) -> String {
        guard local, reference.hasPrefix("cloud:") else { return reference }
        return modelLibrary.firstLocalReference(hasImage: hasImage)
            ?? modelLibrary.firstLocalReference(hasImage: hasImage, confirmedVision: false) ?? reference
    }

    /// Whether the conversation window's composer can use Cloud models: signed in,
    /// and its conversation is not one kept on this Mac.
    var cloudAvailable: Bool { cloudAvailable(launcher: false) }
    func cloudAvailable(launcher: Bool) -> Bool { !storesLocally(launcher: launcher) }

    /// A Typeflux Cloud session exists; without one every conversation stays on this Mac.
    var isSignedIn: Bool { session().map { !$0.token.isEmpty } ?? false }

    /// Whether this composer's conversation stays on this Mac: always when signed out,
    /// the stored place for an existing conversation, else the draft's choice or the default.
    func storesLocally(launcher: Bool) -> Bool {
        guard isSignedIn else { return true }
        if !launcher, let id = selectedId { return isLocal(id) }
        return (launcher ? launcherDraft : draft).storesLocally ?? commandSources.privateByDefault()
    }

    /// Only a conversation that has not started can still choose where it is stored,
    /// so none is ever half uploaded and half kept on this Mac.
    func canChangeStorage(launcher: Bool) -> Bool {
        isSignedIn && (launcher || selectedId == nil)
    }

    func setStoresLocally(_ value: Bool, launcher: Bool) {
        guard canChangeStorage(launcher: launcher) else { return }
        if launcher { launcherDraft.storesLocally = value } else { draft.storesLocally = value }
        persistDrafts()
    }

    /// The conversation is kept on this Mac rather than in the Typeflux Cloud account.
    func isLocal(_ id: String) -> Bool { !isSignedIn || localConversationIds.contains(id) }

    func registerLocalHistory(_ items: [AskConversationSummary]) {
        localConversationIds.formUnion(items.map(\.id))
    }

    func isDeletedConversation(_ id: String) -> Bool { deletedConversationIDs.contains(id) }

    /// The cache partition of a conversation's copies and drafts.
    func cacheOwner(_ id: String) -> String {
        localConversationIds.contains(id) ? AskRoutedAPI.localOwner : owner
    }
    func requiresVision(launcher: Bool) -> Bool {
        let current = launcher ? launcherDraft : draft
        return current.sendsImage
            || (!launcher && selected?.messages.contains(where: { $0.hasImage }) == true)
    }

    @Published var isOpeningChat = false
    @Published var savedChatDrafts: [AskSavedChatDraft] = []
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
    /// Why the last files could not all be attached, per composer.
    @Published var attachmentNotice: String?
    @Published var launcherAttachmentNotice: String?
    /// Loads in flight per draft key (`visionDraftKey`); sending waits for them.
    @Published var attachmentLoads: [String: Int] = [:]
    /// Skills, MCP servers, notes and local mode for slash commands; the window controller fills it in.
    var commandSources = AskCommandSources()
    /// Bumped by the "/search" command; the window opens its search palette.
    @Published var searchRequest = 0
    /// A short confirmation after a slash command, cleared after a moment.
    @Published var commandFeedback: String?
    @Published var permissionModes: [String: AskPermissionMode] = [:]
    @Published var launcherPermissionMode: AskPermissionMode = .standard
    @Published var draftPermissionMode: AskPermissionMode = .standard
    /// What a workflow's actions did after the last run, for the launcher's bottom bar.
    @Published var workflowActions: AskWorkflowActionsState?
    /// A workflow's question in the launcher: may it open a web host it does not name?
    @Published var workflowApproval: AskWorkflowApproval?
    /// Answers `workflowApproval`; set while it is shown.
    var workflowApprovalReply: ((Bool) -> Void)?
    /// Command names, most recent first, for the palette's "Recent" group.
    var recentCommands: [String] = []
    @Published private(set) var recoveringImages: [String: AskImageRecoveryTarget] = [:]
    @Published private(set) var conversations: [AskConversationSummary] = []
    /// Conversations stored on this Mac. Signed in, they are listed beside the Cloud ones.
    @Published private(set) var localConversationIds: Set<String> = []
    @Published private(set) var selected: AskConversation?
    @Published private(set) var selectedId: String?
    @Published private(set) var isLoadingSelection = false
    @Published private(set) var selectionLoadFailed = false
    private(set) var snapshots: [String: AskConversation] = [:]
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
    @Published private(set) var capturingScreenshot = false
    /// Reopening an unfinished question preserves its original captured context.
    @Published private(set) var launcherContextRestored = false
    @Published var capturedContentChanges: [Bool: AskCapturedContentChange] = [:]
    var capturedContentFeedbackTasks: [Bool: Task<Void, Never>] = [:]
    var capturedContentFeedbackDuration: Duration = .seconds(5)
    var capturedContentAccount: String? { session()?.owner }
    @Published var recoveryEntries: [String: [AskExecutionEntry]] = [:]
    @Published var inspectingRecovery = false
    @Published var recoveryWorking = false
    var recoveryGeneration = UUID()
    /// What the latest `resume` of a credit-paused run reported, per conversation,
    /// until the account balance changes again.
    @Published var creditPauseDetails: [String: CloudCreditsExhaustedDetails] = [:]
    /// Validation feedback belongs to the composer that submitted it.
    @Published var submissionIssues: [Bool: AskSubmissionIssue] = [:]
    @Published private(set) var submissionPreflights: [Bool: UUID] = [:]
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
    var onSignIn: () -> Void = { LoginWindowController.shared.show() }
    var onControlChanged: ((Bool) -> Void)?
    /// Called when Typeflux Cloud reports no credits left, so the account balance can refresh.
    var onCreditsExhausted: (() -> Void)?
    var recordingIsActive: () -> Bool = { false }

    let api: any AskAPI
    let cache: any AskCaching
    let tools: any AskToolExecuting
    private let capture: any AskContextCapturing
    let session: () -> (owner: String, token: String)?
    let deviceId: String
    var owner = ""
    private var operations: [String: Task<Void, Never>] = [:]
    private var operationIds: [String: UUID] = [:]
    private var approvals: [String: CheckedContinuation<String?, Never>] = [:]
    private var approvalRequests: [String: (id: UUID, request: AskApprovalRequest)] = [:]
    let approvalStore = AskApprovalStore()
    var cloudApprovals: [String: (id: String, request: AskApprovalRequest)] = [:]
    private let approvalReuseEnabled: Bool
    private var operationErrors: [String: String] = [:]
    private var pendingSends: [String: AskSendRequest] = [:]
    // Local consent for the latest submission, retained for retries but never restored from history.
    private var screenshotConsent: [String: String] = [:]
    var captureGeneration = UUID()
    var selectionGeneration = UUID()
    private var selectionObservation: Task<Void, Never>?
    private var draftSave: Task<Void, Never>?
    private var draftSaveConversationID: String?
    private var deletedConversationIDs: Set<String> = []
    private var authObserver: AnyCancellable?
    private var modelObserver: AnyCancellable?
    private var memoryObserver: AnyCancellable?
    private let defaults: UserDefaults
    private let memoryInvalidations: MemoryInvalidationStore
    private var memoryPurgeTask: Task<Void, Never>?
    private var memoryPurgeGeneration = 0
    static let memoryPurgePendingKey = "ask.memory.purgePending"

    init(api: any AskAPI, cache: any AskCaching, tools: any AskToolExecuting,
         capture: any AskContextCapturing, deviceId: String, modelLibrary: AskModelLibrary? = nil,
         defaults: UserDefaults = .standard,
         trustedApprovalPeer: AskHarnessContract? = nil, scopedApprovalEnabled: Bool = false,
         session: @escaping () -> (owner: String, token: String)?) {
        self.modelLibrary = modelLibrary ?? .shared
        self.api = api; self.cache = cache; self.tools = tools; self.capture = capture
        self.deviceId = deviceId; self.session = session; self.defaults = defaults
        memoryInvalidations = MemoryInvalidationStore(defaults: defaults)
        // Only DI-supplied, trusted advertisements may enable reuse. Conversation metadata is inert.
        approvalReuseEnabled = AskHarnessContract(version: 1, capabilities: [AskHarnessCapability.scopedApproval.rawValue])
            .permits(.scopedApproval, peer: trustedApprovalPeer, enabled: scopedApprovalEnabled ? [.scopedApproval] : [])
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
        memoryObserver = NotificationCenter.default.publisher(for: .askMemoryDidClear)
            .sink { [weak self] notification in
            let changedOwner = notification.userInfo?["owner"] as? String
            Task { @MainActor in
                guard let self, changedOwner == nil || changedOwner == self.session()?.owner else { return }
                self.clearMemory()
            }
        }
    }

    /// Drops captured memory and removes the copies pinned to server conversations.
    /// The purge stays pending across launches until the server confirms it.
    func clearMemory() {
        let account = session()?.owner ?? "local"
        memoryInvalidations.invalidate(owner: account, notify: false)
        for id in pendingSends.keys { pendingSends[id]?.memory = nil }
        if launcherDraft.memory != nil { launcherDraft.memory = AskMemory() }
        if draft.memory != nil { draft.memory = AskMemory() }
        for (id, value) in drafts where value.memory != nil { drafts[id]?.memory = AskMemory() }
        for (id, value) in snapshots where value.memory != nil { snapshots[id]?.memory = nil }
        selected?.memory = nil
        memoryPurgeGeneration += 1
        defaults.set(true, forKey: Self.memoryPurgePendingKey)
        defaults.set(true, forKey: Self.memoryPurgePendingKey + "." + account)
        persistDrafts()
        flushMemoryPurge()
    }

    /// Retries a pending purge; it runs whenever the user is signed in. A clear
    /// that happens while a purge is in flight triggers one more purge afterwards.
    func flushMemoryPurge() {
        guard memoryPurgeTask == nil, let current = session(),
              defaults.bool(forKey: Self.memoryPurgePendingKey + "." + current.owner) else { return }
        let generation = memoryPurgeGeneration
        let cutoff = memoryInvalidations.cutoff(owner: current.owner)
        memoryPurgeTask = Task { [weak self, api] in
            var purged = false
            do {
                try await api.purgeMemory(owner: current.owner, token: current.token)
                purged = true
            } catch {
                NetworkDebugLogger.logMessage("[Ask Memory] purge failed: \(error.localizedDescription)")
            }
            guard let self else { return }
            memoryPurgeTask = nil
            // Completion only acknowledges the account and deletion epoch that started this request.
            guard purged else { return }
            guard session()?.owner == current.owner else {
                // Never acknowledge another account's pending deletion with this response.
                flushMemoryPurge()
                return
            }
            if memoryPurgeGeneration == generation, memoryInvalidations.cutoff(owner: current.owner) == cutoff {
                defaults.set(false, forKey: Self.memoryPurgePendingKey + "." + current.owner)
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
    var canSend: Bool { !isLoadingAttachments(launcher: false) && (canSendNow || canQueue || (isEditingQueued && draft.canSend)) }
    private var canSendNow: Bool { submissionPreflights[false] == nil && !isLoadingSelection && (selectedId == nil || selected != nil) && draft.canSend && !isBusy && (selected.map { pendingSends[$0.id] == nil && !($0.run == nil && $0.messages.last?.role == "user") } ?? true) && !capturing && !recordingIsActive() && !voiceInput.isOccupied }
    /// A busy conversation takes the follow-up into its queue instead.
    var canQueue: Bool {
        guard submissionPreflights[false] == nil, let value = selected, !isLoadingSelection, isBusy, !isEditingQueued else { return false }
        return draft.canSend && sendQueue.canEnqueue(value.id) && !capturing && !recordingIsActive() && !voiceInput.isOccupied
    }
    var canSendLauncher: Bool { submissionPreflights[true] == nil && launcherDraft.canSend && !isLoadingAttachments(launcher: true) && !capturing && !recordingIsActive() && !voiceInput.isOccupied }

    /// The account session; switching accounts resets the model first.
    func credentials() -> AskRoute? {
        guard let current = session() else { error = L("ask.loginRequired"); return nil }
        if owner != current.owner {
            if !owner.isEmpty { resetSession() }
            owner = current.owner
        }
        return AskRoute(account: current.owner, owner: current.owner, token: current.token)
    }

    /// The session for one conversation: the local engine for a conversation kept on
    /// this Mac, otherwise the Cloud account. A new conversation (nil) follows the draft.
    func credentials(for id: String?) -> AskRoute? {
        guard let account = credentials() else { return nil }
        let local = id.map(isLocal) ?? storesLocally(launcher: false)
        return local ? account.local : account
    }

    func resetSession() {
        quickSearch.cancel()
        quickSearch.results = nil
        recoveryGeneration = UUID(); recoveryWorking = false; inspectingRecovery = false
        recoveryEntries = [:]
        capturedContentFeedbackTasks.values.forEach { $0.cancel() }
        capturedContentFeedbackTasks = [:]
        capturedContentChanges = [:]
        workflowAuthoring?.reset()
        tools.cancelProjects(conversationId: nil)
        voiceInput.cancel()
        historyErrorTask?.cancel(); historyRefreshError = nil
        pullRefreshID = nil; isRefreshingHistory = false
        operations.values.forEach { $0.cancel() }; operations = [:]; operationIds = [:]
        submissionPreflights = [:]; submissionIssues = [:]
        approvals.values.forEach { $0.resume(returning: nil) }; approvals = [:]; approvalRequests = [:]; approvalStore.reset()
        inferenceUsage = [:]
        pendingApprovals = [:]; busyIds = []; pendingSends = [:]; operationErrors = [:]
        sendQueue = AskSendQueue(); steeringIds = []
        screenshotConsent = [:]
        cloudApprovals = [:]
        permissionModes = [:]; launcherPermissionMode = .standard; draftPermissionMode = .standard
        draftSave?.cancel(); draftSaveConversationID = nil; deletedConversationIDs = []; captureGeneration = UUID(); selectionGeneration = UUID()
        selectionObservation?.cancel(); selectionObservation = nil
        inferenceProgress = [:]; progressInferenceIDs = [:]
        selected = nil; selectedId = nil; isLoadingSelection = false; selectionLoadFailed = false
        snapshots = [:]; drafts = [:]; transcriptPositions = [:]; savedChatDrafts = []
        historyGeneration = UUID(); historyOffset = 0; conversations = []; localConversationIds = []
        launcherScreenshotNotice = nil; screenshotNotice = nil; recoveringImages = [:]
        attachmentNotice = nil; launcherAttachmentNotice = nil
        launcherDraft = AskDraft(); draft = .followUp; launcherContextRestored = false
        capturing = false; capturingScreenshot = false
        controllingConversationId = nil; onControlChanged?(false); owner = ""
    }

    func makeLauncherSelectionRequest() -> ReadOnlySelectionRequest { capture.makeSelectionRequest() }
    func restoreLauncherContextMarker(_ restored: Bool) { launcherContextRestored = restored }

    func prepareLauncher(request: ReadOnlySelectionRequest? = nil) async {
        let request = request ?? makeLauncherSelectionRequest()
        guard !Task.isCancelled else { return }
        flushMemoryPurge()
        let previousWarning = captureWarning
        captureWarning = nil
        normalizeScreenshotChoices()
        if let current = session(), owner != current.owner { resetSession(); owner = current.owner }
        let expectedOwner = owner
        let expectedSessionOwner = session()?.owner
        // Invalidate an older preparation before awaiting the draft cache.
        let generation = UUID(); captureGeneration = generation; capturing = false; capturingScreenshot = false
        let typedBefore = !launcherDraft.text.isEmpty
        var restored = false
        if !typedBefore, let cached = try? await cache.draft(key: "launcher", owner: owner) {
            guard !Task.isCancelled, generation == captureGeneration,
                  owner == expectedOwner, session()?.owner == expectedSessionOwner else { return }
            // The panel is already open: never replace anything typed meanwhile.
            if launcherDraft.text.isEmpty, !cached.text.isEmpty { launcherDraft = cached; restored = true }
        }
        guard !Task.isCancelled, generation == captureGeneration,
              owner == expectedOwner, session()?.owner == expectedSessionOwner else { return }
        // Restore an unfinished question without silently replacing its context.
        // Text typed into the just-opened panel still gets this launch's context.
        if typedBefore || restored {
            launcherContextRestored = true
            // The kept draft keeps its context as it was. A screenshot that was not
            // taken still says why, instead of reading as attached on this opening.
            if launcherDraft.includeScreenshot, launcherDraft.screenshot == nil {
                captureWarning = previousWarning ?? capture.missingScreenshotWarning()
            }
            return
        }
        clearCapturedContentFeedback(launcher: true)
        capturing = true; capturingScreenshot = launcherDraft.includeScreenshot; launcherContextRestored = false
        let memoryGeneration = memoryPurgeGeneration
        defer { if generation == captureGeneration { capturing = false; capturingScreenshot = false } }
        let context = await capture.capture(includeScreenshot: launcherDraft.includeScreenshot, includeSelection: true, request: request)
        guard !Task.isCancelled, generation == captureGeneration,
              owner == expectedOwner, session()?.owner == expectedSessionOwner else { return }
        launcherDraft.selection = context.selection
        launcherDraft.selectionOff = nil
        launcherDraft.source = context.source
        launcherDraft.sourceBundleID = context.sourceBundleID
        launcherDraft.sourceOff = nil
        launcherDraft.screenshot = context.screenshot
        launcherDraft.capturedAt = context.capturedAt
        launcherDraft.memory = memoryGeneration == memoryPurgeGeneration ? context.memory ?? AskMemory() : AskMemory()
        launcherDraft.memoryOff = nil
        captureWarning = context.warning
        persistDrafts()
    }

    /// Replace only the source identity. Old selected text belongs to the old
    /// source; screenshots and memory remain explicit, independent attachments.
    func refreshLauncherContext() async {
        guard !Task.isCancelled else { return }
        // The nonactivating launcher leaves the source app frontmost. Pin it
        // now, before any asynchronous accessibility or screenshot work.
        let request = makeLauncherSelectionRequest()
        if let current = session(), owner != current.owner { resetSession(); owner = current.owner }
        normalizeScreenshotChoices()
        let expectedOwner = owner, expectedSessionOwner = session()?.owner
        let generation = UUID(); captureGeneration = generation
        capturing = true; capturingScreenshot = false
        defer { if generation == captureGeneration { capturing = false; capturingScreenshot = false } }
        // A popover can activate Typeflux even though the launcher itself is
        // nonactivating. Its editor is never a replacement source application.
        guard request.processID != ProcessInfo.processInfo.processIdentifier else {
            reportSourceRefreshFailure(L("ask.context.refresh.externalApp"))
            return
        }
        let context = await capture.capture(includeScreenshot: false, includeSelection: false, request: request)
        guard !Task.isCancelled, generation == captureGeneration,
              owner == expectedOwner, session()?.owner == expectedSessionOwner else { return }
        let sourceFailed = context.selectionStatus.map {
            !["selection-not-requested", "accessibility-context", "no-selection-found"].contains($0)
        } ?? false
        guard !sourceFailed, let source = context.source,
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            reportSourceRefreshFailure(context.warning ?? L("ask.context.refresh.failed"))
            return
        }
        let before = AskCapturedContentSnapshot(launcherDraft)
        let wasRestored = launcherContextRestored
        launcherDraft.selection = nil
        launcherDraft.selectionOff = nil
        launcherDraft.source = source
        launcherDraft.sourceBundleID = context.sourceBundleID
        launcherContextRestored = false
        recordCapturedContentChange(.sourceReplacement(restored: wasRestored), before: before,
                                    text: L("ask.context.refresh.applied"), launcher: true)
        persistDrafts()
    }

    func refreshScreenshot(launcher: Bool) async {
        guard !Task.isCancelled, !capturing || capturingScreenshot,
              screenshotCapability(launcher: launcher).canAttach else { return }
        let generation = UUID(); captureGeneration = generation; capturing = true; capturingScreenshot = true
        let expectedOwner = owner, expectedSessionOwner = session()?.owner
        let draftKey = capturedContentKey(launcher: launcher)
        defer { if captureGeneration == generation { capturing = false; capturingScreenshot = false } }
        let context = await capture.capture(includeScreenshot: true, includeSelection: false)
        guard !Task.isCancelled, captureGeneration == generation,
              owner == expectedOwner, session()?.owner == expectedSessionOwner,
              capturedContentKey(launcher: launcher) == draftKey else { return }
        guard let screenshot = context.screenshot else {
            captureWarning = context.warning ?? L("ask.capture.unavailable")
            return
        }
        clearCapturedContentFeedback(launcher: launcher)
        if launcher {
            launcherDraft.screenshot = screenshot; launcherDraft.capturedAt = context.capturedAt
        } else {
            draft.screenshot = screenshot; draft.capturedAt = context.capturedAt
        }
        captureWarning = context.warning; persistDrafts()
    }

    func persistDrafts() {
        draftSave?.cancel()
        // While a queued message is open in the composer, the conversation's own draft is the stash.
        let editing = sendQueue.editing.flatMap { $0.conversationId == selectedId ? $0.stash : nil }
        let launcher = launcherDraft, followUp = editing ?? draft, owner = owner
        let id = isLoadingSelection ? nil : selectedId.flatMap { deletedConversationIDs.contains($0) ? nil : $0 }
        let followUpOwner = id.map(cacheOwner) ?? owner
        if let id, !isLoadingSelection { drafts[id] = followUp }
        draftSaveConversationID = id
        draftSave = Task { [cache] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                try await cache.saveDraft(launcher, key: "launcher", owner: owner)
                try Task.checkCancellation()
                if let id, self.owner == owner, !deletedConversationIDs.contains(id) {
                    try await cache.saveDraft(followUp, key: id, owner: followUpOwner)
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

    /// The launcher's home offers recent conversations before the workspace has
    /// listed them: read them from this Mac's cache, never the network, so the
    /// launcher neither waits nor shows an error for it.
    func loadCachedHistoryIfNeeded() async {
        // Signed out there is nothing to list; `credentials()` would also report that as an error.
        guard conversations.isEmpty, session() != nil, let current = credentials() else { return }
        let cached = (try? await cache.list(owner: current.owner)) ?? []
        let cachedLocal = current.token.isEmpty ? [] : (try? await cache.list(owner: AskRoutedAPI.localOwner)) ?? []
        guard owner == current.account, conversations.isEmpty else { return }
        localConversationIds.formUnion(cachedLocal.map(\.id))
        conversations = Self.unique(Self.insertingByDate(cachedLocal, into: Self.unique(cached)))
    }

    func refreshHistory(loadMore: Bool = false, inlineError: Bool = false) async {
        guard let current = credentials() else { return }
        let generation = UUID(); historyGeneration = generation
        // Signed in, conversations kept on this Mac are listed beside the Cloud ones.
        let separateLocal = !current.token.isEmpty
        if !loadMore, conversations.isEmpty {
            let cached = (try? await cache.list(owner: current.owner)) ?? []
            let cachedLocal = separateLocal ? (try? await cache.list(owner: AskRoutedAPI.localOwner)) ?? [] : []
            guard owner == current.account, generation == historyGeneration else { return }
            localConversationIds.formUnion(cachedLocal.map(\.id))
            conversations = Self.unique(Self.insertingByDate(cachedLocal, into: Self.unique(cached)))
        }
        do {
            let offset = loadMore ? historyOffset : 0
            let items = try await api.list(token: current.token, offset: offset)
            let localItems = separateLocal && !loadMore ? try? await localHistory() : nil
            guard owner == current.account, generation == historyGeneration else { return }
            if let localItems { localConversationIds.formUnion(localItems.map(\.id)) }
            // Retain row positions while reading. Polling must never remove and
            // reinsert the selected row, and pagination uses server rows, not UI count.
            let incoming = Self.unique(items)
            let incomingLocal = Self.unique(localItems ?? []).filter { item in !incoming.contains { $0.id == item.id } }
            let byId = Dictionary(uniqueKeysWithValues: (incoming + incomingLocal).map { ($0.id, $0) })
            var merged = conversations.compactMap { item -> AskConversationSummary? in
                if let updated = byId[item.id] { return updated.updatedAt >= item.updatedAt ? updated : item }
                // A list that could not be read says nothing about its conversations.
                let unread = separateLocal && localItems == nil && localConversationIds.contains(item.id)
                return loadMore || unread || busyIds.contains(item.id) || pendingSends[item.id] != nil
                    || selectedId == item.id ? item : nil
            }
            let existing = Set(merged.map(\.id))
            merged.append(contentsOf: incoming.filter { !existing.contains($0.id) })
            merged = Self.insertingByDate(incomingLocal.filter { !existing.contains($0.id) }, into: merged)
            conversations = Self.unique(merged)
            historyOffset = offset + items.count
            historyHasMore = items.count == 50
        } catch {
            if owner == current.account, generation == historyGeneration {
                if inlineError { historyRefreshError = L("ask.history.refreshFailed") }
                else { self.error = error.localizedDescription }
            }
        }
    }

    /// Every conversation stored on this Mac; the engine pages by 50.
    private func localHistory() async throws -> [AskConversationSummary] {
        var all: [AskConversationSummary] = []
        while true {
            let page = try await api.list(token: "", offset: all.count)
            all += page
            if page.count < 50 { return all }
        }
    }

    /// Adds rows without moving the ones already listed: each goes above the first older row.
    static func insertingByDate(_ items: [AskConversationSummary],
                                into list: [AskConversationSummary]) -> [AskConversationSummary] {
        var result = list
        for item in items where !result.contains(where: { $0.id == item.id }) {
            let index = result.firstIndex { $0.updatedAt < item.updatedAt } ?? result.endIndex
            result.insert(item, at: index)
        }
        return result
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
        let id = AskConversationID.canonical(rawId)
        guard let current = credentials(for: id) else { return }
        if selectedId == id, isLoadingSelection || (!reload && selected != nil && !selectionLoadFailed) { return }
        clearCapturedContentFeedback(launcher: false)
        voiceInput.cancel()
        cancelQueuedEdit(advancing: false)
        selectionObservation?.cancel(); selectionObservation = nil
        let generation = UUID(); selectionGeneration = generation
        let oldId = selectedId, oldDraft = draft
        if let oldId, !isLoadingSelection { drafts[oldId] = oldDraft }
        // Commit navigation synchronously, before the first cache/network await.
        selectedId = id; selected = snapshots[id]; isLoadingSelection = true; selectionLoadFailed = false
        draft = drafts[id] ?? .followUp; submissionIssues[false] = nil; error = nil; captureWarning = nil; screenshotNotice = nil; visionSwitch = nil
        attachmentNotice = nil
        captureGeneration = UUID(); capturing = false; capturingScreenshot = false
        if let oldId, !deletedConversationIDs.contains(oldId), let saved = drafts[oldId] { try? await cache.saveDraft(saved, key: oldId, owner: cacheOwner(oldId)) }
        let cached = try? await cache.load(id: id, owner: current.owner)
        let savedDraft = try? await cache.draft(key: id, owner: current.owner)
        guard generation == selectionGeneration, owner == current.account else { return }
        if let cached {
            let merged = sanitizedMemory(snapshots[id]?.reconciling(cached) ?? cached,
                                         account: current.account, local: current.token.isEmpty)
            selected = merged; snapshots[id] = merged
            await refreshRecovery(merged, route: current)
        }
        draft = drafts[id] ?? savedDraft ?? .followUp
        do {
            let value = try await api.conversation(id: id, token: current.token)
            guard owner == current.account else { return }
            let hasUnconfirmedMessage = pendingSends[id].map { pending in !value.messages.contains { $0.id == pending.id } } ?? false
            if !hasUnconfirmedMessage { try await cache.save(value, owner: current.owner) }
            let latest = try await cache.load(id: id, owner: current.owner) ?? value
            guard owner == current.account else { return }
            snapshots[id] = sanitizedMemory(snapshots[id]?.reconciling(latest) ?? latest,
                                            account: current.account, local: current.token.isEmpty)
            guard generation == selectionGeneration else { return }
            selected = snapshots[id] ?? latest; isLoadingSelection = false
            await refreshRecovery(selected ?? latest, route: current)
            guard generation == selectionGeneration, owner == current.account else { return }
            switchToVisionModelIfNeeded(launcher: false); normalizeScreenshotChoices(); error = operationErrors[id]
            queueDidSettle(id)
            // Observe active runs without resuming desktop tools or inference.
            if latest.run?.isActive == true, !busyIds.contains(id) {
                selectionObservation = monitorConversation(id: id, current: current)
            }
            // Loading a conversation never resumes desktop tools automatically.
        } catch {
            if generation == selectionGeneration, owner == current.account {
                isLoadingSelection = false; selectionLoadFailed = true; self.error = error.localizedDescription
            }
        }
    }

    func retrySelection() {
        guard let id = selectedId else { return }
        Task { await select(id, reload: true) }
    }

    /// `storesLocally` starts a conversation kept on this Mac (true) or in Typeflux Cloud
    /// (false); nil follows the default from settings.
    func newConversation(storesLocally: Bool? = nil) {
        draftPermissionMode = .standard
        clearCapturedContentFeedback(launcher: false)
        selectionObservation?.cancel(); selectionObservation = nil
        voiceInput.cancel()
        cancelQueuedEdit(advancing: false)
        persistDrafts()
        selectionGeneration = UUID(); selected = nil; selectedId = nil
        isLoadingSelection = false; selectionLoadFailed = false
        captureGeneration = UUID(); capturing = false; capturingScreenshot = false
        draft = AskDraft(); submissionIssues[false] = nil; error = nil; captureWarning = nil; screenshotNotice = nil; visionSwitch = nil
        attachmentNotice = nil
        if isSignedIn { draft.storesLocally = storesLocally }
        // No source app is trustworthy here, so only global memory applies.
        draft.memory = capture.globalMemory() ?? AskMemory()
    }

    func submitLauncher() {
        if consumeModeCommand(launcher: true) { return }
        normalizeScreenshotChoices()
        guard canSendLauncher else { return }
        submit(launcherDraft, newConversation: true, launcher: true)
    }
    func addReference(_ reference: AskReference) {
        var updated = draft
        updated.references = (updated.references ?? []) + [reference]
        guard updated.referencesWithinLimit else { error = L("ask.input.tooLarge"); return }
        draft = updated
    }

    func submitDraft() {
        if consumeModeCommand(launcher: false) { return }
        normalizeScreenshotChoices()
        guard !isLoadingAttachments(launcher: false) else { return }
        if isEditingQueued { saveQueuedEdit(); return }
        if canQueue, let id = selected?.id {
            sendQueue.enqueue(draft, to: id)
            clearCapturedContentFeedback(launcher: false)
            draft = .followUp; persistDrafts()
            return
        }
        guard canSendNow else { return }
        submit(draft, newConversation: selectedId == nil)
    }

    /// Sends `text` as a follow-up in the selected conversation, leaving whatever
    /// the user is typing in the composer untouched.
    func sendFollowUp(_ text: String) {
        guard selected != nil else { return }
        var followUp = AskDraft.followUp
        followUp.text = text
        submit(followUp, newConversation: false, clearsDraft: false)
    }

    /// `messageId` keeps a queued message's ID; `clearsDraft` is false when the queue
    /// sends on its own, so whatever the user is typing stays in the composer.
    private func submit(_ submitted: AskDraft, newConversation: Bool, messageId queuedId: String? = nil,
                        clearsDraft: Bool = true, launcher: Bool = false) {
        guard submissionPreflights[launcher] == nil else { return }
        guard submitted.referencesWithinLimit, submitted.text.utf8.count <= 32000,
              (submitted.sentSelection?.utf8.count ?? 0) <= 64000,
              (submitted.sentSource?.utf8.count ?? 0) <= 1000,
              (submitted.attachments ?? []).reduce(0, { $0 + $1.payloadBytes }) <= AskAttachmentLimits.maximumPayloadBytes else {
            rejectSubmission(.init(text: L("ask.input.tooLarge")), submitted: submitted, queuedId: queuedId, launcher: launcher)
            return
        }
        guard let account = credentials() else {
            rejectSubmission(.init(text: L("ask.loginRequired"), offersSignIn: true),
                             submitted: submitted, queuedId: queuedId, launcher: launcher)
            return
        }
        guard newConversation || selected != nil else { return }
        let local = newConversation
            ? account.token.isEmpty || (submitted.storesLocally ?? commandSources.privateByDefault())
            : selectedId.map(isLocal) == true
        let hasImage = submitted.sendsImage || (!newConversation && selected?.messages.contains { $0.hasImage } == true)
        let reference = localFallback(submitted.modelRef ?? (newConversation ? modelLibrary.defaultReference
                                      : selected?.modelRef ?? "cloud:default"), hasImage: hasImage, local: local)
        let token = local ? "" : account.token
        // Catalog refresh and Ollama probing may suspend. Reserve the submission only;
        // history, cache, tool grants and window changes happen after they succeed.
        let needsRefresh = (reference.hasPrefix("cloud:") && reference != "cloud:default")
            || modelLibrary.registry.resolve(reference)?.0.isOllama == true
        if !needsRefresh {
            if let reason = modelSelectionIssue(reference, cloudAvailable: !token.isEmpty, hasImage: hasImage) {
                rejectSubmission(reason, submitted: submitted, queuedId: queuedId, launcher: launcher)
                return
            }
            submissionIssues[launcher] = nil
            submitValidated(submitted, modelRef: reference, local: local, newConversation: newConversation, messageId: queuedId,
                            clearsDraft: clearsDraft, launcher: launcher)
            return
        }
        let id = newConversation ? UUID().uuidString.lowercased() : selected!.id
        guard !busyIds.contains(id) else { return }
        let generation = selectionGeneration
        let operationId = UUID()
        submissionPreflights[launcher] = operationId
        busyIds.insert(id); operationIds[id] = operationId
        operations[id] = Task { [weak self] in
            guard let self else { return }
            var handled = false
            defer {
                if !handled, owner == account.account, session()?.owner == account.account,
                   !deletedConversationIDs.contains(id), let queuedId {
                    sendQueue.putFirst(AskQueuedMessage(id: queuedId, draft: submitted), in: id)
                    sendQueue.pause(id)
                }
                if submissionPreflights[launcher] == operationId { submissionPreflights[launcher] = nil }
                finishOperation(id, operationId: operationId)
            }
            do {
                try await validateModel(reference, token: token, hasImage: hasImage)
                try Task.checkCancellation()
                guard owner == account.account, session()?.owner == account.account else { return }
                guard selectionGeneration == generation else { return }
                handled = true
                submissionIssues[launcher] = nil
                busyIds.remove(id)
                submitValidated(submitted, modelRef: reference, local: local, newConversation: newConversation, messageId: queuedId,
                                clearsDraft: clearsDraft, launcher: launcher)
            } catch is CancellationError {} catch {
                guard owner == account.account, session()?.owner == account.account, selectionGeneration == generation else { return }
                let issue = modelSelectionIssue(reference, cloudAvailable: !token.isEmpty, hasImage: hasImage)
                    ?? AskSubmissionIssue(text: error.localizedDescription, offersModels: true)
                handled = true
                rejectSubmission(issue, submitted: submitted, queuedId: queuedId, launcher: launcher)
            }
        }
    }

    private func rejectSubmission(_ issue: AskSubmissionIssue, submitted: AskDraft, queuedId: String?, launcher: Bool) {
        submissionIssues[launcher] = issue
        error = issue.text
        if let queuedId, let id = selectedId {
            sendQueue.putFirst(AskQueuedMessage(id: queuedId, draft: submitted), in: id)
            sendQueue.pause(id)
        }
        persistDrafts()
    }

    func modelSelectionIssue(_ reference: String, cloudAvailable: Bool, hasImage: Bool) -> AskSubmissionIssue? {
        if !cloudAvailable, reference.hasPrefix("cloud:") {
            return .init(text: L("ask.local.modelRequired"), offersModels: true, offersSignIn: !isSignedIn)
        }
        guard let (provider, model) = modelLibrary.registry.resolve(reference) else {
            return .init(text: L("ask.models.unavailable"), offersModels: true)
        }
        return modelLibrary.selectionReason(model, provider: provider, hasImage: hasImage, loggedIn: cloudAvailable)
            .map { .init(text: $0, offersModels: true) }
    }

    private func submitValidated(_ submitted: AskDraft, modelRef: String, local: Bool, newConversation: Bool, messageId queuedId: String? = nil,
                                 clearsDraft: Bool = true, launcher: Bool = false) {
        guard let account = credentials() else { return }
        guard newConversation || selected != nil else { return }
        let id = newConversation ? UUID().uuidString.lowercased() : selected!.id
        guard !busyIds.contains(id) else { return }
        if newConversation, local { localConversationIds.insert(id) }
        let current = local ? account.local : account
        error = nil; operationErrors[id] = nil; busyIds.insert(id)
        if newConversation {
            permissionModes[id] = permissionMode(launcher: launcher)
            if launcher { launcherPermissionMode = .standard } else { draftPermissionMode = .standard }
            tools.bindConversation(id)
        }
        let folders = (submitted.attachments ?? []).compactMap { $0.kind == .folder ? $0.path : nil }
        if !folders.isEmpty { tools.grantFolders(folders, conversationId: id) }
        var value = newConversation ? AskConversation(id: id, title: String(submitted.title.prefix(50)), revision: 0, updatedAt: Date(), messages: []) : selected!
        let messageId = queuedId ?? UUID().uuidString
        var request = submitted.request(deviceId: deviceId, tools: [], id: messageId)
        request.clientToolApproval = true
        request.skills = skillUses(submitted.skills)
        request.modelRef = modelRef
        request.reasoningEffort = reasoningEffort.requestValue(for: request.modelRef.flatMap { modelLibrary.registry.resolve($0)?.1 })
        request.memory = newConversation && submitted.memoryOff != true
            ? (submitted.memory ?? capture.globalMemory())?.usable(owner: current.account,
                                                                  invalidations: memoryInvalidations) : nil
        value.modelRef = request.modelRef
        Self.applyMemoryChoice(submitted, newConversation: newConversation, request: &request, conversation: &value)
        pendingSends[id] = request
        screenshotConsent[id] = submitted.includeScreenshot ? messageId : nil
        value.messages.append(.init(id: messageId, role: "user", text: request.text, selection: request.selection, source: request.source, image: request.image, createdAt: Date(), reasoningEffort: request.reasoningEffort, references: request.references, attachments: request.attachments, skills: request.skills, mcpServers: request.mcpServers))
        if launcher { persistDrafts() }
        selectedId = id; selected = value; isLoadingSelection = false; selectionGeneration = UUID()
        if clearsDraft, launcher || draft == submitted {
            clearCapturedContentFeedback(launcher: false); draft = .followUp
        }
        snapshots[id] = value; selectionLoadFailed = false
        updateSummary(value)
        if launcher, launcherDraft == submitted {
            clearCapturedContentFeedback(launcher: true); launcherDraft = AskDraft(); launcherContextRestored = false
        }
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
                try Task.checkCancellation()
                request.memory = request.memory?.usable(owner: current.account, invalidations: memoryInvalidations)
                pendingSends[id] = request
                let response = try await api.send(conversationId: id, request: request, token: current.token)
                pendingSends[id] = nil
                try await drive(response, current: current, screenshotConsentMessageID: submitted.includeScreenshot ? messageId : nil)
            } catch is CancellationError {} catch { await reportOperationError(error, id: id, owner: current.account) }
        }
    }

    /// The server pins memory from the opening message only; empty memory is not sent.
    static func openingMemory(_ memory: AskMemory?) -> AskMemory? {
        guard let memory, !memory.isEmpty else { return nil }
        return memory
    }

    private func validateModel(_ reference: String?, token: String, hasImage: Bool = false) async throws {
        let reference = reference ?? "cloud:default"
        if token.isEmpty, reference.hasPrefix("cloud:") {
            throw AskSubmissionIssue(text: L("ask.local.modelRequired"), offersModels: true, offersSignIn: !isSignedIn)
        }
        if reference.hasPrefix("cloud:"), reference != "cloud:default" {
            let catalog = try await api.models(token: token)
            try Task.checkCancellation()
            try modelLibrary.replaceCloudModels(catalog)
        }
        if modelLibrary.registry.resolve(reference)?.0.isOllama == true {
            await modelLibrary.probeOllama()
            try Task.checkCancellation()
        }
        if let issue = modelSelectionIssue(reference, cloudAvailable: !token.isEmpty, hasImage: hasImage) { throw issue }
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
        guard let value = selected, !busyIds.contains(value.id),
              let current = credentials(for: value.id) else { return }
        if canRetransmitReceipts {
            Task { await retransmitSavedReceipts() }
            return
        }
        guard !recoveryBlocksResume(value) else { inspectingRecovery = true; return }
        let id = value.id
        let retryModelRef = modelReference(launcher: false)
        if pendingSends[id] == nil, let run = value.run, ["failed", "cancelled"].contains(run.status),
           value.messages.contains(where: { $0.hasImage }) {
            guard canResumeImage else {
                error = screenshotCapability(launcher: false).hint ?? L("ask.models.unavailable")
                return
            }
            if let target = imageRecoveryTarget { recoveringImages[id] = target }
        }
        busyIds.insert(id); submissionIssues[false] = nil; error = nil; operationErrors[id] = nil
        let operationId = UUID(); operationIds[id] = operationId
        operations[id] = Task { [weak self] in
            guard let self else { return }; defer { finishOperation(id, operationId: operationId) }
            let monitor = monitorConversation(id: id, current: current)
            defer { monitor.cancel() }
            do {
                _ = await tools.definitions(conversationId: id)
                let response: AskConversation
                if var request = pendingSends[id] {
                    try await validateModel(
                        request.modelRef, token: current.token,
                        hasImage: request.sendsImage || value.messages.contains(where: { $0.hasImage })
                    )
                    request.memory = request.memory?.usable(owner: current.account, invalidations: memoryInvalidations)
                    response = try await api.send(conversationId: id, request: request, token: current.token)
                    pendingSends[id] = nil
                } else if value.run == nil, let message = value.messages.last, message.role == "user" {
                    let request = AskSendRequest(clientToolApproval: true, id: message.id, deviceId: deviceId, text: message.text,
                                                 selection: message.selection, source: message.source, image: message.image,
                                                 tools: await tools.definitions(conversationId: id), modelRef: value.modelRef, reasoningEffort: message.reasoningEffort, references: message.references,
                                                 attachments: message.attachments)
                    try await validateModel(
                        request.modelRef, token: current.token,
                        hasImage: request.sendsImage || value.messages.contains(where: { $0.hasImage })
                    )
                    response = try await api.send(conversationId: id, request: request, token: current.token)
                } else if let run = value.run, ["failed", "cancelled"].contains(run.status) {
                    try await validateModel(
                        retryModelRef, token: current.token,
                        hasImage: value.messages.contains(where: { $0.hasImage })
                    )
                    response = try await api.retry(conversationId: id, runId: run.id, deviceId: deviceId, modelRef: retryModelRef, token: current.token)
                } else {
                    response = try await api.conversation(id: id, token: current.token)
                }
                try await drive(response, current: current, screenshotConsentMessageID: screenshotConsent[id])
            } catch is CancellationError {} catch { await reportOperationError(error, id: id, owner: current.account) }
        }
    }

    /// Continues the selected run where the server paused it for credits. The server
    /// re-checks the balance; a run that is still short stays paused with the new details.
    func resumeCreditPause() {
        guard let value = selected, let run = value.run, run.isPausedForCredits, !busyIds.contains(value.id),
              let current = credentials(for: value.id) else { return }
        selectionObservation?.cancel(); selectionObservation = nil
        let id = value.id
        busyIds.insert(id); submissionIssues[false] = nil; error = nil; operationErrors[id] = nil; creditPauseDetails[id] = nil
        let operationId = UUID(); operationIds[id] = operationId
        operations[id] = Task { [weak self] in
            guard let self else { return }; defer { finishOperation(id, operationId: operationId) }
            let monitor = monitorConversation(id: id, current: current)
            defer { monitor.cancel() }
            do {
                let response = try await api.resume(conversationId: id, runId: run.id, token: current.token)
                try await drive(response, current: current, screenshotConsentMessageID: screenshotConsent[id])
            } catch is CancellationError {} catch let exhausted as CloudCreditsExhaustedError {
                guard owner == current.account else { return }
                creditPauseDetails[id] = exhausted.details ?? CloudCreditsExhaustedDetails()
                onCreditsExhausted?()
            } catch { await reportOperationError(error, id: id, owner: current.account) }
        }
    }

    /// A refreshed balance supersedes what an earlier `resume` reported.
    func creditBalanceDidChange() {
        if !creditPauseDetails.isEmpty { creditPauseDetails = [:] }
    }

    /// Only the latest reply can be regenerated: the server rewinds the whole
    /// turn that produced it, so an older answer could not be replaced without
    /// silently discarding the turns that follow it.
    var regenerableAnswerId: String? {
        guard let value = selected, !isLoadingSelection, !isBusy, !recoveryBlocksResume(value) else { return nil }
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
        guard let value = selected, !busyIds.contains(value.id),
              let current = credentials(for: value.id) else { return }
        guard !recoveryBlocksResume(value) else { inspectingRecovery = true; return }
        let id = value.id
        let modelRef = modelReference(launcher: false)
        busyIds.insert(id); submissionIssues[false] = nil; error = nil; operationErrors[id] = nil
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
                    hasImage: value.messages.contains(where: { $0.hasImage })
                )
                let request = AskRegenerateRequest(clientToolApproval: true, messageId: messageId, deviceId: deviceId,
                                                   modelRef: modelRef, tools: definitions)
                let response = try await api.regenerate(conversationId: id, request: request, token: current.token)
                try await drive(response, current: current, screenshotConsentMessageID: screenshotConsent[id])
            } catch is CancellationError {} catch { await reportOperationError(error, id: id, owner: current.account) }
        }
    }

    private func sanitizedMemory(_ value: AskConversation, account: String, local: Bool) -> AskConversation {
        var value = value
        // Legacy local snapshots have no attributable account. Keep their history
        // readable, but never adopt that memory into the next signed-in account.
        if local, account != AskRoutedAPI.localOwner, value.memory?.owner == nil { value.memory = nil }
        value.memory = value.memory?.usable(owner: account, invalidations: memoryInvalidations)
        if value.memory == nil, let payload = value.run?.inference?.payload {
            value.run?.inference?.payload = AskMemory.removingInjection(from: payload)
        }
        return value
    }

    func accept(_ value: AskConversation, route: AskRoute) async throws {
        try Task.checkCancellation()
        guard owner == route.account, session()?.owner == route.account,
              !deletedConversationIDs.contains(value.id) else { throw CancellationError() }
        if let previous = snapshots[value.id], !value.isNewer(than: previous) { return }
        var value = snapshots[value.id]?.reconciling(value, preservingEqualRevisionContent: true) ?? value
        value = sanitizedMemory(value, account: route.account, local: route.token.isEmpty)
        // Persist meaningful message/state changes, not every transient preview.
        if snapshots[value.id]?.messages != value.messages || snapshots[value.id]?.run?.status != value.run?.status || snapshots[value.id]?.usage != value.usage {
            try await cache.save(value, owner: route.owner)
        }
        guard owner == route.account else { throw CancellationError() }
        // Recheck after the cache write: another delivery or optimistic send
        // may have advanced the state while this task was suspended.
        if let latest = snapshots[value.id], !value.isNewer(than: latest) { return }
        value = snapshots[value.id]?.reconciling(value, preservingEqualRevisionContent: true) ?? value
        value = sanitizedMemory(value, account: route.account, local: route.token.isEmpty)
        snapshots[value.id] = value
        if selected?.id == value.id { selected = selected?.reconciling(value, preservingEqualRevisionContent: true) ?? value }
        if let inferenceID = progressInferenceIDs[value.id], value.run?.inference?.id != inferenceID {
            inferenceProgress[value.id] = nil; progressInferenceIDs[value.id] = nil
        }
        updateSummary(value)
        await refreshRecovery(value, route: route)
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

    private func drive(_ initial: AskConversation, current: AskRoute,
                       screenshotConsentMessageID: String?) async throws {
        defer {
            if Task.isCancelled, let run = initial.run {
                tools.cancelProjectRun(.init(ownerId: current.account, conversationId: initial.id, runId: run.id))
            }
        }
        var value = initial
        while true {
            value = sanitizedMemory(value, account: current.account, local: current.token.isEmpty)
            try await accept(value, route: current)
            value = sanitizedMemory(value, account: current.account, local: current.token.isEmpty)
            // A monitor can have advanced while this response was in flight.
            if let latest = snapshots[value.id] { value = latest }
            guard let run = value.run, run.isActive else { return }
            guard !run.needsRecoveryInspection else { throw AskRecoveryError.unknown }
            // Pending calls stay pending while credits are out; only `resume` continues.
            if run.isPausedForCredits { return }
            if run.status == "running" {
                try await Task.sleep(for: .seconds(1))
                value = try await api.conversation(id: value.id, token: current.token)
                continue
            }
            guard run.deviceId == deviceId else { throw AskLocalError.message(L("ask.tool.otherDevice")) }
            if run.budgetEnabled == true, let deadline = run.budgetDeadline, Date() >= deadline {
                value = try await api.cancel(conversationId: value.id, runId: run.id, token: current.token)
                try await accept(value, route: current)
                throw AskLocalError.message(L("ask.budget.stopped", L("ask.budget.reason.duration")))
            }
            tools.bindExecution(ownerId: current.account, conversationId: value.id, runId: run.id)
            if run.status == "waiting_inference", let inference = run.inference {
                let identity = AskExecutionIdentity(owner: current.account, conversation: value, run: run,
                                                    callId: inference.id, kind: "model")
                let saved = try await cache.execution(id: identity.key, owner: current.owner)
                var receipt: AskInferenceResult?
                if let saved {
                    guard saved.permits(identity), case .inference(let persisted) = saved.receipt else {
                        throw AskRecoveryError.unknown
                    }
                    receipt = persisted
                }
                if receipt == nil {
                    guard let reference = run.modelRef,
                          let (provider, model) = modelLibrary.registry.resolve(reference) else {
                        throw AskLocalError.message(L("ask.models.unavailable"))
                    }
                    let audit = AskExecutionAudit(identity: identity, toolVersion: run.modelRef ?? "model", toolName: "model",
                                                  argumentsHash: AskToolPolicy.digest(inference.payload))
                    guard try await cache.claimExecution(audit, owner: current.owner) else { throw AskRecoveryError.unknown }
                    try Task.checkCancellation()
                    guard session()?.owner == current.account else { throw CancellationError() }
                    guard snapshots[value.id]?.run?.id == run.id,
                          snapshots[value.id]?.run?.status == "waiting_inference",
                          snapshots[value.id]?.run?.inference?.id == inference.id else { return }
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
                        let currentPayload = sanitizedMemory(value, account: current.account, local: current.token.isEmpty)
                            .run?.inference?.payload ?? inference.payload
                        let payload = try AskContextPlanner.devicePayload(currentPayload, model: model, budgeted: run.budgetEnabled == true)
                        let (text, calls) = try await customInference.complete(provider: provider,
                            connection: modelLibrary.connection(provider, model: model), payload: payload,
                            onUsage: { [weak self] usage in await self?.recordInferenceUsage(usage, id: inference.id, owner: current.account) },
                            onProgress: { [weak self] progress in
                                await self?.updateInferenceProgress(progress, id: conversationID, inferenceID: inference.id, owner: current.account, visible: inference.summaryThrough == nil || inference.summaryThrough == 0)
                            })
                        let progress = inferenceProgress[value.id]
                        receipt = AskInferenceResult(runId: run.id, deviceId: deviceId, inferenceId: inference.id, content: text, toolCalls: calls, usage: inferenceUsage[inference.id], reasoning: progress?.reasoning, reasoningMilliseconds: progress?.reasoningMilliseconds,
                                                     finishReason: progress?.truncated == true ? "length" : nil)
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        let progress = inferenceProgress[value.id]
                        receipt = AskInferenceResult(runId: run.id, deviceId: deviceId, inferenceId: inference.id, content: progress?.text ?? "", usage: inferenceUsage[inference.id], failed: true, reasoning: progress?.reasoning, reasoningMilliseconds: progress?.reasoningMilliseconds)
                    }
                    // Persist under the original binding even if logout/cancel raced completion.
                    try await cache.saveReceipt(.inference(receipt!), identity: identity, owner: current.owner)
                }
                try Task.checkCancellation()
                guard session()?.owner == current.account else { throw CancellationError() }
                value = try await api.inferenceResult(conversationId: value.id, request: receipt!, token: current.token)
                try await cache.recordExecution(id: identity.key, event: .acknowledged, owner: current.owner)
                inferenceUsage[inference.id] = nil
                continue
            }
            guard let call = run.pending.first else { return }
            let identity = AskExecutionIdentity(owner: current.account, conversation: value, run: run,
                                                callId: call.id, kind: "tool")
            let journalKey = identity.key
            let saved = try await cache.execution(id: journalKey, owner: current.owner)
            var result: AskToolResultRequest?
            if let saved {
                guard saved.permits(identity), case .tool(let persisted) = saved.receipt else { throw AskRecoveryError.unknown }
                result = persisted
            }
            if result == nil {
                // Project and artifact scopes belong to the account, as `artifactAccess` reads them,
                // not to the cache partition a private conversation uses.
                tools.bindExecution(ownerId: current.account, conversationId: value.id, runId: run.id)
                // Consent comes from the submitted draft, never from historical images or live UI state.
                let cloudDefinition = run.approvalTool(for: call)
                let binding: AskToolBinding
                do {
                    binding = try await preparedToolBinding(call, conversationId: value.id, cloudDefinition: cloudDefinition)
                } catch let failure as AskToolPreparationFailure {
                    guard let rejected = try await rejectToolPreparation(failure, call: call, value: value,
                                                                         identity: identity, current: current) else { return }
                    value = try await deliverToolResult(rejected, identity: identity, current: current)
                    continue
                }
                try Task.checkCancellation()
                guard session()?.owner == current.account else { throw CancellationError() }
                let request = AskToolPolicy.request(call: call, owner: current.account, conversation: value.id,
                                                    run: run.id, step: String(run.steps), binding: binding,
                                                    risk: toolRisk(call, cloudDefinition: cloudDefinition), reuseEnabled: false,
                                                    now: approvalStore.now())
                let grantID: String?
                if automaticallyApproves(call, risk: request.risk, conversationId: value.id) {
                    grantID = approvalStore.issue(request)
                } else {
                    let approvalID = UUID()
                    approvalRequests[value.id] = (approvalID, request)
                    pendingApprovals[value.id] = call
                    grantID = await withCheckedContinuation { approvals[value.id] = $0 }
                    if approvalRequests[value.id]?.id == approvalID {
                        pendingApprovals[value.id] = nil
                        approvalRequests[value.id] = nil
                    }
                }
                try Task.checkCancellation()
                var context = request.context
                context.approvalId = grantID
                result = AskToolResultRequest(runId: run.id, deviceId: deviceId, toolCallId: call.id,
                                              content: "User denied this tool call. Do not repeat it.", isError: true,
                                              harness: .init(version: 1, context: context,
                                                             approval: grantID.flatMap { approvalStore.auditScope($0) },
                                                             outcome: .init(status: "denied")))
                if cloudDefinition != nil { result?.approveExecution = false }
                let latest = try await api.conversation(id: value.id, token: current.token)
                try await accept(latest, route: current)
                guard snapshots[value.id]?.run?.id == run.id, snapshots[value.id]?.run?.status == "waiting_tool",
                      snapshots[value.id]?.run?.pending.first == call else {
                    approvalStore.revoke(conversation: value.id)
                    return
                }
                try Task.checkCancellation()
                guard session()?.owner == current.account else { throw CancellationError() }
                let audit = AskExecutionAudit(identity: identity, toolVersion: binding.toolVersion, toolName: call.function.name,
                                              argumentsHash: request.context.argumentsHash,
                                              approvalId: grantID, approvedAt: grantID == nil ? nil : approvalStore.now())
                guard try await cache.claimExecution(audit, owner: current.owner) else { throw AskRecoveryError.unknown }
                if let grantID {
                    result?.harness?.outcome?.status = "unknown"
                    do {
                        if call.function.name == "computer" || call.function.name == "browser" {
                            guard controllingConversationId == nil else { throw AskLocalError.message(L("ask.tool.busy")) }
                            controllingConversationId = value.id; onControlChanged?(true)
                        }
                        // Claiming and fetching can suspend. Re-resolve local evidence at dispatch.
                        let currentCloudDefinition = snapshots[value.id]?.run?.approvalTool(for: call)
                        guard (currentCloudDefinition == nil) == (cloudDefinition == nil) else {
                            throw AskLocalError.message(L("ask.approval.changed"))
                        }
                        let bindingNow = try await preparedToolBinding(call, conversationId: value.id,
                                                                      cloudDefinition: currentCloudDefinition)
                        try Task.checkCancellation()
                        guard session()?.owner == current.account else { throw CancellationError() }
                        guard bindingNow == request.binding,
                              approvalStore.consume(grantID, for: request) else {
                            throw AskLocalError.message(L("ask.approval.changed"))
                        }
                        tools.setExecutionDeadline(run.budgetEnabled == true ? run.budgetDeadline : nil, conversationId: value.id)
                        let authorize = { [self] in
                            try Task.checkCancellation()
                            if run.budgetEnabled == true, let deadline = run.budgetDeadline, Date() >= deadline {
                                throw AskLocalError.message(L("ask.budget.stopped", L("ask.budget.reason.duration")))
                            }
                            guard self.session()?.owner == current.account,
                                  self.snapshots[identity.conversationId]?.run?.id == run.id,
                                  self.snapshots[identity.conversationId]?.run?.status == "waiting_tool",
                                  self.snapshots[identity.conversationId]?.run?.pending.first == call,
                                  self.approvalStore.validateDispatch(grantID, for: request) else {
                                throw AskLocalError.message(L("ask.approval.changed"))
                            }
                        }
                        if cloudDefinition != nil {
                            try authorize()
                            cloudApprovals[identity.key] = (grantID, request)
                            result?.approveExecution = true
                            result?.content = "Tool execution authorized."
                            result?.isError = false
                            result?.harness?.outcome?.status = "ok"
                        } else {
                            let output = try await tools.executeApproved(call, conversationId: value.id,
                                                                        binding: bindingNow, authorize: authorize)
                            result?.record(output)
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        result?.content = error.localizedDescription
                        if let failure = error as? AskToolPreparationFailure {
                            result?.content = L("ask.tool.notExecuted", failure.message)
                            result?.harness?.outcome = failure.outcome
                        } else if let observation = error as? AskObservationError {
                            // Automation executors return an unknown receipt once any event
                            // was dispatched; these thrown refusals precede that boundary.
                            let failure = AskToolPreparationFailure(observation)
                            result?.content = L("ask.tool.notExecuted", failure.message)
                            result?.harness?.outcome = failure.outcome
                        } else if error is MCPInputError { result?.harness?.outcome?.status = "invalid" }
                        else if let projectError = error as? AskProjectError {
                            result?.harness?.outcome?.status = projectError == .denied ? "denied" : "invalid"
                        } else if let artifactError = error as? AskArtifactError {
                            result?.harness?.outcome?.status = artifactError == .denied ? "denied" : "invalid"
                        }
                        else if case MCPClientError.timedOut = error { result?.harness?.outcome?.status = "timeout" }
                    }
                    if let scope = approvalStore.auditScope(grantID) {
                        result?.harness?.approval = scope
                    }
                    if controllingConversationId == value.id { controllingConversationId = nil; onControlChanged?(false) }
                }
                try await cache.saveReceipt(.tool(result!), identity: identity, owner: current.owner)
            }
            value = try await deliverToolResult(result!, identity: identity, current: current)
        }
    }

    var terminalAccess: AskTerminalAccess {
        .init(status: { [weak self] ref in
            guard let self else { throw AskProjectRuntimeError.denied }
            try self.validateTerminalAccess(ref)
            return try self.tools.terminalStatus(ref)
        }, stop: { [weak self] ref in
            guard let self else { throw AskProjectRuntimeError.denied }
            try self.validateTerminalAccess(ref)
            try self.tools.stopTerminal(ref)
        }, preview: { [weak self] ref, entry, resources in
            guard let self else { throw AskProjectRuntimeError.denied }
            try self.validateTerminalAccess(ref)
            return try self.tools.terminalPreview(ref, entry: entry, resources: resources)
        })
    }

    private func validateTerminalAccess(_ ref: AskProcessRef) throws {
        guard session()?.owner == ref.ownerId, selectedId == ref.conversationId else {
            throw AskProjectRuntimeError.denied
        }
    }

    var artifactAccess: AskArtifactAccess {
        .init(load: { [weak self] ref in
            guard let self, let current = self.session(), self.selectedId == ref.conversationId else {
                throw AskArtifactError.denied
            }
            return try self.tools.loadArtifact(ref, ownerId: current.owner, conversationId: ref.conversationId)
        }, validate: { [weak self] ref in
            guard let self, let current = self.session(), self.selectedId == ref.conversationId else {
                throw AskArtifactError.denied
            }
            try self.tools.validateArtifact(ref, ownerId: current.owner, conversationId: ref.conversationId)
        }, htmlEnabled: tools.artifactPreviewEnabled)
    }

    func exportProjectPatch(_ ref: AskWorkspaceRef) throws -> Data {
        guard let current = session(), selectedId == ref.conversationId else { throw AskProjectError.denied }
        return try tools.exportProjectPatch(ref, ownerId: current.owner, conversationId: ref.conversationId)
    }

    /// This query never upgrades a tool name into a permission.
    func isGranted(_ call: AskToolCall, conversationId: String) async -> Bool {
        guard let account = session(), let value = snapshots[conversationId], let run = value.run,
              let binding = try? await tools.approvalBinding(for: call, conversationId: conversationId) else { return false }
        let request = AskToolPolicy.request(call: call, owner: account.owner, conversation: conversationId,
                                           run: run.id, step: String(run.steps), binding: binding,
                                           risk: tools.risk(of: call), reuseEnabled: approvalReuseEnabled,
                                           now: approvalStore.now())
        return approvalStore.reusableGrant(for: request) != nil
    }

    /// Screen capture needs an opened data scope in standard mode, just like files need a root.
    func automaticallyApproves(_ call: AskToolCall, risk: AskToolRisk, conversationId: String) -> Bool {
        let mode = permissionMode(conversationId: conversationId)
        if mode == .standard, call.function.name == "computer",
           (try? AskLocalTools.arguments(call.function.arguments)["action"] as? String) == "screenshot" {
            guard let messageID = screenshotConsent[conversationId],
                  snapshots[conversationId]?.messages.last(where: { $0.role == "user" })?.id == messageID else { return false }
        }
        return mode.automaticallyAllows(risk)
    }

    func resumeAutomaticallyApprovedTool(_ id: String) {
        guard let pending = approvalRequests[id],
              let call = pendingApprovals[id],
              automaticallyApproves(call, risk: pending.request.risk, conversationId: id) else { return }
        approve(conversationId: id, allowed: true, expectedApprovalID: pending.id)
    }

    func approvalRisk(_ conversationId: String) -> AskToolRisk? {
        approvalRequests[conversationId]?.request.risk
    }

    func approvalID(_ conversationId: String) -> UUID? { approvalRequests[conversationId]?.id }
    func approvalTarget(_ conversationId: String) -> String? { approvalRequests[conversationId]?.request.binding.summary }
    func mcpServerName(of call: AskToolCall) -> String? { tools.mcpServerName(of: call) }

    func canAllowForConversation(_ conversationId: String) -> Bool {
        approvalRequests[conversationId]?.request.reusable == true
    }

    func approveForConversation(_ conversationId: String, expectedApprovalID: UUID? = nil) {
        guard canAllowForConversation(conversationId) else { return }
        resolveApproval(conversationId, allowed: true, reusable: true, expected: expectedApprovalID)
    }

    func approve(conversationId: String, allowed: Bool, expectedApprovalID: UUID? = nil) {
        resolveApproval(conversationId, allowed: allowed, reusable: false, expected: expectedApprovalID)
    }

    private func resolveApproval(_ conversationId: String, allowed: Bool, reusable: Bool, expected: UUID?) {
        guard let pending = approvalRequests[conversationId], expected == nil || expected == pending.id,
              let continuation = approvals.removeValue(forKey: conversationId) else { return }
        let currentOwner = session()?.owner
        let grant = allowed && currentOwner == pending.request.context.ownerId
            ? approvalStore.issue(pending.request, reusable: reusable) : nil
        continuation.resume(returning: grant)
    }

    func stop(id: String? = nil) {
        guard let id = id ?? selected?.id, let current = credentials(for: id) else { return }
        permissionModes[id] = .standard
        tools.cancelProjects(conversationId: id)
        operations[id]?.cancel()
        approvalStore.revoke(conversation: id)
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
                if owner == current.account { pendingSends[id] = nil }
                try await accept(stopped, route: current)
            } catch { await reportOperationError(error, id: id, owner: current.account) }
        }
    }

    func delete(_ id: String) async {
        guard !busyIds.contains(id), let current = credentials(for: id) else { return }
        tools.cancelProjects(conversationId: id)
        do {
            try await api.delete(conversationId: id, token: current.token)
            guard owner == current.account else { return }
            try tools.deleteArtifacts(ownerId: current.account, conversationId: id)
            try workflowAuthoring?.remove(id)
            deletedConversationIDs.insert(id)
            // Drain a writer already inside the cache before deleting its draft.
            // New writers check the tombstone immediately before saving.
            if draftSaveConversationID == id {
                let pendingSave = draftSave
                pendingSave?.cancel()
                await pendingSave?.value
            }
            try await cache.delete(id: id, owner: current.owner)
            guard owner == current.account else { return }
            conversations.removeAll { $0.id == id }; localConversationIds.remove(id)
            drafts[id] = nil; snapshots[id] = nil; operationErrors[id] = nil; transcriptPositions[id] = nil
            sendQueue.clear(id)
            screenshotConsent[id] = nil; permissionModes[id] = nil; approvalStore.revoke(conversation: id)
            if selectedId == id { selectedId = nil; newConversation() }
            else { persistDrafts() }
        } catch { self.error = error.localizedDescription }
    }

    /// Callers await this before their operation finishes, so a conversation never looks idle
    /// and resumable while its journal still lacks the execution that just failed.
    func reportOperationError(_ error: Error, id: String, owner expectedOwner: String) async {
        guard owner == expectedOwner else { return }
        if let issue = error as? AskSubmissionIssue, selectedId == id { submissionIssues[false] = issue }
        operationErrors[id] = error.localizedDescription
        if selectedId == id { self.error = error.localizedDescription }
        if let value = snapshots[id], let route = credentials(for: id) {
            await refreshRecovery(value, route: route)
        }
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

    private func monitorConversation(id: String, current: AskRoute) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let self, owner == current.account else { return }
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

    private func acceptObserved(_ value: AskConversation, current: AskRoute) async throws {
        guard owner == current.account else { throw CancellationError() }
        if let pending = pendingSends[value.id], !value.messages.contains(where: { $0.id == pending.id }) { return }
        try await accept(value, route: current)
        if value.run?.isActive == false {
            approve(conversationId: value.id, allowed: false)
            throw CancellationError()
        }
    }
}

/// Where one conversation's calls go. `owner` partitions the cache and `token` picks the
/// backend; `account` is the session the work started in, so a sign-out or account
/// switch drops its late results even for conversations kept on this Mac.
struct AskRoute: Equatable, Sendable {
    var account: String
    var owner: String
    var token: String

    /// The same session, sent to the engine on this Mac.
    var local: AskRoute { .init(account: account, owner: AskRoutedAPI.localOwner, token: "") }
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
    var canSteer: Bool {
        selected.map { $0.run?.isActive == true && !recoveryBlocksResume($0) } == true && !isLoadingSelection
    }

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
        clearCapturedContentFeedback(launcher: false)
        sendQueue.editing = .init(conversationId: id, itemId: itemId, stash: draft)
        draft = item.draft
    }

    func saveQueuedEdit(advancing: Bool = true) {
        guard let editing = sendQueue.editing else { return }
        clearCapturedContentFeedback(launcher: false)
        normalizeScreenshotChoices()
        sendQueue.update(editing.itemId, in: editing.conversationId, draft: draft)
        sendQueue.editing = nil
        if selectedId == editing.conversationId { draft = editing.stash }
        persistDrafts()
        if advancing { queueDidSettle(editing.conversationId) }
    }

    func cancelQueuedEdit(advancing: Bool = true) {
        guard let editing = sendQueue.editing else { return }
        clearCapturedContentFeedback(launcher: false)
        sendQueue.editing = nil
        if selectedId == editing.conversationId { draft = editing.stash }
        if advancing { queueDidSettle(editing.conversationId) }
    }

    /// Hands a queued message to the running run, which reads it at its next step.
    /// A run that already ended gets it as the next turn instead.
    func steerQueued(_ itemId: String) {
        guard let value = selected, let current = credentials(for: value.id), let run = value.run, run.isActive,
              !recoveryBlocksResume(value), !steeringIds.contains(itemId), sendQueue.messages(value.id).contains(where: { $0.id == itemId }) else { return }
        if sendQueue.isEditing(value.id, itemId: itemId) { saveQueuedEdit(advancing: false) }
        guard let latest = sendQueue.messages(value.id).first(where: { $0.id == itemId }) else { return }
        let id = value.id
        steeringIds.insert(itemId)
        // A changed instruction invalidates pending intent before the network suspension.
        approvalStore.revoke(conversation: id)
        approve(conversationId: id, allowed: false)
        var message = latest.draft.request(deviceId: deviceId, tools: [], id: latest.id)
        message.skills = skillUses(latest.draft.skills)
        let request = AskSteerRequest(runId: run.id, message: message)
        Task { [weak self] in
            guard let self else { return }
            defer { steeringIds.remove(itemId) }
            do {
                let response = try await api.steer(conversationId: id, request: request, token: current.token)
                guard owner == current.account else { return }
                sendQueue.markSteered(latest, in: id)
                try await accept(response, route: current)
            } catch {
                guard owner == current.account else { return }
                // The run ended first: send it ahead of the rest of the queue.
                let refreshed = try? await api.conversation(id: id, token: current.token)
                guard owner == current.account else { return }
                if let refreshed, refreshed.run?.isActive != true {
                    sendQueue.putFirst(latest, in: id)
                    sendQueue.resume(id)
                    try? await accept(refreshed, route: current)
                    queueDidSettle(id)
                } else {
                    await reportOperationError(error, id: id, owner: current.account)
                }
            }
        }
    }

    /// Called whenever a conversation may have gone idle: settles jumped messages,
    /// pauses after a failed or stopped run, and otherwise sends the next queued message.
    func queueDidSettle(_ id: String) {
        guard let value = snapshots[id] ?? (selected?.id == id ? selected : nil) else { return }
        sendQueue.reconcile(id, transcript: value.messages, run: value.run)
        if recoveryBlocksResume(value) { sendQueue.pause(id); return }
        guard selectedId == id, selected != nil, !isLoadingSelection, !busyIds.contains(id), pendingSends[id] == nil,
              value.run?.isActive != true, let next = sendQueue.next(for: id), !steeringIds.contains(next.id),
              let item = sendQueue.take(next.id, from: id) else { return }
        submit(item.draft, newConversation: false, messageId: item.id, clearsDraft: false)
    }
}
