// swiftlint:disable file_length
import Foundation
import Observation
import TypefluxChat

@MainActor @Observable
final class ChatStore {
    private(set) var email = ""
    private(set) var isAuthenticated = false
    private(set) var isLoading = false
    private(set) var isLoadingConversation = false
    private(set) var isSending = false
    private(set) var conversations: [ChatConversationSummary] = []
    private(set) var models: [ChatModel] = []
    private(set) var conversation: ChatConversation?
    private(set) var selectedID: String?
    private(set) var hasMore = false
    var modelRef = "" {
        didSet { reasoningEffort = reasoningEffort.nearest(in: supportedReasoningLevels) }
    }

    private(set) var reasoningEffort: ChatReasoningEffort = .providerDefault
    var draft = ""
    var imageDataURL: String?
    var errorMessage: String?

    let isSynthetic: Bool
    let deviceID: String
    private let service: any ChatAPI
    private let credentials: any CredentialStore
    private let reconnectDelay: Duration
    private var session: ChatSession?
    private var accountGeneration = 0
    private var selectionGeneration = 0
    private var observationTask: Task<Void, Never>?
    private var refreshTask: Task<ChatSession, Error>?
    private var isForeground = true
    private var pendingRequest: ChatSendRequest?
    private var activeSendID: String?
    private var requiresConversationSnapshot = false

    init(
        service: any ChatAPI,
        credentials: any CredentialStore,
        deviceID: String,
        isSynthetic: Bool = false,
        reconnectDelay: Duration = .milliseconds(500)
    ) {
        self.service = service
        self.credentials = credentials
        self.deviceID = deviceID
        self.isSynthetic = isSynthetic
        self.reconnectDelay = reconnectDelay
    }

    func restore() async {
        guard !isAuthenticated else { return }
        do {
            guard let account = try credentials.load() else { return }
            email = account.email
            session = account.session
            isAuthenticated = true
            await refreshHome()
        } catch { errorMessage = error.localizedDescription }
    }

    func login(email: String, password: String) async {
        resetAccount()
        let generation = accountGeneration
        isLoading = true
        defer {
            if generation == accountGeneration {
                isLoading = false
            }
        }
        do {
            try credentials.clear()
            let account = try await service.login(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )
            try checkAccount(generation)
            try credentials.save(SavedAccount(email: email, session: account))
            self.email = email
            session = account
            isAuthenticated = true
            await refreshHome()
        } catch { report(error, generation: generation) }
    }

    func signOut() async {
        let token = session?.refreshToken
        resetAccount()
        do { try credentials.clear() } catch { errorMessage = error.localizedDescription }
        // Local state is gone before awaiting server revocation.
        if let token {
            try? await service.logout(refreshToken: token)
        }
    }

    func refreshHome() async {
        guard isAuthenticated else { return }
        let generation = accountGeneration
        isLoading = true
        defer {
            if generation == accountGeneration {
                isLoading = false
            }
        }
        do {
            let values = try await authorized { [service] token in try await service.list(token: token, offset: 0) }
            try checkAccount(generation)
            conversations = values
            hasMore = !values.isEmpty
            let catalog = try await authorized { [service] token in try await service.models(token: token) }
            try checkAccount(generation)
            models = catalog
            if !models.contains(where: { $0.reference == modelRef }) {
                modelRef = models.first?.reference ?? ""
            }
            reasoningEffort = reasoningEffort.nearest(in: supportedReasoningLevels)
        } catch { report(error, generation: generation) }
    }

    func loadMore() async {
        guard isAuthenticated, hasMore, !isLoading else { return }
        let generation = accountGeneration
        let offset = conversations.count
        isLoading = true
        defer {
            if generation == accountGeneration {
                isLoading = false
            }
        }
        do {
            let values = try await authorized { [service] token in
                try await service.list(token: token, offset: offset)
            }
            try checkAccount(generation)
            let existing = Set(conversations.map(\.id))
            let additions = values.filter { !existing.contains($0.id) }
            conversations += additions
            hasMore = !additions.isEmpty
        } catch { report(error, generation: generation) }
    }

    func newConversation() {
        changeSelection(UUID().uuidString.lowercased())
    }

    func select(_ id: String) async {
        changeSelection(id)
        requiresConversationSnapshot = true
        await reloadConversation()
    }

    func reloadConversation(reportFailure: Bool = true) async {
        guard let id = selectedID, isAuthenticated else { return }
        let generation = accountGeneration
        let selection = selectionGeneration
        isLoadingConversation = true
        defer {
            if generation == accountGeneration, selection == selectionGeneration {
                isLoadingConversation = false
            }
        }
        do {
            let value = try await authorized { [service] token in try await service.conversation(id: id, token: token) }
            guard generation == accountGeneration, selection == selectionGeneration else { return }
            accept(value)
            if reportFailure {
                errorMessage = nil
            }
            startObservation()
        } catch {
            if reportFailure, selection == selectionGeneration {
                report(error, generation: generation)
            }
        }
    }

    func send() async {
        guard canSend else { return }
        if selectedID == nil {
            selectedID = UUID().uuidString.lowercased()
        }
        guard let id = selectedID else { return }
        let generation = accountGeneration
        let selection = selectionGeneration
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = sendRequest(text: text)
        pendingRequest = request
        activeSendID = request.id
        isSending = true
        errorMessage = nil
        defer {
            if generation == accountGeneration, selection == selectionGeneration, activeSendID == request.id {
                isSending = false
                activeSendID = nil
            }
        }
        do {
            let value = try await authorized { [service] token in try await service.send(
                conversationId: id,
                request: request,
                token: token
            ) }
            guard generation == accountGeneration, selection == selectionGeneration else { return }
            draft = ""
            imageDataURL = nil
            pendingRequest = nil
            accept(value)
            isSending = false
            activeSendID = nil
            startObservation()
            await refreshHome()
        } catch {
            if selection == selectionGeneration {
                report(error, generation: generation)
                // A transport failure can happen after the server accepted the message.
                // Reloading never repeats a POST; the draft remains available for inspection.
                if isAuthenticated {
                    await reloadConversation(reportFailure: false)
                }
                if generation == accountGeneration, selection == selectionGeneration,
                   conversation?.messages.contains(where: { $0.id == request.id }) == true {
                    draft = ""
                    imageDataURL = nil
                    pendingRequest = nil
                    errorMessage = nil
                }
            }
        }
    }

    func cancelRun() async {
        guard let value = conversation, let run = value.run, run.isActive else { return }
        let generation = accountGeneration
        let selection = selectionGeneration
        do {
            let updated = try await authorized { [service] token in try await service.cancel(
                conversationId: value.id,
                runId: run.id,
                token: token
            ) }
            guard generation == accountGeneration, selection == selectionGeneration else { return }
            accept(updated)
        } catch {
            if selection == selectionGeneration {
                report(error, generation: generation)
            }
        }
    }

    func setForeground(_ foreground: Bool) async {
        isForeground = foreground
        observationTask?.cancel()
        observationTask = nil
        if foreground, isAuthenticated {
            await refreshHome()
            if conversation != nil {
                await reloadConversation()
            }
        }
    }
}

extension ChatStore {
    var isRunning: Bool {
        conversation?.run?.isActive == true
    }

    var composerValidation: String? {
        if requiresConversationSnapshot, conversation == nil {
            return "Load this conversation before sending a follow-up."
        }
        if draft.utf8.count > 32000 {
            return "Keep messages under 32 KB."
        }
        if isAuthenticated, !models.contains(where: { $0.reference == modelRef }) {
            return "Choose an available cloud model. Refresh if the model list is empty."
        }
        if hasConversationImages, selectedModel?.vision != true {
            if conversation?.messages.contains(where: \.hasImage) == true {
                return "This conversation contains photos. Choose a model that supports photos."
            }
            return "Choose a model that supports photos, or remove the attached photo."
        }
        return nil
    }

    var canSend: Bool {
        isAuthenticated && !isSending && !isRunning && composerValidation == nil && !draft
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var attachmentContext: String {
        "\(accountGeneration):\(selectionGeneration)"
    }

    var isBusy: Bool {
        isSending || isRunning
    }

    var selectedModel: ChatModel? {
        models.first { $0.reference == modelRef }
    }

    var selectedModelID: String? {
        selectedModel?.id
    }

    var supportedReasoningLevels: [ChatReasoningEffort] {
        ChatReasoningEffort.levels(for: selectedModel)
    }

    var hasConversationImages: Bool {
        imageDataURL != nil || conversation?.messages.contains(where: \.hasImage) == true
    }

    @discardableResult
    func selectModel(_ model: ChatModel) -> Bool {
        guard !isBusy, let available = models.first(where: { $0.reference == model.reference }),
              !hasConversationImages || available.vision == true else { return false }
        modelRef = available.reference
        return true
    }

    func selectReasoningEffort(_ effort: ChatReasoningEffort) {
        guard !isBusy else { return }
        reasoningEffort = effort.nearest(in: supportedReasoningLevels)
    }
}

private extension ChatStore {
    func sendRequest(text: String) -> ChatSendRequest {
        let requestedModel = modelRef.isEmpty ? nil : modelRef
        let requestedEffort = reasoningEffort.requestValue(for: selectedModel)
        if let pendingRequest, pendingRequest.text == text, pendingRequest.image == imageDataURL,
           pendingRequest.modelRef == requestedModel, pendingRequest.reasoningEffort == requestedEffort {
            return pendingRequest
        }
        return ChatSendRequest(deviceId: deviceID, text: text, image: imageDataURL,
                               modelRef: requestedModel, reasoningEffort: requestedEffort)
    }

    private func changeSelection(_ id: String) {
        observationTask?.cancel()
        observationTask = nil
        selectionGeneration += 1
        selectedID = id
        conversation = nil
        requiresConversationSnapshot = false
        isLoadingConversation = false
        draft = ""
        imageDataURL = nil
        modelRef = models.first?.reference ?? ""
        reasoningEffort = .providerDefault
        errorMessage = nil
        isSending = false
        pendingRequest = nil
        activeSendID = nil
    }

    private func accept(_ value: ChatConversation) {
        guard value.id == selectedID else { return }
        if let current = conversation, value.revision < current.revision {
            return
        }
        conversation = value
    }

    private func startObservation() {
        observationTask?.cancel()
        guard isForeground, let id = selectedID, isRunning else { return }
        let generation = accountGeneration
        let selection = selectionGeneration
        observationTask = Task { [weak self] in
            guard let self else { return }
            var failures = 0
            var reconnecting = false
            while observationIsCurrent(generation: generation, selection: selection) {
                do {
                    if reconnecting {
                        guard try await refreshObservedConversation(id: id, generation: generation,
                                                                    selection: selection) else { return }
                    }
                    try await authorized { [service] token in
                        try await service.observe(id: id, token: token) { [weak self] value in
                            try Task.checkCancellation()
                            await self?.receive(value, generation: generation, selection: selection)
                        }
                    }
                    if !isRunning {
                        return
                    }
                    // The server deliberately closes healthy streams after 30 seconds.
                    // A normal EOF does not consume the network-failure retry budget.
                    failures = 0
                } catch {
                    guard observationIsCurrent(generation: generation, selection: selection),
                          !(error is CancellationError) else { return }
                    failures += 1
                    if failures > 3 {
                        errorMessage = "Live updates paused. Refresh this conversation to reconnect."
                        return
                    }
                }
                do {
                    try await Task.sleep(for: reconnectDelay * (1 << max(0, failures - 1)))
                } catch { return }
                reconnecting = true
            }
        }
    }

    private func refreshObservedConversation(id: String, generation: Int, selection: Int) async throws -> Bool {
        let snapshot = try await authorized { [service] token in
            try await service.conversation(id: id, token: token)
        }
        guard generation == accountGeneration, selection == selectionGeneration else { return false }
        accept(snapshot)
        return isRunning
    }

    func observationIsCurrent(generation: Int, selection: Int) -> Bool {
        !Task.isCancelled && generation == accountGeneration && selection == selectionGeneration
    }

    private func receive(_ value: ChatConversation, generation: Int, selection: Int) {
        guard generation == accountGeneration, selection == selectionGeneration else { return }
        accept(value)
    }

    private func authorized<Value: Sendable>(_ operation: (String) async throws -> Value) async throws -> Value {
        let generation = accountGeneration
        guard let current = session else { throw ChatAPIError.unauthorized }
        do {
            let result = try await operation(current.accessToken)
            try checkAccount(generation)
            return result
        } catch ChatAPIError.unauthorized {
            try checkAccount(generation)
            do {
                let fresh: ChatSession = if let session, session.accessToken != current.accessToken {
                    session
                } else {
                    try await refreshSession(generation: generation)
                }
                try checkAccount(generation)
                let result = try await operation(fresh.accessToken)
                try checkAccount(generation)
                return result
            } catch ChatAPIError.unauthorized {
                if generation == accountGeneration {
                    resetAccount()
                    try? credentials.clear()
                    errorMessage = "Your session expired. Please sign in again."
                }
                throw CancellationError()
            }
        }
    }

    private func refreshSession(generation: Int) async throws -> ChatSession {
        guard let token = session?.refreshToken else { throw ChatAPIError.unauthorized }
        if let refreshTask {
            return try await refreshTask.value
        }
        let task = Task { [weak self, service] in
            let fresh = try await service.refresh(refreshToken: token)
            // Token rotation belongs to the account, not to the request that
            // noticed expiry. Persist it even if that view/stream was cancelled.
            guard let self, generation == accountGeneration else { throw CancellationError() }
            try credentials.save(SavedAccount(email: email, session: fresh))
            session = fresh
            return fresh
        }
        refreshTask = task
        defer {
            if generation == accountGeneration {
                refreshTask = nil
            }
        }
        let fresh = try await task.value
        try checkAccount(generation)
        return fresh
    }

    private func checkAccount(_ generation: Int) throws {
        try Task.checkCancellation()
        guard generation == accountGeneration else { throw CancellationError() }
    }

    private func resetAccount() {
        accountGeneration += 1
        observationTask?.cancel()
        observationTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        session = nil
        email = ""
        isAuthenticated = false
        isLoading = false
        conversations = []
        models = []
        modelRef = ""
        hasMore = false
        changeSelection(UUID().uuidString.lowercased())
        selectedID = nil
    }

    private func report(_ error: Error, generation: Int) {
        guard generation == accountGeneration, !(error is CancellationError), !Task.isCancelled else { return }
        if case let ChatAPIError.server(_, message) = error {
            errorMessage = message ?? "The server could not complete this request."
        } else if case ChatAPIError.unauthorized = error {
            errorMessage = "Please check your email and password."
        } else {
            errorMessage = error.localizedDescription
        }
    }
}
