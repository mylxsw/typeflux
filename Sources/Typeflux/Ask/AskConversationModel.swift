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
    let launcherIconCache = AskLauncherIconCache(diskCache: .shared)
    var launcherIconWarmupEnabled = false
    /// The launcher card's visible height while its panel animates.
    let launcherViewport = AskLauncherViewport()
    /// Screen recording access shared by the open launcher's home renders.
    let launcherCapturePermissions = AskCapturePermissionSnapshot()
    /// Keyword entries reused while typing (`typingLauncherSearchEntries`).
    var launcherSearchEntriesCache: (key: LauncherSearchEntriesKey, entries: [AskLauncherSearchEntry])?
    var browserSearch: any AskBrowserSearching = AskBrowserSearchService()
    var systemCommandRunner = AskSystemCommandRunner()
    var terminalCommandDispatcher: any TerminalCommandDispatching = TerminalCommandDispatcher()
    /// Opens the built-in terminal windows; tests record the requests instead.
    var terminalRunner: any TerminalRunnerPresenting = TerminalRunnerCenter.shared
    @Published var terminalCommandSending = false
    var confirmSystemCommand: (AskSystemCommand) -> Bool = AskSystemCommandConfirmation.confirm
    var appIndex: any AskAppSearching = AskAppIndex.shared
    var launcherHomeFallbackKeywordIDs: [String] = []
    lazy var launcherInputHistory = AskLauncherInputHistoryStore(settings: modelLibrary.settings)
    @Published var quickAsk: AskQuickAskSession?
    @Published var launcherHistoryMode = false
    @Published var launcherHistoryIndex = 0
    @Published var launcherHistoryFillID: UUID?
    @Published var launcherPresentationID = UUID() { didSet { cancelAttachmentWork(launcher: true); launcherImageScope.invalidate(); workflowImageCopyTask?.cancel(); clipboardAction.cancelPreparation() } }
    var launcherDismissedAt: Date?
    var launcherExecutedInput: String?
    /// Files and folders the launcher can open; tests supply their own.
    var fileIndex: any AskFileSearching = AskFileIndex.shared
    var semanticSearch: (any SemanticFileSearching)?
    /// Whether a found file is still there; tests decide instead.
    var fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    var quickLookFile: (AskFileHit) -> Void = { AskQuickLook.shared.toggle($0.url) }
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
    var translationEngineFactory: AskTranslationEngineFactory?
    var onTranslateScreenshot: ((ScreenshotFollowUpImage) -> Void)?
    var onMoveTranslationToPanel: ((AskPluginSession, () -> Void) -> Bool)?
    lazy var translationFanout = translationEngineFactory?.makeSession() ?? AskTranslationFanout()
    lazy var translationSettingsModel = AskTranslationSettingsModel(store: modelLibrary.settings)
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
    var wordBookTask: Task<Void, Never>?
    /// Opens the word book dialog on a word; tests record it instead.
    var openWordBook: @MainActor (String?) -> Void = { key in AskWordBookWindowController.shared.show(selecting: key) }
    /// Opens the word book and looks a word up there; tests record it instead.
    var lookUpInWordBook: @MainActor (String) -> Void = { text in
        AskWordBookWindowController.shared.show(lookingUp: text)
    }
    var workflowImageCopyTask: Task<Void, Never>?
    /// Saved AI prompt results; the window controller supplies them (`AskConversationModel+Notes`).
    var notebookTask: Task<Void, Never>?
    var notebookReadTask: Task<Bool, Never>?
    var notes: (any AskNoteStoring)? { didSet { refreshAnswerNotes() } }
    /// The shown result's text and the note it was saved as, so ⌘S again takes it out.
    var launcherNote: (body: String, id: UUID)?
    /// Opens the notes window on a note; tests record it instead.
    var openNotes: @MainActor (UUID?) -> Void = { id in AskNotesWindowController.shared.show(selecting: id) }
    /// Opens the notes window on a new note with this title; tests record it instead.
    var createNote: @MainActor (String) -> Void = { AskNotesWindowController.shared.showNewNote(title: $0) }
    /// Shows a result moved out of the launcher (⌘O); tests record it instead.
    var presentResultWindow: @MainActor (AskResultDocument) -> Void = { AskResultWindowController.shared.present($0) }
    /// Opens a saved note in a result window; tests record it instead.
    var openNoteWindow: @MainActor (AskNote) -> Void = { AskResultWindowController.shared.open($0) }
    /// What result windows opened from the launcher can do.
    var resultWindowServices: AskResultDocument.Services { AskResultWindowController.shared.services }
    /// The system monitor in the launcher (`top`); see `AskConversationModel+SystemMonitor`.
    lazy var emojiUsage = EmojiUsageStore(defaults: modelLibrary.settings.defaults)
    let systemMonitor = SystemMonitorLauncherModel()
    lazy var calendarLauncher = CalendarLauncherModel()
    /// This Mac's configuration in the launcher (`sys`); see `AskConversationModel+SystemInfo`.
    let systemInfo = SystemInfoLauncherModel()
    /// What `sys` reads the configuration with; tests use their own.
    lazy var systemInfoStore: SystemInfoStore = .shared
    /// The monitor's own window (⌘O from the launcher); tests use their own.
    lazy var systemMonitorWindow: SystemMonitorWindowController = .shared
    /// The launcher's keyword plugins (`fy` → translate); see `AskConversationModel+Plugins`.
    lazy var plugins: AskPluginSession = {
        let session = AskPluginSession(plugins: makeLauncherPlugins()) { [weak self] in
            self?.launcherKeywords ?? AskPluginRegistry.defaultKeywords
        }
        connectWordBook(to: session)
        connectNotes(to: session)
        session.launcherIconCache = launcherIconCache
        session.onActivate = { [weak self] keyword in self?.keywordUsage.record(keyword) }
        session.onRunInput = { [weak self] keyword, text, title in
            self?.recordLauncherInput(destination: .keyword, label: title, text: text, keyword: keyword.keyword)
        }
        return session
    }()
    /// How often each launcher keyword is used, for the launcher's home.
    lazy var keywordUsage = AskKeywordUsageStore(defaults: defaults)
    /// Types text into the app the launcher came from; the window controller supplies it.
    var deliverText: ((String) async throws -> Void)?
    /// The existing clipboard history; supplied by the app's shared store.
    var clipboardEntries: @MainActor @Sendable () -> [ClipboardEntry] = { [] }
    let clipboardAction = ClipboardContentAction()
    var clipboardContentActions: any ClipboardContentActing = SystemClipboardContentActions()
    @Published var launcherClipboardPreview: ClipboardEntry?
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
    var customInference: any AskModelCompleting
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
        let current = launcher ? launcherDraft : draft
        // A temporary question may use Cloud models; its own model decides where it runs.
        if current.temporary == true { return false }
        return current.storesLocally ?? commandSources.privateByDefault()
    }

    /// Only a conversation that has not started can still choose where it is stored,
    /// so none is ever half uploaded and half kept on this Mac.
    func canChangeStorage(launcher: Bool) -> Bool {
        isSignedIn && (launcher || selectedId == nil)
    }

    func setStoresLocally(_ value: Bool, launcher: Bool) {
        guard canChangeStorage(launcher: launcher) else { return }
        if launcher {
            launcherDraft.storesLocally = value; launcherDraft.temporary = nil
        } else {
            draft.storesLocally = value
            if draft.temporary == true { draft.temporary = nil; draft.memory = capture.globalMemory() ?? AskMemory() }
        }
        persistDrafts()
    }

    /// The conversation is kept on this Mac rather than in the Typeflux Cloud account.
    /// A temporary conversation counts as local while it runs on the user's own model.
    func isLocal(_ id: String) -> Bool {
        if let temporary = temporaryConversation, temporary.id == id { return !isSignedIn || !temporary.cloud }
        return !isSignedIn || localConversationIds.contains(id)
    }

    func registerLocalHistory(_ items: [AskConversationSummary]) {
        localConversationIds.formUnion(items.map(\.id))
    }

    func isDeletedConversation(_ id: String) -> Bool { deletedConversationIDs.contains(id) }

    /// The cache partition of a conversation's copies and drafts.
    func cacheOwner(_ id: String) -> String {
        if isTemporary(id) { return AskRoutedAPI.temporaryOwner }
        return localConversationIds.contains(id) ? AskRoutedAPI.localOwner : owner
    }
    func requiresVision(launcher: Bool) -> Bool {
        let current = launcher ? launcherDraft : draft
        return current.sendsImage
            || (!launcher && selected?.messages.contains(where: { $0.hasImage }) == true)
    }

    @Published var isOpeningChat = false
    @Published var savedChatDrafts: [AskSavedChatDraft] = []
    var chatDraftWrites: [String: [String: AskChatDraftWrite]] = [:]
    var featureRoute: (FeatureCommand) async throws -> Data = { try await FeatureProcess.route($0) }
    var acceptedFeatureHandoffs: Set<String> = []
    var externallyDrivenConversations: Set<String> = []
    var activeChatDraftID: String?
    var pendingDraftHandoff: AskDraftHandoff?
    var chatDraftSubmissions: [String: AskDraftHandoffSubmission] = [:]
    @Published var referenceLocation: String?
    @Published var launcherWindowMode: AskLauncherWindowMode = .complete
    @Published var launcherDraft = AskDraft(includeScreenshot: false) {
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
    let attachmentWork = AskAttachmentWork()
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
    /// The one temporary conversation, while it lasts; see `AskConversationModel+Temporary`.
    @Published private(set) var temporaryConversation: AskTemporaryConversation?
    /// Asks before a temporary conversation with messages is left; tests answer instead.
    var confirmTemporaryLeave: @MainActor () -> AskTemporaryLeaveDecision = AskTemporaryLeaveConfirmation.confirm
    @Published private(set) var selected: AskConversation?
    @Published private(set) var selectedId: String? { didSet { if selectedId != oldValue { refreshAnswerNotes() } } }
    /// Answers of the shown conversation that are in the notebook, by message id.
    @Published var answerNoteIDs: [String: UUID] = [:]
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
    /// At most one automatic reconciliation per run in this process.
    var automaticRecoveryAttempts: Set<String> = []
    var automaticRecoveryEnabled = true
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
    @Published private(set) var historyHasPendingSync = false
    private var historySyncTask: Task<Void, Never>?
    private var pullRefreshID: UUID?
    private var historyErrorTask: Task<Void, Never>?
    @Published var historyHasMore = false
    @Published var controllingConversationId: String?

    var onShowConversation: (() -> Void)?
    var onOpenSettings: ((StudioSection) -> Void)?
    var onOpenFeedback: (() -> Void)?
    /// Opens the usage guide, searching for the text when it is not empty; set by the app.
    var onOpenHelp: ((String) -> Void)?
    /// Starts a screenshot, going straight to a follow-up when there is one; set by the app,
    /// which owns the screenshot coordinator.
    var onStartScreenshot: ((ScreenshotMode, ScreenshotFollowUp?) -> Void)?
    /// Shows the launcher, then runs the closure once its context is in (`AskConversationModel+Screenshot`).
    var onShowLauncher: ((@escaping @MainActor () -> Void) -> Void)?
    /// The screenshot handed to the launcher, while its text shows there.
    var launcherScreenshot: AskLauncherScreenshot? {
        didSet { if oldValue?.source.id != launcherScreenshot?.source.id { oldValue?.source.recognition.cancel() } }
    }
    deinit { launcherScreenshot?.source.recognition.cancel() }
    /// Reads a screenshot's text, band by band when it is long.
    var screenshotTextRecognizer: any ImageTextRecognizing = TiledImageTextRecognizer(base: VisionImageTextRecognizer())
    var onSignIn: () -> Void = { LoginWindowController.shared.show() }
    var onControlChanged: ((Bool) -> Void)?
    /// Called when Typeflux Cloud reports no credits left, so the account balance can refresh.
    var onCreditsExhausted: (() -> Void)?
    var recordingIsActive: () -> Bool = { false }

    let api: any AskAPI
    let cache: any AskCaching
    let tools: any AskToolExecuting
    let workspaces: AskConversationWorkspaceStore?
    private let capture: any AskContextCapturing
    let session: () -> (owner: String, token: String)?
    let deviceId: String
    var owner = ""
    var titleTasks: [String: Task<Void, Never>] = [:]
    var titleRetryAfter: [String: Date] = [:]
    private var operations: [String: Task<Void, Never>] = [:]
    private var operationIds: [String: UUID] = [:]
    var operationGenerations: [String: UUID] = [:]
    private struct OperationOwner {
        let account: String
        let conversationId: String
    }
    private var operationOwners: [UUID: OperationOwner] = [:]
    private var operationRuns: [UUID: AskProjectScope] = [:]
    private var approvals: [String: CheckedContinuation<String?, Never>] = [:]
    private var approvalRequests: [String: (id: UUID, request: AskApprovalRequest)] = [:]
    let approvalStore = AskApprovalStore()
    var expiredFolderNotices: Set<String> = []
    var cloudApprovals: [String: (id: String, request: AskApprovalRequest)] = [:]
    private let approvalReuseEnabled: Bool
    private var operationErrors: [String: String] = [:]
    private var pendingSends: [String: AskSendRequest] = [:]
    private var queueSession = UUID()
    private struct QueueFlight {
        let attempt: UUID
        let owner: String
        let device: String
        let originalDevice: String
        let session: UUID
        let selection: UUID
        let claim: AskSendQueue.Claim
        var task: Task<Void, Never>?
    }
    private var queueFlights: [String: [String: QueueFlight]] = [:]
    private var queuedSubmissions: [String: AskSendQueue.Claim] = [:]
    private var queuedOperations: Set<UUID> = []
    private var queuedSubmissionSelections: [String: UUID] = [:]
    // Local consent for the latest submission, retained for retries but never restored from history.
    private var screenshotConsent: [String: String] = [:]
    var captureGeneration = UUID()
    let launcherImageScope = AskImagePresentationScope()
    let conversationImageScope = AskImagePresentationScope()
    let remoteImageScope = AskRemoteImageScope()
    var selectionGeneration = UUID() { didSet { cancelAttachmentWork(launcher: false); remoteImageScope.invalidate(); conversationImageScope.invalidate() } }
    private var selectionObservation: Task<Void, Never>?

    func stopSelectionObservation() {
        selectionObservation?.cancel()
        selectionObservation = nil
    }
    private var draftSave: Task<Void, Never>?
    private var draftSaveConversationID: String?
    private var deletedConversationIDs: Set<String> = []
    /// Temporary conversations being kept; ending them meanwhile would delete what the user saved.
    private var keepingTemporaryIDs: Set<String> = []
    private var imageAuthObserver: AnyCancellable?
    private var authObserver: AnyCancellable?
    private var modelObserver: AnyCancellable?
    private var memoryObserver: AnyCancellable?
    private var notesObserver: AnyCancellable?
    private let defaults: UserDefaults
    private let memoryInvalidations: MemoryInvalidationStore
    private var memoryPurgeTask: Task<Void, Never>?
    private var memoryPurgeGeneration = 0
    static let memoryPurgePendingKey = "ask.memory.purgePending"

    init(api: any AskAPI, cache: any AskCaching, tools: any AskToolExecuting,
         workspaces: AskConversationWorkspaceStore? = nil,
         capture: any AskContextCapturing, deviceId: String, modelLibrary: AskModelLibrary? = nil,
         defaults: UserDefaults = .standard,
         trustedApprovalPeer: AskHarnessContract? = nil, scopedApprovalEnabled: Bool = false,
         session: @escaping () -> (owner: String, token: String)?,
         modelClient: any AskModelCompleting = AskCustomInference()) {
        self.customInference = modelClient
        self.modelLibrary = modelLibrary ?? .shared
        self.api = api; self.cache = AskTemporaryCache(base: cache); self.tools = tools
        self.workspaces = workspaces; self.capture = capture
        self.deviceId = deviceId; self.session = session; self.defaults = defaults
        quickSearch.launcherIconCache = launcherIconCache
        memoryInvalidations = MemoryInvalidationStore(defaults: defaults)
        // Only DI-supplied, trusted advertisements may enable reuse. Conversation metadata is inert.
        approvalReuseEnabled = AskHarnessContract(version: 1, capabilities: [AskHarnessCapability.scopedApproval.rawValue])
            .permits(.scopedApproval, peer: trustedApprovalPeer, enabled: scopedApprovalEnabled ? [.scopedApproval] : [])
        launcherDraft = newQuestionDraft()
        normalizeScreenshotChoices()
        modelObserver = self.modelLibrary.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                normalizeScreenshotChoices()
                objectWillChange.send()
            }
        }
        authObserver = NotificationCenter.default.publisher(for: .authDidLogout).sink { [weak self] _ in
            if Thread.isMainThread { MainActor.assumeIsolated { self?.resetSession() } }
            else { Task { @MainActor in self?.resetSession() } }
        }
        imageAuthObserver = NotificationCenter.default.publisher(for: .authDidLogin)
            .merge(with: NotificationCenter.default.publisher(for: .authTokenDidRefresh)).sink { [weak self] _ in
                Task { @MainActor in self?.invalidateRemoteImages() }
            }
        notesObserver = NotificationCenter.default.publisher(for: .askNotesDidChange).sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshAnswerNotes()
                do {
                    if let saved = self.launcherNote,
                       try await self.notes?.note(id: saved.id).map({ !$0.isDeleted }) != true,
                       self.launcherNote?.id == saved.id {
                        self.launcherNote = nil
                        self.plugins.showNoteSaved(false)
                    }
                } catch { self.confirm(L("ask.notes.storageUnavailable")) }
            }
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
        if let id, let temporary = temporaryConversation, temporary.id == id { return account.temporary(cloud: temporary.cloud) }
        let local = id.map(isLocal) ?? storesLocally(launcher: false)
        return local ? account.local : account
    }

    func resetSession() {
        acceptedFeatureHandoffs.removeAll()
        externallyDrivenConversations.removeAll()
        tools.resetFolderSession()
        expiredFolderNotices = []
        quickAsk = nil
        if let temporary = temporaryConversation, !keepingTemporaryIDs.contains(temporary.id), let workspaces {
            let account = owner
            Task {
                do { try await workspaces.discard(owner: account, conversationId: temporary.id) }
                catch { ErrorLogStore.shared.log("Ask temporary workspace cleanup failed: \(error.localizedDescription)") }
            }
        }
        releaseLauncherScreenshot()
        launcherIconCache.clear()
        workflowImageCopyTask?.cancel()
        launcherImageScope.invalidate(); conversationImageScope.invalidate()
        cancelAttachmentWork()
        notebookTask?.cancel()
        notebookReadTask?.cancel()
        wordBookTask?.cancel()
        wordBook?.beginSession()
        quickSearch.cancel()
        quickSearch.results = nil
        recoveryGeneration = UUID(); recoveryWorking = false; inspectingRecovery = false
        recoveryEntries = [:]
        automaticRecoveryAttempts = []
        capturedContentFeedbackTasks.values.forEach { $0.cancel() }
        capturedContentFeedbackTasks = [:]
        capturedContentChanges = [:]
        workflowAuthoring?.reset()
        tools.cancelProjects(conversationId: nil)
        voiceInput.cancel()
        historyErrorTask?.cancel(); historyRefreshError = nil
        historySyncTask?.cancel(); historySyncTask = nil; historyHasPendingSync = false
        pullRefreshID = nil; isRefreshingHistory = false
        titleTasks.values.forEach { $0.cancel() }; titleTasks = [:]; titleRetryAfter = [:]
        operations.values.forEach { $0.cancel() }; operations = [:]; operationIds = [:]; operationGenerations = [:]; operationRuns = [:]; operationOwners = [:]
        submissionPreflights = [:]; submissionIssues = [:]
        approvals.values.forEach { $0.resume(returning: nil) }; approvals = [:]; approvalRequests = [:]; approvalStore.reset()
        inferenceUsage = [:]
        pendingApprovals = [:]; busyIds = []; pendingSends = [:]; operationErrors = [:]
        queueSession = UUID()
        for flights in queueFlights.values { for flight in flights.values { flight.task?.cancel() } }
        queueFlights = [:]; queuedSubmissions = [:]; queuedSubmissionSelections = [:]; queuedOperations = []
        sendQueue = AskSendQueue(); steeringIds = []
        screenshotConsent = [:]
        cloudApprovals = [:]
        permissionModes = [:]; launcherPermissionMode = .standard; draftPermissionMode = .standard
        draftSave?.cancel(); draftSaveConversationID = nil; deletedConversationIDs = []; captureGeneration = UUID(); selectionGeneration = UUID()
        selectionObservation?.cancel(); selectionObservation = nil
        inferenceProgress = [:]; progressInferenceIDs = [:]
        selected = nil; selectedId = nil; isLoadingSelection = false; selectionLoadFailed = false
        snapshots = [:]; drafts = [:]; transcriptPositions = [:]; savedChatDrafts = []
        activeChatDraftID = nil; pendingDraftHandoff = nil; chatDraftSubmissions = [:]
        historyGeneration = UUID(); historyOffset = 0; conversations = []; localConversationIds = []
        // In memory only, so a new session never sees it; the server expires its copy.
        temporaryConversation = nil; keepingTemporaryIDs = []
        launcherScreenshotNotice = nil; screenshotNotice = nil; recoveringImages = [:]
        attachmentNotice = nil; launcherAttachmentNotice = nil
        attachmentLoads[visionDraftKey(launcher: true)] = nil
        launcherDraft = newQuestionDraft(); draft = .followUp; launcherContextRestored = false
        launcherHistoryMode = false; launcherHistoryIndex = 0; launcherHistoryFillID = nil
        launcherPresentationID = UUID(); launcherExecutedInput = nil; launcherDismissedAt = nil
        capturing = false; capturingScreenshot = false
        controllingConversationId = nil; onControlChanged?(false); owner = ""
    }

    /// New questions inherit screen access without requesting it. Saved drafts keep their choice.
    func newQuestionDraft() -> AskDraft { AskDraft(includeScreenshot: capture.screenCaptureAllowed) }

    var screenCaptureAllowed: Bool { capture.screenCaptureAllowed }

    func makeLauncherSelectionRequest() -> ReadOnlySelectionRequest { capture.makeSelectionRequest() }
    func restoreLauncherContextMarker(_ restored: Bool) { launcherContextRestored = restored }

    func prepareLauncher(request: ReadOnlySelectionRequest? = nil) async {
        let request = request ?? makeLauncherSelectionRequest()
        guard !Task.isCancelled else { return }
        flushMemoryPurge()
        captureWarning = nil
        normalizeScreenshotChoices()
        if let current = session(), owner != current.owner { resetSession(); owner = current.owner }
        let expectedOwner = owner
        let expectedSessionOwner = session()?.owner
        let generation = UUID(); captureGeneration = generation; capturing = false; capturingScreenshot = false
        if !capture.screenCaptureAllowed { launcherDraft.includeScreenshot = false }
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

    func openScreenCaptureSettings() { capture.openScreenCaptureSettings() }

    func refreshScreenshot(launcher: Bool) async {
        guard !Task.isCancelled, !capturing || capturingScreenshot,
              screenshotCapability(launcher: launcher).canAttach else { return }
        guard capture.requestScreenCapturePermission() else {
            captureWarning = AskContextCapture.missingScreenshotWarning(allowed: false)
            if (launcher ? launcherDraft : draft).screenshot == nil { clearCapturedContentFeedback(launcher: launcher) }
            persistDrafts()
            return
        }
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
            if (launcher ? launcherDraft : draft).screenshot == nil { clearCapturedContentFeedback(launcher: launcher) }
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

    func flushFeatureDrafts() async {
        persistDrafts()
        await draftSave?.value
        if selectedId == nil, draft.hasChatInput, draft.temporary != true, activeChatDraftID == nil {
            _ = try? await stageChatDraft(draft, account: owner)
        }
    }

    func persistDrafts() {
        draftSave?.cancel()
        // While a queued message is open in the composer, the conversation's own draft is the stash.
        let editing = sendQueue.editing.flatMap { $0.conversationId == selectedId ? $0.stash : nil }
        // Launcher input is kept in local history, never restored as an active draft.
        let launcher = newQuestionDraft(), followUp = editing ?? draft, owner = owner
        let id = isLoadingSelection ? nil : selectedId.flatMap { deletedConversationIDs.contains($0) ? nil : $0 }
        let followUpOwner = id.map(cacheOwner) ?? owner
        // Privacy cleanup must not be cancelled by the next debounced edit.
        if followUp.temporary == true { detachChatDraft() }
        let recoveryKey = id == nil ? activeChatDraftID : nil
        if let id, !isLoadingSelection { drafts[id] = followUp }
        draftSaveConversationID = id
        draftSave = Task { [cache] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                try await cache.saveDraft(launcher, key: "launcher", owner: owner)
                try Task.checkCancellation()
                if let recoveryKey {
                    try await saveChatDraft(followUp, key: recoveryKey, account: owner)
                }
                try Task.checkCancellation()
                if let id, self.owner == owner, !deletedConversationIDs.contains(id) {
                    try await cache.saveDraft(followUp, key: id, owner: followUpOwner)
                }
                if self.error == L("ask.cache.failed"),
                   !self.selectedRecoveryEntries.contains(where: \.readUnavailable) { self.error = nil }
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
            observeHistorySynchronization(current)
        } catch {
            if owner == current.account, generation == historyGeneration {
                if inlineError { historyRefreshError = L("ask.history.refreshFailed") }
                else { self.error = error.localizedDescription }
            }
        }
    }

    func refreshAfterAccountChange() async {
        let localSelection = selectedId.flatMap { id in
            localConversationIds.contains(id) || (owner == AskRoutedAPI.localOwner && conversations.contains { $0.id == id })
                ? id : nil
        }
        guard credentials() != nil else { return }
        let selection = selectionGeneration
        await refreshHistory()
        guard selection == selectionGeneration, session()?.owner == owner else { return }
        if let localSelection {
            localConversationIds.insert(localSelection)
            await select(localSelection)
        }
        await loadSavedChatDrafts()
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
        guard leaveTemporaryConversation(for: id) else { return }
        let previousOwner = owner
        let accountChanged = !previousOwner.isEmpty && previousOwner != session()?.owner
        let wasLocal = localConversationIds.contains(id)
            || (previousOwner == AskRoutedAPI.localOwner && conversations.contains { $0.id == id })
        let localRow = accountChanged && wasLocal ? conversations.first { $0.id == id } : nil
        guard credentials() != nil else { return }
        if accountChanged {
            // The row may have been clicked before the new account's history loaded.
            // Keep local rows on their local route; discard rows from the old Cloud account.
            if wasLocal {
                localConversationIds.insert(id)
                if let localRow { conversations = [localRow] }
            }
            Task { await refreshHistory() }
            guard wasLocal else { return }
        }
        guard let current = credentials(for: id) else { return }
        if selectedId == id, isLoadingSelection || (!reload && selected != nil && !selectionLoadFailed) { return }
        clearCapturedContentFeedback(launcher: false)
        voiceInput.cancel()
        cancelQueuedEdit(advancing: false)
        selectionObservation?.cancel(); selectionObservation = nil
        let generation = UUID(); selectionGeneration = generation
        let selectingSession = queueSession
        detachChatDraft()
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
            guard owner == current.account, session()?.owner == current.account,
                  selectingSession == queueSession, !deletedConversationIDs.contains(id) else { return }
            reconcileConfirmedSupplements(fromAuthenticated: value)
            let hasUnconfirmedMessage = pendingSends[id].map { pending in !value.messages.contains { $0.id == pending.id } } ?? false
            if !hasUnconfirmedMessage { try await cache.save(value, owner: current.owner) }
            let latest = try await cache.load(id: id, owner: current.owner) ?? value
            guard owner == current.account, session()?.owner == current.account,
                  selectingSession == queueSession, !deletedConversationIDs.contains(id) else { return }
            snapshots[id] = sanitizedMemory(snapshots[id]?.reconciling(latest) ?? latest,
                                            account: current.account, local: current.token.isEmpty)
            reconcileConfirmedQueuedSubmission(fromAuthenticated: value)
            guard generation == selectionGeneration else { return }
            selected = snapshots[id] ?? latest; isLoadingSelection = false
            await refreshRecovery(selected ?? latest, route: current)
            guard generation == selectionGeneration, owner == current.account else { return }
            switchToVisionModelIfNeeded(launcher: false); normalizeScreenshotChoices()
            error = selectedRecoveryEntries.contains(where: \.readUnavailable)
                ? L("ask.cache.failed") : operationErrors[id]
            queueDidSettle(id)
            // Observe active runs without resuming desktop tools or inference.
            if latest.run?.isActive == true, !busyIds.contains(id) {
                selectionObservation = monitorConversation(id: id, current: current)
            }
            updateSummary(selected ?? latest)
            scheduleTitle(selected ?? latest, route: current)
            // Reconcile persisted results and inspect uncertain effects without
            // replaying the original action.
            await recoverWithoutUser()
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
    /// `temporary` starts a temporary conversation instead, which never enters history.
    @discardableResult
    func newConversation(storesLocally: Bool? = nil, temporary: Bool = false) -> Bool {
        guard leaveTemporaryConversation(for: nil) else { return false }
        detachChatDraft()
        draftPermissionMode = .standard
        clearCapturedContentFeedback(launcher: false)
        selectionObservation?.cancel(); selectionObservation = nil
        voiceInput.cancel()
        cancelQueuedEdit(advancing: false)
        persistDrafts()
        selectionGeneration = UUID(); selected = nil; selectedId = nil
        isLoadingSelection = false; selectionLoadFailed = false
        captureGeneration = UUID(); capturing = false; capturingScreenshot = false
        draft = newQuestionDraft(); submissionIssues[false] = nil; error = nil; captureWarning = nil; screenshotNotice = nil; visionSwitch = nil
        attachmentNotice = nil
        if isSignedIn { draft.storesLocally = storesLocally }
        // No source app is trustworthy here, so only global memory applies.
        // A temporary conversation uses none.
        draft.temporary = temporary ? true : nil
        draft.memory = temporary ? AskMemory() : capture.globalMemory() ?? AskMemory()
        return true
    }

    func submitLauncher(recordInput: Bool = true) {
        if plugins.keyword?.pluginID == AskQuickAskPlugin.id { submitQuickAsk(); return }
        guard !isTerminalCommandMode, !isTerminalCommandInput(launcherDraft.text) else { return }
        if consumeModeCommand(launcher: true) { return }
        normalizeScreenshotChoices()
        guard canSendLauncher else { return }
        if !FeatureProcess.owns(.chat) {
            let incoming = launcherDraft
            Task { _ = await transferFeatureDraft(incoming, submit: true) }
            return
        }
        // The launcher always starts a new conversation, so it leaves a temporary one.
        guard leaveTemporaryConversation(for: nil) else { return }
        // A temporary question leaves no trace in the launcher's input history either.
        if recordInput, launcherDraft.temporary != true { recordLauncherInput(destination: .askAI) }
        submit(launcherDraft, newConversation: true, launcher: true)
    }
    func addReference(_ reference: AskReference) {
        var updated = draft
        updated.references = (updated.references ?? []) + [reference]
        guard updated.referencesWithinLimit else { error = L("ask.input.tooLarge"); return }
        draft = updated
    }

    @discardableResult
    func submitDraft() -> Bool {
        if consumeModeCommand(launcher: false) { return true }
        normalizeScreenshotChoices()
        guard !isLoadingAttachments(launcher: false) else { return false }
        if isEditingQueued { saveQueuedEdit(); return true }
        if canQueue, let id = selected?.id {
            sendQueue.enqueue(draft, to: id)
            clearCapturedContentFeedback(launcher: false)
            draft = .followUp; persistDrafts()
            return true
        }
        guard canSendNow else { return false }
        return submit(draft, newConversation: selectedId == nil)
    }

    /// Sends `text` as a follow-up in the selected conversation, leaving whatever
    /// the user is typing in the composer untouched.
    func sendFollowUp(_ text: String, recoveryCheck: Bool = false) {
        guard selected != nil else { return }
        var followUp = AskDraft.followUp
        followUp.text = text
        submit(followUp, newConversation: false, clearsDraft: false, recoveryCheck: recoveryCheck)
    }

    /// `messageId` keeps a queued message's ID; `clearsDraft` is false when the queue
    /// sends on its own, so whatever the user is typing stays in the composer.
    @discardableResult
    private func submit(_ submitted: AskDraft, newConversation: Bool, messageId queuedId: String? = nil,
                        clearsDraft: Bool = true, launcher: Bool = false, recoveryCheck: Bool = false, quickAskGeneration: UUID? = nil) -> Bool {
        var transferred = false
        let queuedConversation = queuedId == nil ? nil : selectedId
        defer {
            if !transferred, let id = queuedConversation { restoreQueuedSubmission(id) }
        }
        guard submissionPreflights[launcher] == nil else { return false }
        guard submitted.referencesWithinLimit, submitted.text.utf8.count <= 32000,
              (submitted.sentSelection?.utf8.count ?? 0) <= 64000,
              (submitted.sentSource?.utf8.count ?? 0) <= 1000,
              (submitted.attachments ?? []).reduce(0, { $0 + $1.payloadBytes }) <= AskAttachmentLimits.maximumPayloadBytes else {
            rejectSubmission(.init(text: L("ask.input.tooLarge")), submitted: submitted, queuedId: queuedId, launcher: launcher)
            return false
        }
        guard let account = credentials() else {
            rejectSubmission(.init(text: L("ask.loginRequired"), offersSignIn: true),
                             submitted: submitted, queuedId: queuedId, launcher: launcher)
            return false
        }
        guard newConversation || selected != nil else { return false }
        if !newConversation, let selected, !admitAgentCommand(selected) { return false }
        let temporary = newConversation && submitted.temporary == true
        let requested = submitted.modelRef ?? (newConversation ? modelLibrary.defaultReference
                                               : selected?.modelRef ?? "cloud:default")
        // A temporary conversation runs where its model does: Cloud models in Typeflux Cloud,
        // the user's own models on this Mac, so they never pass through the server.
        let local = temporary
            ? account.token.isEmpty || !requested.hasPrefix("cloud:")
            : newConversation
                ? account.token.isEmpty || (submitted.storesLocally ?? commandSources.privateByDefault())
                : selectedId.map(isLocal) == true
        let hasImage = submitted.sendsImage || (!newConversation && selected?.messages.contains { $0.hasImage } == true)
        let reference = localFallback(requested, hasImage: hasImage, local: local)
        let token = local ? "" : account.token
        // Catalog refresh and Ollama probing may suspend. Reserve the submission only;
        // history, cache, tool grants and window changes happen after they succeed.
        let needsRefresh = (reference.hasPrefix("cloud:") && reference != "cloud:default")
            || modelLibrary.registry.resolve(reference)?.0.isOllama == true
        if !needsRefresh {
            if let reason = modelSelectionIssue(reference, cloudAvailable: !token.isEmpty, hasImage: hasImage) {
                rejectSubmission(reason, submitted: submitted, queuedId: queuedId, launcher: launcher)
                return false
            }
            submissionIssues[launcher] = nil
            transferred = true
            return submitValidated(submitted, modelRef: reference, local: local, newConversation: newConversation, messageId: queuedId,
                            clearsDraft: clearsDraft, launcher: launcher, temporary: temporary, recoveryCheck: recoveryCheck, quickAskGeneration: quickAskGeneration)
        }
        let id = newConversation ? UUID().uuidString.lowercased() : selected!.id
        guard !busyIds.contains(id) else { return false }
        let generation = selectionGeneration
        let operationId = UUID()
        submissionPreflights[launcher] = operationId
        busyIds.insert(id); registerOperation(id, operationId: operationId, account: account.account)
        transferred = true
        operations[id] = Task { [weak self] in
            guard let self else { return }
            var handled = false
            defer {
                if !handled, owner == account.account, session()?.owner == account.account,
                   !deletedConversationIDs.contains(id), queuedId != nil {
                    restoreQueuedSubmission(id)
                }
                if submissionPreflights[launcher] == operationId { submissionPreflights[launcher] = nil }
                finishOperation(id, operationId: operationId)
            }
            do {
                try checkOperation(id, operationId: operationId, account: account.account)
                try await validateModel(reference, token: token, hasImage: hasImage)
                try Task.checkCancellation()
                guard owner == account.account, session()?.owner == account.account else { return }
                guard quickAskGeneration.map({ self.quickAsk?.generation == $0 }) ?? (selectionGeneration == generation) else { return }
                handled = true
                submissionIssues[launcher] = nil
                busyIds.remove(id)
                submitValidated(submitted, modelRef: reference, local: local, newConversation: newConversation, messageId: queuedId,
                                clearsDraft: clearsDraft, launcher: launcher, temporary: temporary, recoveryCheck: recoveryCheck, quickAskGeneration: quickAskGeneration)
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, operationIds[id] == operationId,
                      owner == account.account, session()?.owner == account.account,
                      quickAskGeneration.map({ self.quickAsk?.generation == $0 }) ?? (selectionGeneration == generation) else { return }
                let issue = modelSelectionIssue(reference, cloudAvailable: !token.isEmpty, hasImage: hasImage)
                    ?? AskSubmissionIssue(text: error.localizedDescription, offersModels: true)
                handled = true
                rejectSubmission(issue, submitted: submitted, queuedId: queuedId, launcher: launcher)
            }
        }
        return true
    }

    private func rejectSubmission(_ issue: AskSubmissionIssue, submitted: AskDraft, queuedId: String?, launcher: Bool) {
        submissionIssues[launcher] = issue
        if !launcher || plugins.keyword?.pluginID != AskQuickAskPlugin.id { error = issue.text }
        if queuedId != nil, let id = selectedId { restoreQueuedSubmission(id) }
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

    private func stageFolderSubmission(_ submitted: AskDraft, conversation: AskConversation, route: AskRoute,
                                       messageID: String, generation: UUID) -> Bool {
        let id = conversation.id
        let folders = (submitted.attachments ?? []).compactMap { $0.kind == .folder ? $0.path : nil }
        if folders.isEmpty, tools.temporaryFolders(conversationId: id).isEmpty,
           conversation.messages.contains(where: { message in
               (message.attachments ?? []).contains { attachment in
                   attachment.kind == .folder && (attachment.path.map { !hasSettingsFolder($0) } ?? true)
               }
           }),
           expiredFolderNotices.insert(id).inserted {
            attachmentNotice = L("ask.folder.expired")
        }
        do {
            try tools.stageFolders(folders, lifetime: .conversationSession,
                                   ownerId: route.account, deviceId: deviceId, conversationId: id,
                                   messageID: messageID, generation: generation)
        } catch {
            busyIds.remove(id)
            operationErrors[id] = error.localizedDescription
            self.error = error.localizedDescription
            return false
        }
        return true
    }

    private func admitFolderSubmission(_ response: AskConversation, conversationID: String,
                                       messageID: String, previousRunID: String?) throws {
        // Only this send's response can admit its local folder selection.
        // A displayed/observed run or retried historical message cannot mint authority.
        if response.id == conversationID, let run = response.run, run.deviceId == deviceId,
           run.id != previousRunID, response.messages.last(where: { $0.role == "user" })?.id == messageID {
            try tools.admitFolders(messageID: messageID, conversationId: conversationID, runId: run.id)
            if !run.isActive { tools.revokeTaskFolders(conversationId: conversationID, runId: run.id) }
        }
    }

    @discardableResult
    private func submitValidated(_ submitted: AskDraft, modelRef: String, local: Bool, newConversation: Bool, messageId queuedId: String? = nil,
                                 clearsDraft: Bool = true, launcher: Bool = false, temporary: Bool = false,
                                 recoveryCheck: Bool = false, quickAskGeneration: UUID? = nil) -> Bool {
        var admitted = false
        let queuedConversation = queuedId == nil ? nil : selectedId
        defer {
            if !admitted, let id = queuedConversation {
                busyIds.remove(id)
                restoreQueuedSubmission(id)
            }
        }
        guard let account = credentials() else { return false }
        guard newConversation || selected != nil else { return false }
        let inline = quickAskGeneration != nil
        if let quickAskGeneration, quickAsk?.generation != quickAskGeneration { return false }
        let id = newConversation ? UUID().uuidString.lowercased() : selected!.id
        guard !busyIds.contains(id) else { return false }
        if inline { quickAsk?.conversationId = id }
        if temporary {
            // Only one temporary conversation exists; the UI asked before leaving the last one.
            discardTemporaryConversation()
            temporaryConversation = AskTemporaryConversation(id: id, cloud: !local)
        } else if newConversation, local { localConversationIds.insert(id) }
        let temporaryRun = isTemporary(id)
        let current = temporaryRun ? account.temporary(cloud: !local) : local ? account.local : account
        if !inline { error = nil }
        operationErrors[id] = nil; busyIds.insert(id)
        if newConversation {
            permissionModes[id] = permissionMode(launcher: launcher)
            if launcher { launcherPermissionMode = .standard } else { draftPermissionMode = .standard }
            tools.bindConversation(id)
        }
        var value = newConversation ? AskConversation(id: id, title: String(submitted.title.prefix(50)), revision: 0, updatedAt: Date(), messages: []) : selected!
        let messageId = queuedId ?? UUID().uuidString
        let operationId = UUID()
        guard stageFolderSubmission(submitted, conversation: value, route: current,
                                    messageID: messageId, generation: operationId) else { return false }
        var request = submitted.request(deviceId: deviceId, tools: [], id: messageId)
        request.deviceCreate = newConversation ? true : nil
        request.maxSteps = recoveryCheck ? min(modelLibrary.settings.askAgentMaxSteps, 20)
            : modelLibrary.settings.askAgentMaxSteps
        request.recoveryCheck = recoveryCheck ? true : nil
        if recoveryCheck || inline { request.imageResults = false }
        // A temporary conversation is never named: it has no place in history to be found by.
        request.titlePolicy = .init(enabled: modelLibrary.settings.askAutomaticTitles && !temporaryRun,
                                    modelRef: modelLibrary.settings.askTitleModelReference)
        request.auxiliaryModelRef = local ? modelLibrary.settings.askAuxiliaryModelReference : nil
        request.temporary = temporary ? true : nil
        request.clientToolApproval = true
        request.skills = skillUses(submitted.skills)
        request.modelRef = modelRef
        request.reasoningEffort = reasoningEffort.requestValue(for: request.modelRef.flatMap { modelLibrary.registry.resolve($0)?.1 })
        request.memory = newConversation && !temporaryRun && submitted.memoryOff != true
            ? (submitted.memory ?? capture.globalMemory())?.usable(owner: current.account,
                                                                  invalidations: memoryInvalidations) : nil
        value.modelRef = request.modelRef
        Self.applyMemoryChoice(submitted, newConversation: newConversation, request: &request, conversation: &value)
        pendingSends[id] = request
        admitted = true
        if launcher, !inline, newConversation { detachChatDraft() }
        if !launcher, !inline, newConversation, clearsDraft, draft == submitted, let key = activeChatDraftID {
            chatDraftSubmissions[id] = .init(key: key, owner: current.account, messageID: messageId)
            activeChatDraftID = nil
            pendingDraftHandoff = nil
        }
        screenshotConsent[id] = submitted.includeScreenshot ? messageId : nil
        value.messages.append(.init(id: messageId, role: "user", text: request.text, selection: request.selection, source: request.source, image: request.image, createdAt: Date(), reasoningEffort: request.reasoningEffort, references: request.references, attachments: request.attachments, skills: request.skills, mcpServers: request.mcpServers))
        if launcher { persistDrafts() }
        if !inline {
            selectedId = id; selected = value; isLoadingSelection = false; selectionGeneration = UUID()
        }
        if queuedId != nil { queuedSubmissionSelections[id] = selectionGeneration }
        if !inline, clearsDraft, launcher || draft == submitted {
            clearCapturedContentFeedback(launcher: false); draft = .followUp
        }
        snapshots[id] = value
        if !inline { selectionLoadFailed = false }
        updateSummary(value)
        if !inline, launcher, launcherDraft == submitted {
            clearCapturedContentFeedback(launcher: true); launcherDraft = newQuestionDraft(); launcherContextRestored = false
        }
        // A queued message sending on its own must not bring the window forward.
        if clearsDraft && !inline { onShowConversation?() }
        persistDrafts()
        registerOperation(id, operationId: operationId, account: current.account)
        startSubmittedSend(submitted, conversation: value, request: request, route: current,
                           operationId: operationId, inline: inline)
        return true
    }

    /// The server pins memory from the opening message only; empty memory is not sent.
    static func openingMemory(_ memory: AskMemory?) -> AskMemory? {
        guard let memory, !memory.isEmpty else { return nil }
        return memory
    }

    private func validateModel(_ reference: String?, token: String, hasImage: Bool = false) async throws {
        try Task.checkCancellation()
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

    /// Own the internal recovery like any other cancellable execution. Drafts,
    /// user messages, original run identity and permission mode stay unchanged.
    func startInternalRecovery() {
        guard let value = selected, let run = value.run, !busyIds.contains(value.id), !recoveryWorking,
              run.deviceId == deviceId, run.status != "completed", run.status != "cancelled",
              let current = credentials(for: value.id), admitAgentCommand(value) else { return }
        let entries = selectedRecoveryEntries.filter { $0.audit?.identity.runId == run.id && $0.needsInspection(run: run) }
        var callIDs = entries.compactMap { $0.audit?.identity.kind == "tool" ? $0.audit?.identity.callId : nil }
        if callIDs.isEmpty, run.needsRecoveryInspection { callIDs = run.pending.map(\.id) }
        let request = AskRecoveryRequest(runId: run.id, deviceId: deviceId, callIds: callIDs,
            inferenceId: entries.first { $0.audit?.identity.kind == "model" }?.audit?.identity.callId)
        stopSelectionObservation()
        let id = value.id, operationId = UUID()
        busyIds.insert(id); error = nil; operationErrors[id] = nil
        registerOperation(id, operationId: operationId, account: current.account)
        operations[id] = Task { [weak self] in
            guard let self else { return }
            defer { finishOperation(id, operationId: operationId) }
            do {
                try checkOperation(id, operationId: operationId, account: current.account)
                let response = try await api.recover(conversationId: id, request: request, token: current.token)
                try checkOperation(id, operationId: operationId, account: current.account)
                guard response.run?.id == run.id,
                      (request.callIds.isEmpty || response.run?.internalRecovery != nil),
                      try AskCoding.encoder().encode(response.messages.filter({ $0.role == "user" }))
                        == AskCoding.encoder().encode(value.messages.filter({ $0.role == "user" })) else {
                    throw AskLocalError.message(L("ask.recovery.readOnlyUnavailable"))
                }
                try await drive(response, current: current, operationId: operationId, screenshotConsentMessageID: screenshotConsent[id])
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, operationIds[id] == operationId else { return }
                await reportOperationError(error, id: id, owner: current.account)
            }
        }
    }

    func resume() {
        selectionObservation?.cancel(); selectionObservation = nil
        guard let value = selected, !busyIds.contains(value.id),
              let current = credentials(for: value.id) else { return }
        guard admitAgentCommand(value) else { return }
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
        let operationId = UUID(); registerOperation(id, operationId: operationId, account: current.account)
        if queuedSubmissions[id] != nil { queuedOperations.insert(operationId) }
        operations[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if operationIds[id] == operationId, owner == current.account, session()?.owner == current.account {
                    restoreQueuedSubmission(id)
                }
                finishOperation(id, operationId: operationId)
            }
            let monitor = monitorConversation(id: id, current: current, operationId: operationId)
            defer { monitor.cancel() }
            do {
                try checkOperation(id, operationId: operationId, account: current.account)
                _ = await tools.definitions(conversationId: id)
                let response: AskConversation
                if let request = pendingSends[id] {
                    response = try await resumePendingSend(request, conversation: value, route: current, operationId: operationId)
                    pendingSends[id] = nil
                    acknowledgeQueuedSubmission(id, messageID: request.id)
                    if request.recoveryCheck == true, response.run?.recoveryCheck != true {
                        if let run = response.run, run.isActive {
                            _ = try? await api.cancel(conversationId: id, runId: run.id, token: current.token)
                        }
                        throw AskLocalError.message(L("ask.recovery.readOnlyUnavailable"))
                    }
                } else if value.run == nil, let message = value.messages.last, message.role == "user" {
                    var request = AskSendRequest(clientToolApproval: true, id: message.id, deviceId: deviceId, text: message.text,
                                                 selection: message.selection, source: message.source, image: message.image,
                                                 tools: await tools.definitions(conversationId: id), modelRef: value.modelRef, reasoningEffort: message.reasoningEffort, references: message.references,
                                                 attachments: message.attachments)
                    request.maxSteps = modelLibrary.settings.askAgentMaxSteps
                    try await validateModel(
                        request.modelRef, token: current.token,
                        hasImage: request.sendsImage || value.messages.contains(where: { $0.hasImage })
                    )
                    try checkOperation(id, operationId: operationId, account: current.account)
                    response = try await api.send(conversationId: id, request: request, token: current.token)
                } else if let run = value.run, ["failed", "cancelled"].contains(run.status) {
                    try await validateModel(
                        retryModelRef, token: current.token,
                        hasImage: value.messages.contains(where: { $0.hasImage })
                    )
                    try checkOperation(id, operationId: operationId, account: current.account)
                    response = try await api.retry(conversationId: id, runId: run.id, deviceId: deviceId, modelRef: retryModelRef,
                                                   maxSteps: modelLibrary.settings.askAgentMaxSteps, token: current.token)
                } else {
                    try checkOperation(id, operationId: operationId, account: current.account)
                    response = try await api.conversation(id: id, token: current.token)
                }
                try await drive(response, current: current, operationId: operationId, screenshotConsentMessageID: screenshotConsent[id])
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, operationIds[id] == operationId else { return }
                await reportOperationError(error, id: id, owner: current.account)
            }
        }
    }

    /// Continues the selected run where the server paused it for credits. The server
    /// re-checks the balance; a run that is still short stays paused with the new details.
    func resumeCreditPause() {
        guard let value = selected, let run = value.run, run.isPausedForCredits, !busyIds.contains(value.id),
              let current = credentials(for: value.id) else { return }
        guard admitAgentCommand(value) else { return }
        selectionObservation?.cancel(); selectionObservation = nil
        let id = value.id
        busyIds.insert(id); submissionIssues[false] = nil; error = nil; operationErrors[id] = nil; creditPauseDetails[id] = nil
        let operationId = UUID(); registerOperation(id, operationId: operationId, account: current.account)
        operations[id] = Task { [weak self] in
            guard let self else { return }; defer { finishOperation(id, operationId: operationId) }
            let monitor = monitorConversation(id: id, current: current, operationId: operationId)
            defer { monitor.cancel() }
            do {
                try checkOperation(id, operationId: operationId, account: current.account)
                let response = try await api.resume(conversationId: id, runId: run.id, token: current.token)
                try await drive(response, current: current, operationId: operationId, screenshotConsentMessageID: screenshotConsent[id])
            } catch is CancellationError {} catch let exhausted as CloudCreditsExhaustedError {
                guard !Task.isCancelled, operationIds[id] == operationId, owner == current.account else { return }
                creditPauseDetails[id] = exhausted.details ?? CloudCreditsExhaustedDetails()
                onCreditsExhausted?()
            } catch {
                guard !Task.isCancelled, operationIds[id] == operationId else { return }
                await reportOperationError(error, id: id, owner: current.account)
            }
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
        guard admitAgentCommand(value) else { return }
        guard !recoveryBlocksResume(value) else { inspectingRecovery = true; return }
        let id = value.id
        let modelRef = modelReference(launcher: false)
        busyIds.insert(id); submissionIssues[false] = nil; error = nil; operationErrors[id] = nil
        let operationId = UUID(); registerOperation(id, operationId: operationId, account: current.account)
        operations[id] = Task { [weak self] in
            guard let self else { return }
            defer { finishOperation(id, operationId: operationId) }
            let monitor = monitorConversation(id: id, current: current, operationId: operationId)
            defer { monitor.cancel() }
            do {
                try checkOperation(id, operationId: operationId, account: current.account)
                let definitions = await tools.definitions(conversationId: id)
                try await validateModel(
                    modelRef, token: current.token,
                    hasImage: value.messages.contains(where: { $0.hasImage })
                )
                let request = AskRegenerateRequest(maxSteps: modelLibrary.settings.askAgentMaxSteps,
                                                   clientToolApproval: true, messageId: messageId, deviceId: deviceId,
                                                   modelRef: modelRef, tools: definitions)
                try checkOperation(id, operationId: operationId, account: current.account)
                let response = try await api.regenerate(conversationId: id, request: request, token: current.token)
                try await drive(response, current: current, operationId: operationId, screenshotConsentMessageID: screenshotConsent[id])
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, operationIds[id] == operationId else { return }
                await reportOperationError(error, id: id, owner: current.account)
            }
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

    func accept(_ incoming: AskConversation, route: AskRoute, operationId: UUID? = nil) async throws {
        let acceptingSession = queueSession
        try Task.checkCancellation()
        if let operationId { try checkOperation(incoming.id, operationId: operationId, account: route.account) }
        guard owner == route.account, session()?.owner == route.account,
              !deletedConversationIDs.contains(incoming.id) else { throw CancellationError() }
        reconcileConfirmedSupplements(fromAuthenticated: incoming)
        if let previous = snapshots[incoming.id], !incoming.isNewer(than: previous) {
            if previous.revision > incoming.revision || previous.run?.id == incoming.run?.id {
                reconcileConfirmedQueuedSubmission(fromAuthenticated: incoming)
            }
            return
        }
        // Keep authenticated evidence separate from the display/cache projection across awaits.
        var value = snapshots[incoming.id]?.reconciling(incoming, preservingEqualRevisionContent: true) ?? incoming
        value = sanitizedMemory(value, account: route.account, local: route.token.isEmpty)
        // Persist meaningful message/state changes, not every transient preview.
        if snapshots[value.id]?.title != value.title || snapshots[value.id]?.titleGeneration != value.titleGeneration
            || snapshots[value.id]?.titleSource != value.titleSource || snapshots[value.id]?.titlePolicy != value.titlePolicy
            || snapshots[value.id]?.messages != value.messages || snapshots[value.id]?.run?.status != value.run?.status
            || snapshots[value.id]?.usage != value.usage {
            try await cache.save(value, owner: route.owner)
            if let workspaces {
                do { try await workspaces.saveConversation(value, owner: route.account) }
                catch { ErrorLogStore.shared.log("Ask workspace conversation save failed: \(error.localizedDescription)") }
            }
        }
        try Task.checkCancellation()
        if let operationId { try checkOperation(value.id, operationId: operationId, account: route.account) }
        guard owner == route.account, session()?.owner == route.account,
              acceptingSession == queueSession, !deletedConversationIDs.contains(incoming.id) else { throw CancellationError() }
        reconcileConfirmedQueuedSubmission(fromAuthenticated: incoming)
        // Recheck after the cache write: another delivery or optimistic send
        // may have advanced the state while this task was suspended.
        if let latest = snapshots[value.id], !value.isNewer(than: latest) { return }
        value = snapshots[value.id]?.reconciling(value, preservingEqualRevisionContent: true) ?? value
        value = sanitizedMemory(value, account: route.account, local: route.token.isEmpty)
        if quickAsk?.conversationId == value.id { objectWillChange.send() }
        // A terminal observer can settle a run even when no drive task is active.
        // Cancel only the explicitly settled run; the executor checks admitted ownership.
        if let previousRun = snapshots[value.id]?.run?.id, previousRun != value.run?.id {
            tools.observeCommandRun(ownerId: route.account, conversationId: value.id, runId: previousRun, active: false)
            tools.revokeTaskFolders(conversationId: value.id, runId: previousRun)
        }
        if let run = value.run {
            if !run.isActive {
                tools.revokeTaskFolders(conversationId: value.id, runId: run.id)
                approvalStore.revokeTask(conversation: value.id, run: run.id)
            }
            tools.observeCommandRun(ownerId: route.account, conversationId: value.id, runId: run.id, active: run.isActive)
        }
        snapshots[value.id] = value
        reconcileConfirmedSupplements(fromAuthenticated: incoming, allowTerminal: incoming.revision >= value.revision
            && incoming.run?.id == value.run?.id && incoming.run?.status == value.run?.status)
        if selected?.id == value.id { selected = selected?.reconciling(value, preservingEqualRevisionContent: true) ?? value }
        if let inferenceID = progressInferenceIDs[value.id], value.run?.inference?.id != inferenceID {
            inferenceProgress[value.id] = nil; progressInferenceIDs[value.id] = nil
        }
        updateSummary(value)
        scheduleTitle(value, route: route)
        observeHistorySynchronization(route)
        await refreshRecovery(value, route: route)
        if let operationId { try checkOperation(incoming.id, operationId: operationId, account: route.account) }
        guard owner == route.account, session()?.owner == route.account,
              acceptingSession == queueSession, !deletedConversationIDs.contains(incoming.id) else { throw CancellationError() }
        if !sendQueue.messages(value.id).isEmpty || !sendQueue.steeredMessages(value.id).isEmpty {
            queueDidSettle(value.id)
        } else {
            sendQueue.noteSettled(value.id, run: value.run)
        }
    }

    private func updateSummary(_ value: AskConversation) {
        // A temporary conversation never appears in the history list.
        guard !isTemporary(value.id) else { return }
        let summary = AskConversationSummary(id: value.id, title: value.title, updatedAt: value.updatedAt)
        if let index = conversations.firstIndex(where: { $0.id == value.id }) {
            if conversations[index] != summary, conversations[index].updatedAt <= summary.updatedAt {
                conversations[index] = summary
            }
        } else { conversations.insert(summary, at: 0) }
    }

    /// Poll only local outbox metadata. This never waits for an upload or causes
    /// a task failure; it stops after synchronization or an account change.
    private func observeHistorySynchronization(_ current: AskRoute) {
        guard historySyncTask == nil, !current.token.isEmpty else { return }
        historySyncTask = Task { [weak self, api] in
            while !Task.isCancelled {
                guard self?.owner == current.account, self?.session()?.owner == current.account else { return }
                let pending = await api.historySyncPending(token: current.token)
                guard !Task.isCancelled else { return }
                guard self?.owner == current.account, self?.session()?.owner == current.account else { return }
                self?.historyHasPendingSync = pending
                if !pending { self?.historySyncTask = nil; return }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func drive(_ initial: AskConversation, current: AskRoute, operationId: UUID,
                       screenshotConsentMessageID: String?, allowsTools: Bool = true) async throws {
        try checkOperation(initial.id, operationId: operationId, account: current.account)
        defer {
            if Task.isCancelled, let scope = operationRuns[operationId],
               owner == scope.ownerId, session()?.owner == scope.ownerId,
               operationGenerations[initial.id] == operationId, snapshots[initial.id]?.run?.id == scope.runId,
               (try? AskAgentBinding.resolve(snapshots[initial.id]?.run?.agentBinding)) != nil {
                tools.cancelProjectRun(scope)
            }
        }
        var value = initial
        var current = current
        while true {
            guard let refreshed = credentials(for: initial.id), refreshed.account == current.account,
                  refreshed.owner == current.owner else { throw CancellationError() }
            current = refreshed
            value = sanitizedMemory(value, account: current.account, local: current.token.isEmpty)
            try await accept(value, route: current, operationId: operationId)
            value = sanitizedMemory(value, account: current.account, local: current.token.isEmpty)
            // A monitor can have advanced while this response was in flight.
            if let latest = snapshots[value.id] { value = latest }
            guard let run = value.run, run.isActive else {
                if let run = value.run {
                    tools.revokeTaskFolders(conversationId: value.id, runId: run.id)
                    approvalStore.revokeTask(conversation: value.id, run: run.id)
                }
                return
            }
            if (try? AskAgentBinding.resolve(run.agentBinding)) == nil,
               run.deviceId != deviceId, ["waiting_tool", "waiting_inference"].contains(run.status) {
                throw AskLocalError.message(L("ask.tool.otherDevice"))
            }
            _ = try AskAgentBinding.resolve(run.agentBinding)
            try checkOperation(value.id, operationId: operationId, account: current.account)
            if run.deviceId == deviceId {
                operationRuns[operationId] = .init(ownerId: current.account, conversationId: value.id, runId: run.id)
            }
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
                try await accept(value, route: current, operationId: operationId)
                throw AskLocalError.message(L("ask.budget.stopped", L("ask.budget.reason.duration")))
            }
            if !allowsTools, run.status == "waiting_tool" {
                let stopped = try await api.cancel(conversationId: value.id, runId: run.id, token: current.token)
                try await accept(stopped, route: current, operationId: operationId)
                throw AskLocalError.message(L("ask.quickAsk.advanced"))
            }
            tools.bindExecution(ownerId: current.account, conversationId: value.id, runId: run.id,
                                deviceId: deviceId, persistent: !isTemporary(value.id))
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
                    let summaryReference = (inference.summaryThrough ?? 0) > 0
                        ? (try? JSONSerialization.jsonObject(with: Data(inference.payload.utf8)) as? [String: Any])?["model"] as? String : nil
                    let audit = AskExecutionAudit(identity: identity, toolVersion: run.modelRef ?? "model", toolName: "model",
                                                  argumentsHash: AskToolPolicy.digest(inference.payload))
                    guard try await cache.claimExecution(audit, owner: current.owner) else { throw AskRecoveryError.unknown }
                    try Task.checkCancellation()
                    guard session()?.owner == current.account else { throw CancellationError() }
                    guard snapshots[value.id]?.run?.id == run.id,
                          snapshots[value.id]?.run?.status == "waiting_inference",
                          snapshots[value.id]?.run?.inference?.id == inference.id else { return }
                    _ = try AskAgentBinding.resolve(snapshots[value.id]?.run?.agentBinding)
                    do {
                        guard let reference = summaryReference ?? run.modelRef,
                              let (provider, model) = modelLibrary.registry.resolve(reference) else {
                            throw AskLocalError.message(L("ask.models.unavailable"))
                        }
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
                        let connection = AskDeviceModelClient.authenticated(modelLibrary.connection(provider, model: model), token: current.token)
                        let (text, calls) = try await customInference.complete(provider: provider,
                            connection: connection, payload: payload,
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
                        if case AskStreamError.contextCapacity = error { receipt?.errorCode = "MODEL_CONTEXT_TOO_LONG" }
                        if error is CloudCreditsExhaustedError { receipt?.errorCode = "CREDITS_EXHAUSTED" }
                    }
                    // Persist under the original binding even if logout/cancel raced completion.
                    try await cache.saveReceipt(.inference(receipt!), identity: identity, owner: current.owner)
                }
                try Task.checkCancellation()
                guard session()?.owner == current.account else { throw CancellationError() }
                value = try await api.inferenceResult(conversationId: value.id, request: receipt!, token: current.token)
                try await acknowledgeExecution(identity, response: value, current: current)
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
                if run.recoveryCheck == true,
                   !run.permitsRecoveryTool(call) {
                    let failure = AskToolPreparationFailure(AskLocalError.message(L("ask.recovery.readOnly")))
                    guard let rejected = try await rejectToolPreparation(failure, call: call, value: value,
                                                                         identity: identity, current: current) else { return }
                    value = try await deliverToolResult(rejected, identity: identity, current: current, operationId: operationId)
                    continue
                }
                // Project and artifact scopes belong to the account, as `artifactAccess` reads them,
                // not to the cache partition a private conversation uses.
                tools.bindExecution(ownerId: current.account, conversationId: value.id, runId: run.id,
                                deviceId: deviceId, persistent: !isTemporary(value.id))
                // Consent comes from the submitted draft, never from historical images or live UI state.
                let cloudDefinition = run.approvalTool(for: call)
                let binding: AskToolBinding
                do {
                    binding = try await preparedToolBinding(call, conversationId: value.id, cloudDefinition: cloudDefinition)
                } catch let failure as AskToolPreparationFailure {
                    guard let rejected = try await rejectToolPreparation(failure, call: call, value: value,
                                                                         identity: identity, current: current) else { return }
                    value = try await deliverToolResult(rejected, identity: identity, current: current, operationId: operationId)
                    continue
                }
                try Task.checkCancellation()
                guard session()?.owner == current.account else { throw CancellationError() }
                let request = AskToolPolicy.request(call: call, owner: current.account, conversation: value.id,
                                                    run: run.id, step: String(run.steps), binding: binding,
                                                    risk: toolRisk(call, cloudDefinition: cloudDefinition), reuseEnabled: false,
                                                    now: approvalStore.now())
                let grantID: String?
                if !binding.requiresExplicitConsent, automaticallyApproves(
                    call,
                    risk: request.risk,
                    conversationId: value.id
                ) {
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
                try await accept(latest, route: current, operationId: operationId)
                guard snapshots[value.id]?.run?.id == run.id, snapshots[value.id]?.run?.status == "waiting_tool",
                      snapshots[value.id]?.run?.pending.first == call else {
                    approvalStore.revoke(conversation: value.id)
                    return
                }
                try Task.checkCancellation()
                guard session()?.owner == current.account else { throw CancellationError() }
                _ = try AskAgentBinding.resolve(snapshots[value.id]?.run?.agentBinding)
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
                        _ = try AskAgentBinding.resolve(snapshots[value.id]?.run?.agentBinding)
                        guard bindingNow == request.binding,
                              approvalStore.consume(grantID, for: request) else {
                            throw AskLocalError.message(L("ask.approval.changed"))
                        }
                        tools.setExecutionDeadline(run.budgetEnabled == true ? run.budgetDeadline : nil, conversationId: value.id)
                        let authorize = { [self] in
                            _ = try AskAgentBinding.resolve(self.snapshots[identity.conversationId]?.run?.agentBinding)
                            try self.checkOperation(identity.conversationId, operationId: operationId, account: current.account)
                            if self.snapshots[identity.conversationId]?.run?.recoveryCheck == true,
                               !run.permitsRecoveryTool(call) {
                                throw AskLocalError.message(L("ask.recovery.readOnly"))
                            }
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
            value = try await deliverToolResult(result!, identity: identity, current: current, operationId: operationId)
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
        .boundImages(context: { [weak self] in
            guard let self, !(self.selectedId.map(self.isDeletedConversation) ?? false) else { return nil }
            let live = self.session()
            return .init(owner: live?.owner ?? "", token: live?.token ?? "", conversation: self.selectedId,
                         selection: self.selectionGeneration)
        }, load: { [weak self] ref, owner in
            guard let self else { throw AskArtifactError.denied }
            return try self.tools.loadArtifact(ref, ownerId: owner, conversationId: ref.conversationId)
        }, validate: { [weak self] ref, owner in
            guard let self else { throw AskArtifactError.denied }
            try self.tools.validateArtifact(ref, ownerId: owner, conversationId: ref.conversationId)
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
        // Personal notes always need explicit consent. Other tools follow the selected mode.
        if call.function.name == AskNotebookTool.name { return false }
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
              let call = pendingApprovals[id], !pending.request.binding.requiresExplicitConsent,
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

    func temporaryFolderGrants() -> [AskFolderGrants.Grant] {
        guard let id = selectedId else { return [] }
        return tools.temporaryFolders(conversationId: id)
    }

    func revokeTemporaryFolder(_ grant: UUID?) {
        guard let id = selectedId else { return }
        tools.revokeFolder(grant, conversationId: id)
        // Pending or cached operation approval cannot outlive the explicit revoke.
        approvalStore.revoke(conversation: id)
        objectWillChange.send()
    }

    func hasSettingsFolder(_ path: String) -> Bool {
        // Presentation uses lexical OS aliases so a missing descendant still shows its Settings source.
        // Execution continues to use its own pinned descriptor and authoritative root selection.
        func comparable(_ raw: String) -> String {
            var path = (raw as NSString).expandingTildeInPath
            for alias in ["/var", "/tmp", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
                path = "/private" + path
            }
            return URL(fileURLWithPath: path).standardized.path
        }
        let path = comparable(path)
        return modelLibrary.settings.askFileAccessFolders.map(comparable)
            .contains { root in path == root || path.hasPrefix(root == "/" ? "/" : root + "/") }
    }

    func shutdownCommandJobs() async { await tools.shutdownCommandJobs() }

    func stop(id: String? = nil) {
        let preflight = submissionPreflights[false] ?? submissionPreflights[true]
        let preflightId = operationIds.first(where: { $0.value == preflight })?.key
        guard let id = id ?? selected?.id ?? preflightId, let current = credentials(for: id) else { return }
        if externallyDrivenConversations.contains(id), FeatureProcess.enabled {
            FeatureProcess.send(.init(destination: .launcher, action: "stopConversation", payload: Data(id.utf8)))
        }
        sendQueue.pause(id)
        cancelQueueFlights(id)
        tools.revokeTaskFolders(conversationId: id, runId: nil)
        approvalStore.revokeTask(conversation: id)
        // No drive task may be active during observer-only settlement or a pause.
        // This synchronous user action cancels only authority already admitted by the host.
        if operationIds[id] == nil {
            tools.observeCommandRun(ownerId: current.account, conversationId: id, runId: nil, active: false)
        }
        let capturedRun = snapshots[id]?.run
        let operationId = operationIds[id]
        let generation = operationGenerations[id]
        let admittedScope = operationId.flatMap { operationRuns[$0] }.flatMap { scope in
            scope.ownerId == current.account && scope.conversationId == id ? scope : nil
        }
        // Task ownership belongs to the current account/conversation/generation.
        // Observed runs neither grant nor revoke it; only our admitted scope
        // authorizes tool interruption, independently of the displayed run.
        if let operationId, let operationOwner = operationOwners[operationId],
           operationOwner.account == current.account, operationOwner.conversationId == id,
           generation == operationId,
           let operation = operations[id] {
            permissionModes[id] = .standard
            operation.cancel()
            if let admittedScope { tools.cancelProjectRun(admittedScope) }
            approve(conversationId: id, allowed: false)
            if controllingConversationId == id { controllingConversationId = nil; onControlChanged?(false) }
            // A command awaiting its response has no admitted remote run to stop.
            // Keep pending request evidence: dispatch may already have succeeded.
            if admittedScope == nil { return }
        }
        guard let capturedRun, capturedRun.deviceId == deviceId else { return }
        Task {
            do {
                let value = try await api.conversation(id: id, token: current.token)
                guard owner == current.account, session()?.owner == current.account,
                      let run = value.run, run.id == capturedRun.id, run.deviceId == capturedRun.deviceId,
                      snapshots[id]?.run?.id == capturedRun.id,
                      operationGenerations[id] == generation else { throw CancellationError() }
                _ = try AskAgentBinding.resolve(capturedRun.agentBinding)
                _ = try AskAgentBinding.resolve(run.agentBinding)
                guard operationId == nil || admittedScope?.runId == run.id else { throw CancellationError() }
                var partial: AskInferenceResult?
                if let inference = run.inference, inference.id == progressInferenceIDs[id],
                   let progress = inferenceProgress[id], run.deviceId == deviceId {
                    partial = AskInferenceResult(runId: run.id, deviceId: deviceId, inferenceId: inference.id,
                                                 content: progress.text, usage: inferenceUsage[inference.id], reasoning: progress.reasoning,
                                                 reasoningMilliseconds: progress.reasoningMilliseconds)
                }
                let stopped = try await api.cancel(conversationId: id, runId: run.id, partial: partial, token: current.token)
                guard owner == current.account, session()?.owner == current.account,
                      snapshots[id]?.run?.id == capturedRun.id, operationGenerations[id] == generation else { return }
                pendingSends[id] = nil
                try await accept(stopped, route: current)
            } catch {
                guard session()?.owner == current.account, snapshots[id]?.run?.id == capturedRun.id,
                      operationGenerations[id] == generation else { return }
                await reportOperationError(error, id: id, owner: current.account)
            }
        }
    }

    func delete(_ id: String) async {
        guard let current = credentials(for: id), owner == current.account, session()?.owner == current.account else { return }
        if let operationId = operationIds[id], operationOwners[operationId]?.account == current.account,
           queuedSubmissions[id] != nil || queuedOperations.contains(operationId) {
            let pending = operations[id]
            pending?.cancel()
            if let scope = operationRuns[operationId] { tools.cancelProjectRun(scope) }
            await pending?.value
        }
        guard !busyIds.contains(id), owner == current.account, session()?.owner == current.account else { return }
        tools.revokeFolder(nil, conversationId: id)
        tools.cancelProjects(conversationId: id)
        do {
            try await syncWorkspace(id, requireFresh: true)
            try await api.delete(conversationId: id, token: current.token)
            guard owner == current.account else { return }
            deletedConversationIDs.insert(id)
            forgetQueueFlights(id)
            sendQueue.clear(id)
            try tools.deleteArtifacts(ownerId: current.account, conversationId: id)
            try workflowAuthoring?.remove(id)
            if selectedId == id { remoteImageScope.invalidate(); conversationImageScope.invalidate() }
            titleTasks[id]?.cancel(); titleTasks[id] = nil; titleRetryAfter[id] = nil
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
            if temporaryConversation?.id == id { temporaryConversation = nil }
            drafts[id] = nil; snapshots[id] = nil; operationErrors[id] = nil; transcriptPositions[id] = nil
            screenshotConsent[id] = nil; permissionModes[id] = nil; approvalStore.revoke(conversation: id)
            if selectedId == id { selectedId = nil; newConversation() }
            else { persistDrafts() }
        } catch { self.error = error.localizedDescription }
    }

    // MARK: - Temporary conversation

    func isTemporary(_ id: String?) -> Bool { id != nil && temporaryConversation?.id == id }

    /// What a new conversation's draft offers as memory: only global memory, since no
    /// source app is trustworthy there.
    func globalMemoryForNewDraft() -> AskMemory { capture.globalMemory() ?? AskMemory() }

    /// Whether moving to `target` (nil for a new conversation) may go ahead. Leaving the
    /// selected temporary conversation ends it; with messages in it the user is asked
    /// first, unless they turned that off, and may keep it instead.
    func leaveTemporaryConversation(for target: String?) -> Bool {
        guard let temporary = temporaryConversation, temporary.id != target else { return true }
        let hasContent = !(snapshots[temporary.id]?.messages.isEmpty ?? true)
        if hasContent, selectedId == temporary.id, modelLibrary.settings.askConfirmLeavingTemporary {
            let decision = confirmTemporaryLeave()
            if decision.suppress { modelLibrary.settings.askConfirmLeavingTemporary = false }
            switch decision.choice {
            case .cancel: return false
            case .keep: keepTemporaryConversation(); return true
            case .end: break
            }
        }
        discardTemporaryConversation()
        return true
    }

    /// Ends the temporary conversation: stops its run and removes its local
    /// workspace, cache, and server copy.
    @discardableResult
    func discardTemporaryConversation() -> Task<Void, Never>? {
        guard let temporary = temporaryConversation, let account = credentials(),
              temporaryConversation?.id == temporary.id else { return nil }
        guard !keepingTemporaryIDs.contains(temporary.id) else {
            // Being kept: it is no longer this session's temporary conversation.
            temporaryConversation = nil
            return nil
        }
        let id = temporary.id, route = account.temporary(cloud: temporary.cloud)
        let activeRun = snapshots[id]?.run.flatMap { $0.isActive ? $0.id : nil }
        temporaryConversation = nil
        operations[id]?.cancel(); operations[id] = nil
        if let operationId = operationIds[id] { operationRuns[operationId] = nil; operationOwners[operationId] = nil }
        operationIds[id] = nil
        approvals[id]?.resume(returning: nil); approvals[id] = nil; approvalRequests[id] = nil
        approvalStore.revoke(conversation: id)
        busyIds.remove(id); pendingSends[id] = nil; pendingApprovals[id] = nil; operationErrors[id] = nil
        inferenceProgress[id] = nil; progressInferenceIDs[id] = nil; recoveryEntries[id] = nil
        drafts[id] = nil; snapshots[id] = nil; transcriptPositions[id] = nil
        forgetQueueFlights(id); sendQueue.clear(id)
        screenshotConsent[id] = nil; permissionModes[id] = nil; cloudApprovals[id] = nil
        titleTasks[id]?.cancel(); titleTasks[id] = nil; titleRetryAfter[id] = nil
        deletedConversationIDs.insert(id)
        if selectedId == id { remoteImageScope.invalidate(); conversationImageScope.invalidate() }
        if controllingConversationId == id { controllingConversationId = nil; onControlChanged?(false) }
        if selectedId == id {
            selectionObservation?.cancel(); selectionObservation = nil
            selectionGeneration = UUID(); selected = nil; selectedId = nil
            isLoadingSelection = false; selectionLoadFailed = false; error = nil
            draft = newQuestionDraft()
            draft.memory = capture.globalMemory() ?? AskMemory()
        }
        tools.revokeFolder(nil, conversationId: id)
        tools.cancelProjects(conversationId: id)
        let workspaceCleanup: Task<Void, Never>? = workspaces.map { workspaces in
            Task {
                do { try await workspaces.discard(owner: route.account, conversationId: id) }
                catch { ErrorLogStore.shared.log("Ask temporary workspace cleanup failed: \(error.localizedDescription)") }
            }
        }
        Task { [api, cache, tools] in
            if let activeRun { _ = try? await api.cancel(conversationId: id, runId: activeRun, token: route.token) }
            try? await api.delete(conversationId: id, token: route.token)
            try? await cache.delete(id: id, owner: route.owner)
            try? tools.deleteArtifacts(ownerId: route.account, conversationId: id)
        }
        return workspaceCleanup
    }

    func discardTemporaryConversationForTermination() async {
        let temporary = temporaryConversation
        let account = owner
        let cleanup = discardTemporaryConversation()
        await cleanup?.value
        if cleanup == nil, let temporary, !keepingTemporaryIDs.contains(temporary.id), let workspaces {
            do { try await workspaces.discard(owner: account, conversationId: temporary.id) }
            catch { ErrorLogStore.shared.log("Ask temporary workspace cleanup failed: \(error.localizedDescription)") }
        }
    }

    /// Turns the temporary conversation into an ordinary one kept where it ran:
    /// Typeflux Cloud for a Cloud model, otherwise this Mac. It then shows in history.
    func keepTemporaryConversation() {
        guard let temporary = temporaryConversation, let account = credentials(),
              !keepingTemporaryIDs.contains(temporary.id) else { return }
        let id = temporary.id
        let from = account.temporary(cloud: temporary.cloud), to = temporary.cloud ? account : account.local
        keepingTemporaryIDs.insert(id)
        Task { [weak self] in
            guard let self else { return }
            defer { keepingTemporaryIDs.remove(id) }
            do {
                let kept = try await api.keep(conversationId: id, token: from.token)
                guard owner == account.account else { return }
                let value = snapshots[id].map { $0.reconciling(kept) } ?? kept
                // Copy it to its lasting partition before the route switches there.
                try await cache.save(value, owner: to.owner)
                if let saved = drafts[id] { try? await cache.saveDraft(saved, key: id, owner: to.owner) }
                try? await cache.delete(id: id, owner: from.owner)
                guard owner == account.account else { return }
                if temporaryConversation?.id == id { temporaryConversation = nil }
                if !temporary.cloud { localConversationIds.insert(id) }
                snapshots[id] = value
                if selectedId == id { selected = value }
                updateSummary(value)
                confirm(L(temporary.cloud ? "ask.temporary.kept.cloud" : "ask.temporary.kept.local"))
            } catch {
                guard owner == account.account else { return }
                self.error = L("ask.temporary.keepFailed")
            }
        }
    }

    /// The memory tool would write what a temporary conversation must forget.
    static func offeredTools(_ tools: [AskToolDefinition], temporary: Bool) -> [AskToolDefinition] {
        temporary ? tools.filter { $0.name != "memory" } : tools
    }

    /// Offer the same host-owned observation actions enforced at dispatch.
    static func recoveryObservationTools(_ tools: [AskToolDefinition]) -> [AskToolDefinition] {
        AskRecoveryObservation.offered(tools)
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

    private func registerOperation(_ id: String, operationId: UUID, account: String) {
        if let previous = operationIds[id] {
            operations[id]?.cancel()
            operationOwners[previous] = nil; operationRuns[previous] = nil
        }
        operationIds[id] = operationId
        operationGenerations[id] = operationId
        operationOwners[operationId] = .init(account: account, conversationId: id)
    }

    private func checkOperation(_ id: String, operationId: UUID, account: String) throws {
        try Task.checkCancellation()
        guard owner == account, session()?.owner == account,
              operationIds[id] == operationId, operationOwners[operationId]?.account == account,
              operations[id]?.isCancelled != true else { throw CancellationError() }
    }

    private func finishOperation(_ id: String, operationId: UUID) {
        queuedOperations.remove(operationId)
        operationRuns[operationId] = nil; operationOwners[operationId] = nil
        guard operationIds[id] == operationId else { return }
        operationIds[id] = nil
        busyIds.remove(id); operations[id] = nil; pendingApprovals[id] = nil
        recoveringImages[id] = nil
        if controllingConversationId == id { controllingConversationId = nil; onControlChanged?(false) }
        queueDidSettle(id)
        if selectedId == id { Task { await recoverWithoutUser() } }
    }

    private func recordInferenceUsage(_ usage: AskTokenUsage, id: String, owner expectedOwner: String) {
        guard owner == expectedOwner else { return }
        inferenceUsage[id] = usage
    }

    func applyFeatureQuickProgress(_ value: FeatureQuickProgress) {
        guard session()?.owner == value.owner, externallyDrivenConversations.contains(value.id),
              !busyIds.contains(value.id), snapshots[value.id]?.run?.id == value.runID else { return }
        inferenceProgress[value.id] = value.progress
        if value.complete { externallyDrivenConversations.remove(value.id); inferenceProgress[value.id] = nil }
    }

    private func updateInferenceProgress(_ progress: AskStreamProgress, id: String, inferenceID: String, owner expectedOwner: String, visible: Bool) {
        guard owner == expectedOwner, progressInferenceIDs[id] == inferenceID, visible else { return }
        inferenceProgress[id] = progress
    }

    private func monitorConversation(id: String, current: AskRoute, operationId: UUID? = nil) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let self, owner == current.account else { return }
                    if let operationId { try checkOperation(id, operationId: operationId, account: current.account) }
                    try await api.observe(id: id, token: current.token) { [weak self] value in
                        guard let self else { throw CancellationError() }
                        try await self.acceptObserved(value, current: current, operationId: operationId)
                    }
                } catch is CancellationError { return }
                catch {
                    // Compatibility with an older server, and recovery after transport loss.
                    if let self, let value = try? await api.conversation(id: id, token: current.token) {
                        try? await acceptObserved(value, current: current, operationId: operationId)
                    }
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func acceptObserved(_ value: AskConversation, current: AskRoute, operationId: UUID?) async throws {
        if let operationId { try checkOperation(value.id, operationId: operationId, account: current.account) }
        guard owner == current.account else { throw CancellationError() }
        if let pending = pendingSends[value.id], !value.messages.contains(where: { $0.id == pending.id }) { return }
        try await accept(value, route: current, operationId: operationId)
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
    /// The temporary conversation's route: cached in memory only, and run in Typeflux
    /// Cloud or on this Mac depending on its model.
    func temporary(cloud: Bool) -> AskRoute {
        .init(account: account, owner: AskRoutedAPI.temporaryOwner, token: cloud ? token : "")
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

    func isQueueItemPending(_ itemID: String) -> Bool {
        guard let id = selectedId else { return false }
        return queueFlights[id]?[itemID] != nil || queuedSubmissions[id]?.item.id == itemID
    }

    var isQueuePaused: Bool { selectedId.map { sendQueue.isPaused($0) } ?? false }

    var canResumeQueue: Bool {
        guard let value = selected, !isLoadingSelection, !busyIds.contains(value.id) else { return false }
        let disposition = queueDisposition(value, ignoringPause: true)
        return disposition == .ready || (disposition == .blocked(.flight)
            && (pendingSends[value.id] != nil || queueFlights[value.id]?.values.contains(where: { $0.task == nil }) == true))
    }

    var queuePauseReason: String? {
        guard let value = selected else { return nil }
        switch queueDisposition(value, ignoringPause: true) {
        case .blocked(.recovery): return L("ask.run.needsDecision")
        case .blocked(.credits): return L("ask.run.pausedCredits")
        case .blocked(.otherDevice): return L("ask.recovery.binding")
        case .blocked(.approval): return L("ask.run.attention")
        case .blocked(.flight): return L("ask.queue.reconcile")
        default: return isQueuePaused ? L("ask.queue.pausedReason") : nil
        }
    }

    /// "Jump the queue" needs a run that is still working.
    var canSteer: Bool {
        selected.map { value in
            guard let run = value.run, ["running", "waiting_tool", "waiting_inference"].contains(run.status) else { return false }
            return !recoveryBlocksResume(value) && (run.status == "running" || run.deviceId == deviceId)
        } == true && !isLoadingSelection
    }

    func removeQueued(_ itemId: String) {
        guard let id = selectedId else { return }
        if sendQueue.isEditing(id, itemId: itemId) { cancelQueuedEdit() }
        sendQueue.remove(itemId, from: id)
        if queuedSubmissions[id]?.item.id == itemId { operations[id]?.cancel() }
        queueFlights[id]?[itemId]?.task?.cancel()
    }

    func clearQueue() {
        guard let id = selectedId else { return }
        cancelQueuedEdit(advancing: false)
        cancelQueueFlights(id)
        if queuedSubmissions[id] != nil { operations[id]?.cancel() }
        sendQueue.clear(id)
    }

    func resumeQueue() {
        guard let value = selected, !recoveryWorking else { return }
        let id = value.id
        if queueDisposition(value, ignoringPause: true) == .blocked(.recovery) {
            inspectingRecovery = true
            return
        }
        if let flight = queueFlights[id]?.values.first(where: { $0.task == nil }) {
            reconcileSteer(flight, conversationID: id)
            return
        }
        if pendingSends[id] != nil {
            // Explicit continuation also releases the pause for following FIFO items.
            // The existing pending request owns this ID; its retry path remains the only sender.
            guard !busyIds.contains(id) else { return }
            sendQueue.resume(id)
            resume()
            return
        }
        guard queueDisposition(value, ignoringPause: true) == .ready else { return }
        sendQueue.resume(id)
        queueDidSettle(id)
    }

    /// Opens a queued message in the composer; what the user was typing is set aside.
    func editQueued(_ itemId: String) {
        guard let id = selectedId, queueFlights[id]?[itemId] == nil, queuedSubmissions[id]?.item.id != itemId,
              let item = sendQueue.messages(id).first(where: { $0.id == itemId }) else { return }
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

    /// Hands the exact queued draft to its captured run at the existing safe boundary.
    func steerQueued(_ itemId: String) {
        guard let value = selected, canSteer, let current = credentials(for: value.id), let run = value.run,
              !steeringIds.contains(itemId), admitAgentCommand(value) else { return }
        if sendQueue.isEditing(value.id, itemId: itemId) { saveQueuedEdit(advancing: false) }
        guard let claim = sendQueue.claim(itemId, in: value.id, runID: run.id) else { return }
        let flight = QueueFlight(attempt: UUID(), owner: current.account, device: deviceId, originalDevice: run.deviceId,
                                 session: queueSession, selection: selectionGeneration, claim: claim)
        queueFlights[value.id, default: [:]][itemId] = flight
        launchSteer(flight, conversationID: value.id, route: current, refreshing: false)
    }

    private func continueAfterQueueReconciliation(_ flight: QueueFlight, conversationID id: String) {
        guard owner == flight.owner, session()?.owner == flight.owner, queueSession == flight.session,
              selectedId == id, selectionGeneration == flight.selection, let value = selected,
              queueDisposition(value, ignoringPause: true) == .ready else { return }
        sendQueue.resume(id)
        queueDidSettle(id)
    }

    private func ownsQueueFlight(_ flight: QueueFlight, conversationID: String) -> Bool {
        owner == flight.owner && session()?.owner == flight.owner && queueSession == flight.session
            && deviceId == flight.device && !deletedConversationIDs.contains(conversationID)
            && queueFlights[conversationID]?[flight.claim.item.id]?.attempt == flight.attempt
    }

    private func cancelQueueFlights(_ id: String) {
        for flight in queueFlights[id]?.values.map({ $0 }) ?? [] { flight.task?.cancel() }
    }

    private func forgetQueueFlights(_ id: String) {
        for flight in queueFlights[id]?.values.map({ $0 }) ?? [] {
            flight.task?.cancel()
            sendQueue.release(flight.claim, in: id)
            steeringIds.remove(flight.claim.item.id)
        }
        queueFlights[id] = nil; queuedSubmissionSelections[id] = nil; pendingSends[id] = nil
        if let claim = queuedSubmissions.removeValue(forKey: id) { sendQueue.release(claim, in: id) }
    }

    private func reconcileSteer(_ previous: QueueFlight, conversationID: String) {
        guard let route = credentials(for: conversationID) else { return }
        let flight = QueueFlight(attempt: UUID(), owner: previous.owner, device: previous.device, originalDevice: previous.originalDevice,
                                 session: previous.session, selection: selectionGeneration, claim: previous.claim)
        queueFlights[conversationID]?[flight.claim.item.id] = flight
        launchSteer(flight, conversationID: conversationID, route: route, refreshing: true)
    }

    private func launchSteer(_ flight: QueueFlight, conversationID id: String, route: AskRoute, refreshing: Bool) {
        let item = flight.claim.item
        steeringIds.insert(item.id)
        if !refreshing {
            approvalStore.revoke(conversation: id)
            approve(conversationId: id, allowed: false)
        }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            defer {
                if ownsQueueFlight(flight, conversationID: id) {
                    queueFlights[id]?[item.id]?.task = nil
                    steeringIds.remove(item.id)
                }
            }
            do {
                if refreshing {
                    let fresh = try await api.conversation(id: id, token: route.token)
                    guard ownsQueueFlight(flight, conversationID: id), !Task.isCancelled else { return }
                    if try await settleSteer(flight, response: fresh, route: route, accepted: false) {
                        continueAfterQueueReconciliation(flight, conversationID: id)
                        return
                    }
                    // Retry only the original idempotent supplement, never a replacement run or new turn.
                    guard let freshRun = fresh.run, freshRun.id == flight.claim.originalRunID,
                          freshRun.deviceId == flight.originalDevice, freshRun.isActive,
                          !freshRun.needsRecoveryInspection, !freshRun.isPausedForCredits,
                          sendQueue.owns(flight.claim, in: id) else { return }
                }
                var message = item.draft.request(deviceId: flight.device, tools: [], id: item.id)
                message.skills = skillUses(item.draft.skills)
                let request = AskSteerRequest(runId: flight.claim.originalRunID ?? "", message: message)
                let response = try await api.steer(conversationId: id, request: request, token: route.token)
                guard ownsQueueFlight(flight, conversationID: id) else { return }
                // Removal invalidates local intent, but a positive response can still release its reservation.
                guard !Task.isCancelled || !sendQueue.owns(flight.claim, in: id) else { return }
                if try await settleSteer(flight, response: response, route: route, accepted: true) == false {
                    sendQueue.pause(id)
                    if selectedId == id { self.error = L("ask.queue.reconcile") }
                }
            } catch {
                guard ownsQueueFlight(flight, conversationID: id) else { return }
                sendQueue.pause(id)
                if !Task.isCancelled, let fresh = try? await api.conversation(id: id, token: route.token),
                   ownsQueueFlight(flight, conversationID: id), !Task.isCancelled {
                    if (try? await settleSteer(flight, response: fresh, route: route, accepted: false)) == true { return }
                }
                guard ownsQueueFlight(flight, conversationID: id), sendQueue.owns(flight.claim, in: id) else { return }
                operationErrors[id] = L("ask.queue.reconcile")
                if selectedId == id { self.error = L("ask.queue.reconcile") }
            }
        }
        queueFlights[id]?[item.id]?.task = task
    }

    /// A transcript ID is consumption; a successful original-run response is acceptance only.
    private func settleSteer(_ flight: QueueFlight, response: AskConversation, route: AskRoute, accepted: Bool) async throws -> Bool {
        let id = response.id, item = flight.claim.item
        guard ownsQueueFlight(flight, conversationID: id), response.run?.id == flight.claim.originalRunID,
              response.run?.deviceId == flight.originalDevice else { return false }
        let consumed = response.messages.contains { $0.id == item.id && $0.runId == flight.claim.originalRunID }
        let terminal = response.run.map { ["completed", "failed", "cancelled"].contains($0.status) && !$0.needsRecoveryInspection } == true
        if !consumed, let latest = snapshots[id] {
            guard latest.run?.id == flight.claim.originalRunID,
                  latest.run?.deviceId == flight.originalDevice else { return false }
            // Content clocks and identity matter; serialized dates can have a different precision.
            if latest.run?.isActive != true, !terminal { return false }
            if response.revision < latest.revision, terminal || latest.run?.isActive != true { return false }
        }
        guard consumed || terminal || accepted else { return false }
        if sendQueue.owns(flight.claim, in: id) {
            if consumed { sendQueue.remove(item.id, from: id) }
            else if terminal { sendQueue.restore(flight.claim, in: id) }
            else { sendQueue.markSteered(item, in: id, runID: flight.claim.originalRunID) }
        }
        sendQueue.release(flight.claim, in: id)
        queueFlights[id]?[item.id] = nil
        steeringIds.remove(item.id)
        // Selection changes invalidate advancement, while confirmed evidence still belongs to its conversation.
        if selectionGeneration != flight.selection { sendQueue.pause(id) }
        try await accept(response, route: route)
        return true
    }

    private func reconcileConfirmedSupplements(fromAuthenticated value: AskConversation, allowTerminal: Bool = false) {
        // Consumption comes only from API/engine transcript evidence, never cached display messages.
        sendQueue.reconcile(value.id, transcript: value.messages, run: nil)
        for flight in queueFlights[value.id]?.values.map({ $0 }) ?? [] {
            guard ownsQueueFlight(flight, conversationID: value.id) else { continue }
            let consumed = value.messages.contains {
                $0.id == flight.claim.item.id && $0.runId == flight.claim.originalRunID
            }
            let terminal = allowTerminal && value.run?.id == flight.claim.originalRunID
                && value.run?.deviceId == flight.originalDevice && value.run.map { ["completed", "failed", "cancelled"].contains($0.status) && !$0.needsRecoveryInspection } == true
            let discardedReplacement = allowTerminal && !sendQueue.owns(flight.claim, in: value.id)
                && value.run.map { !$0.id.isEmpty && $0.id != flight.claim.originalRunID } == true
            guard consumed || terminal || discardedReplacement else { continue }
            if consumed { sendQueue.remove(flight.claim.item.id, from: value.id) }
            else { sendQueue.restore(flight.claim, in: value.id) }
            sendQueue.release(flight.claim, in: value.id)
            queueFlights[value.id]?[flight.claim.item.id] = nil
            steeringIds.remove(flight.claim.item.id)
            if selectionGeneration != flight.selection { sendQueue.pause(value.id) }
            flight.task?.cancel()
        }
    }

    private func startSubmittedSend(_ submitted: AskDraft, conversation value: AskConversation,
                                    request: AskSendRequest, route current: AskRoute, operationId: UUID, inline: Bool) {
        let id = value.id, messageId = request.id
        let queueClaim = queuedSubmissions[id]
        if queueClaim != nil { queuedOperations.insert(operationId) }
        let temporaryRun = isTemporary(id), recoveryCheck = request.recoveryCheck == true
        operations[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                tools.discardFolderSubmission(messageID: messageId)
                if operationIds[id] == operationId, owner == current.account, session()?.owner == current.account {
                    restoreQueuedSubmission(id)
                }
                finishOperation(id, operationId: operationId)
            }
            var accepted = false
            let monitor = monitorConversation(id: id, current: current, operationId: operationId)
            defer { monitor.cancel() }
            do {
                try checkOperation(id, operationId: operationId, account: current.account)
                if let workspaces {
                    try await workspaces.saveConversation(value, owner: current.account)
                    try await workspaces.captureInputs(submitted.attachments ?? [], image: request.image,
                                                       messageId: messageId, owner: current.account,
                                                       conversationId: id)
                }
                try await cache.save(value, owner: current.owner)
                if inline, quickAsk?.conversationId == id { quickAsk?.persisted = true }
                var request = request
                let offered = inline ? [] : Self.offeredTools(await tools.definitions(conversationId: id), temporary: temporaryRun)
                request.tools = inline ? [] : recoveryCheck ? Self.recoveryObservationTools(offered) : offered
                try checkOperation(id, operationId: operationId, account: current.account)
                request.memory = request.memory?.usable(owner: current.account, invalidations: memoryInvalidations)
                pendingSends[id] = request
                let response = try await api.send(conversationId: id, request: request, token: current.token)
                try checkOperation(id, operationId: operationId, account: current.account)
                guard response.id == id, response.messages.contains(where: { $0.id == messageId }) else {
                    throw AskLocalError.message(L("ask.local.conflict"))
                }
                accepted = true
                await acknowledgeChatDraft(response, route: current)
                try checkOperation(id, operationId: operationId, account: current.account)
                // Queue ownership transfers only after drive publishes authoritative state.
                // Admit the staged folder selection first, preserving its existing exact scope.
                if queueClaim == nil { pendingSends[id] = nil }
                try admitFolderSubmission(response, conversationID: id, messageID: messageId, previousRunID: value.run?.id)
                if recoveryCheck, response.run?.recoveryCheck != true {
                    if let run = response.run, run.isActive {
                        _ = try? await api.cancel(conversationId: id, runId: run.id, token: current.token)
                    }
                    throw AskLocalError.message(L("ask.recovery.readOnlyUnavailable"))
                }
                try await drive(response, current: current, operationId: operationId, screenshotConsentMessageID: submitted.includeScreenshot ? messageId : nil, allowsTools: !inline)
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, operationIds[id] == operationId else { return }
                if let claim = queueClaim, !accepted || queuedSubmissions[id] != nil {
                    guard queuedSubmissions[id] == claim, sendQueue.owns(claim, in: id) else { return }
                    await reportOperationError(AskLocalError.message(L("ask.queue.reconcile")), id: id, owner: current.account)
                } else {
                    await reportOperationError(error, id: id, owner: current.account)
                }
            }
        }
    }

    private func reconcileConfirmedQueuedSubmission(fromAuthenticated value: AskConversation) {
        guard session()?.owner == owner, let claim = queuedSubmissions[value.id], let pending = pendingSends[value.id],
              claim.item.id == pending.id, value.messages.contains(where: { $0.id == pending.id }) else { return }
        pendingSends[value.id] = nil
        acknowledgeQueuedSubmission(value.id, messageID: pending.id)
    }

    /// The existing pending submission remains the only sender for its idempotent request.
    private func resumePendingSend(_ pending: AskSendRequest, conversation value: AskConversation,
                                   route current: AskRoute, operationId: UUID) async throws -> AskConversation {
        let id = value.id
        let queueClaim = queuedSubmissions[id]
        if let claim = queueClaim {
            let fresh = try? await api.conversation(id: id, token: current.token)
            try checkOperation(id, operationId: operationId, account: current.account)
            if let fresh, fresh.id == id, fresh.messages.contains(where: { $0.id == pending.id }) {
                try await accept(fresh, route: current, operationId: operationId)
                try checkOperation(id, operationId: operationId, account: current.account)
                return fresh
            }
            // Discarded intent and a different active task allow inspection only.
            guard sendQueue.owns(claim, in: id), fresh?.run?.isActive != true,
                  fresh?.run?.needsRecoveryInspection != true else {
                throw AskLocalError.message(L("ask.queue.reconcile"))
            }
        }
        try await validateModel(pending.modelRef, token: current.token,
                                hasImage: pending.sendsImage || value.messages.contains(where: { $0.hasImage }))
        var request = pending
        request.memory = request.memory?.usable(owner: current.account, invalidations: memoryInvalidations)
        try checkOperation(id, operationId: operationId, account: current.account)
        let response: AskConversation
        do { response = try await api.send(conversationId: id, request: request, token: current.token) }
        catch {
            try checkOperation(id, operationId: operationId, account: current.account)
            if let claim = queueClaim,
               queuedSubmissions[id] != claim || !sendQueue.owns(claim, in: id) { throw CancellationError() }
            throw error
        }
        try checkOperation(id, operationId: operationId, account: current.account)
        guard response.id == id, response.messages.contains(where: { $0.id == pending.id }) else {
            throw AskLocalError.message(L("ask.local.conflict"))
        }
        try await accept(response, route: current, operationId: operationId)
        try checkOperation(id, operationId: operationId, account: current.account)
        await acknowledgeChatDraft(response, route: current)
        try checkOperation(id, operationId: operationId, account: current.account)
        return response
    }

    private func acknowledgeQueuedSubmission(_ id: String, messageID: String) {
        guard let claim = queuedSubmissions[id], claim.item.id == messageID else { return }
        sendQueue.remove(messageID, from: id)
        sendQueue.release(claim, in: id)
        if let generation = queuedSubmissionSelections[id], generation != selectionGeneration { sendQueue.pause(id) }
        queuedSubmissions[id] = nil; queuedSubmissionSelections[id] = nil
    }

    private func restoreQueuedSubmission(_ id: String) {
        guard session()?.owner == owner, let claim = queuedSubmissions[id] else { return }
        sendQueue.restore(claim, in: id)
        if pendingSends[id] == nil {
            sendQueue.release(claim, in: id)
            queuedSubmissions[id] = nil; queuedSubmissionSelections[id] = nil
        }
    }

    private func queueDisposition(_ value: AskConversation, ignoringPause: Bool = false) -> AskQueueDisposition {
        let receiptBlocked = (recoveryEntries[value.id] ?? []).contains {
            $0.readUnavailable || (!$0.acknowledged && !$0.deleted && $0.receipt != nil
                && ($0.audit == nil || $0.audit?.identity.runId == value.run?.id))
        }
        return .resolve(run: value.run, recoveryBlocked: recoveryBlocksResume(value) || receiptBlocked,
                        submitting: busyIds.contains(value.id) || pendingSends[value.id] != nil,
                        steering: !(queueFlights[value.id]?.isEmpty ?? true), pendingApproval: pendingApprovals[value.id] != nil,
                        deviceID: deviceId, paused: !ignoringPause && sendQueue.isPaused(value.id),
                        hasItems: !sendQueue.messages(value.id).isEmpty)
    }

    func queueDidSettle(_ id: String) {
        guard session()?.owner == owner,
              let value = snapshots[id] ?? (selected?.id == id ? selected : nil) else { return }
        // Presentation can settle an admitted run, but cannot prove message consumption.
        sendQueue.reconcile(id, transcript: [], run: value.run)
        if queueDisposition(value) == .blocked(.recovery) { sendQueue.pause(id); return }
        guard selectedId == id, selected != nil, !isLoadingSelection, queueDisposition(value) == .ready,
              let next = sendQueue.next(for: id), let claim = sendQueue.claim(next.id, in: id),
              let item = sendQueue.take(next.id, from: id) else { return }
        queuedSubmissions[id] = claim
        submit(item.draft, newConversation: false, messageId: item.id, clearsDraft: false)
    }

}

// MARK: - Inline launcher conversation

extension AskConversationModel {
    var quickAskConversation: AskConversation? {
        guard let quickAsk, quickAsk.owner == owner, session()?.owner == owner,
              let id = quickAsk.conversationId else { return nil }
        return snapshots[id]
    }

    var quickAskRunning: Bool {
        guard let quickAsk, quickAsk.owner == session()?.owner, !quickAsk.stopped else { return false }
        if quickAsk.conversationId == nil { return submissionPreflights[true] != nil }
        guard let id = quickAsk.conversationId else { return false }
        return busyIds.contains(id) || snapshots[id]?.run?.isActive == true
    }

    var quickAskAnswer: String {
        guard let value = quickAskConversation else { return "" }
        let answer = value.messages.filter { $0.role == "assistant" }.map(\.text).filter { !$0.isEmpty }
        let committed = value.run?.assistantId.map { id in value.messages.contains { $0.id == id } } ?? false
        let preview = committed ? "" : liveProgress(value)?.text ?? ""
        return (answer + (preview.isEmpty ? [] : [preview])).joined(separator: "\n\n")
    }

    var quickAskError: String? {
        if let quickAsk, quickAsk.owner != session()?.owner { return nil }
        if let id = quickAsk?.conversationId {
            let run = snapshots[id]?.run
            return operationErrors[id] ?? run?.failureLocalizationKey.map { L($0) } ?? run?.error
        }
        return submissionIssues[true]?.text
    }

    var canSubmitQuickAsk: Bool {
        canSendLauncher && launcherDraft.hasText && quickAsk?.conversationId == nil
            && !quickAskRunning && !isOpeningChat
    }

    func submitQuickAsk() {
        guard canSubmitQuickAsk else { return }
        guard let account = credentials() else {
            submissionIssues[true] = .init(text: L("ask.loginRequired"), offersSignIn: true)
            return
        }
        guard let keyword = plugins.keyword, keyword.pluginID == AskQuickAskPlugin.id else { return }
        if launcherDraft.temporary == true, !leaveTemporaryConversation(for: nil) { return }
        // Advanced inputs stay in the draft so opening Chat can transfer them intact.
        guard (launcherDraft.attachments ?? []).isEmpty, (launcherDraft.skills ?? []).isEmpty,
              (launcherDraft.mcpServers ?? []).isEmpty else {
            submissionIssues[true] = .init(text: L("ask.quickAsk.advanced"))
            return
        }
        var submitted = launcherDraft
        submitted.includeScreenshot = false
        submitted.screenshot = nil
        submitted.skills = nil
        submitted.mcpServers = nil
        quickAsk = AskQuickAskSession(owner: account.account, submitted: submitted, keyword: keyword)
        if submitted.temporary != true { recordLauncherInput(destination: .keyword, label: L("ask.quickAsk.title")) }
        submit(submitted, newConversation: true, launcher: true, quickAskGeneration: quickAsk?.generation)
    }

    func stopQuickAsk() {
        guard quickAskRunning else { return }
        quickAsk?.stopped = true
        if let id = quickAsk?.conversationId {
            stop(id: id)
        } else if let operation = submissionPreflights[true],
                  let id = operationIds.first(where: { $0.value == operation })?.key {
            stop(id: id)
            submissionPreflights[true] = nil
        }
    }

    func newQuickAskQuestion() {
        guard !quickAskRunning, !isOpeningChat else { return }
        quickAsk = nil
        submissionIssues[true] = nil
        launcherDraft = AskDraft(includeScreenshot: false, modelRef: launcherDraft.modelRef,
                                 storesLocally: launcherDraft.storesLocally, temporary: launcherDraft.temporary)
    }

    /// A hide stops an inline run, but never a run already transferred to Chat.
    func dismissQuickAsk() {
        guard plugins.keyword?.pluginID == AskQuickAskPlugin.id, quickAsk?.handedOff != true else { return }
        quickAsk?.restoreOnPresentation = true
        stopQuickAsk()
    }

    @discardableResult
    func openQuickAskInChat(focusComposer: Bool = false) async -> Bool {
        if !FeatureProcess.owns(.chat) { return await transferFeatureQuickAsk() }
        guard canOpenChatFromLauncher, let quick = quickAsk,
              quick.owner == owner, session()?.owner == owner,
              quick.persisted, let id = quick.conversationId, snapshots[id] != nil else { return false }
        guard leaveTemporaryConversation(for: id) else { return false }
        isOpeningChat = true
        defer { isOpeningChat = false }
        let generation = selectionGeneration, previousID = selectedId, previous = draft
        do {
            let preserved = sendQueue.editing.flatMap { $0.conversationId == previousID ? $0.stash : nil } ?? previous
            if let previousID, previousID != id, !isLoadingSelection {
                try await cache.saveDraft(preserved, key: previousID, owner: cacheOwner(previousID))
            } else if previousID == nil, preserved.hasChatInput, preserved.temporary != true {
                let saved = displacedChatDraft(preserved)
                try await saveChatDraft(saved.draft, key: saved.id, account: owner)
                if owner == quick.owner, session()?.owner == quick.owner { savedChatDrafts.append(saved) }
            }
            guard owner == quick.owner, session()?.owner == quick.owner,
                  quickAsk?.generation == quick.generation, selectionGeneration == generation,
                  draft == previous, !recordingIsActive(), !voiceInput.isOccupied, !capturing,
                  !isLoadingAttachments(launcher: true), !isLoadingAttachments(launcher: false),
                  let value = snapshots[id] else { return false }
            if previousID != id {
                detachChatDraft()
                cancelQueuedEdit(advancing: false)
                if let previousID { drafts[previousID] = preserved }
                stopSelectionObservation()
                selectedId = id; selected = value; isLoadingSelection = false; selectionLoadFailed = false
                selectionGeneration = UUID()
                draft = drafts[id] ?? .followUp
                clearCapturedContentFeedback(launcher: false)
            }
            error = operationErrors[id]
            submissionIssues[false] = nil
            quickAsk?.handedOff = true
            plugins.deactivate()
            launcherDraft = newQuestionDraft()
            persistDrafts()
            onShowConversation?()
            // showConversation focuses the composer for both entry points.
            _ = focusComposer
            return true
        } catch {
            confirm(L("ask.cache.failed"))
            return false
        }
    }
}
