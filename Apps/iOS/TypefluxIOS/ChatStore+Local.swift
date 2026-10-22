// swiftlint:disable file_length
import Foundation
import TypefluxChat

/// Model choice and private conversations. A conversation's storage follows the
/// model of its first message: Typeflux Cloud models keep it in the cloud; the
/// user's own providers keep it on this iPhone only. It never changes afterwards.
extension ChatStore {
    // MARK: Models

    /// Typeflux Cloud models first, then the user's own.
    var availableModels: [ChatModel] {
        models + library.models
    }

    /// Where the selected conversation is kept; nil before its first message.
    var conversationStorage: ChatStorage? {
        guard let id = selectedID else { return nil }
        if isLocalConversation(id) {
            return .local
        }
        if conversation?.messages.isEmpty == false || conversations.contains(where: { $0.id == id }) {
            return .cloud
        }
        return nil
    }

    func isLocalConversation(_ id: String) -> Bool {
        localTemporaryIDs.contains(id) || localConversations.contains { $0.id == id }
    }

    /// The next message goes to the user's own provider instead of Typeflux.
    var sendsLocally: Bool {
        switch conversationStorage {
        case .local: true
        case .cloud: false
        case nil: modelRef.hasPrefix(ChatProvider.referencePrefix)
        }
    }

    /// A model can be chosen when there is somewhere to send: an account or a provider.
    var canChooseModel: Bool {
        isAuthenticated || !library.models.isEmpty || sendsLocally
    }

    func allowsModel(_ model: ChatModel) -> Bool {
        switch conversationStorage {
        case .local: model.isLocal
        case .cloud: !model.isLocal
        case nil: true
        }
    }

    var storageIssue: String? {
        switch conversationStorage {
        case .local where !modelRef.hasPrefix(ChatProvider.referencePrefix):
            "This conversation is kept on this iPhone. Choose one of your own models."
        case .cloud where modelRef.hasPrefix(ChatProvider.referencePrefix):
            "This conversation is kept in Typeflux Cloud. Choose a Typeflux Cloud model."
        default: nil
        }
    }

    /// The model a new conversation starts with: the default when it is available,
    /// else the first Typeflux Cloud model, else the first of the user's own.
    var preferredModelRef: String {
        if let reference = library.defaultModelRef, availableModels.contains(where: { $0.reference == reference }) {
            return reference
        }
        return models.first?.reference ?? library.models.first?.reference ?? ""
    }

    /// Picks the preferred model while the composer still shows an automatic choice,
    /// e.g. when the catalog arrives after the conversation opened. A selection the
    /// user made, or one that became unavailable, is never replaced silently.
    func adoptPreferredModelIfUnset() {
        guard conversationStorage == nil, modelRef.isEmpty || modelRef == automaticModelRef else { return }
        modelRef = preferredModelRef
        automaticModelRef = modelRef
    }

    func setDefaultModel(_ reference: String?) {
        library.defaultModelRef = reference
        if conversationStorage == nil, !isBusy, let reference,
           availableModels.contains(where: { $0.reference == reference }) {
            modelRef = reference
        }
    }

    /// Remembers the model last used in a conversation, so reopening it restores the choice.
    func rememberModel(_ reference: String, for id: String) {
        guard !reference.isEmpty else { return }
        if isLocalConversation(id) {
            guard let localStore else { return }
            Task { try? await localStore.setModelRef(reference, id: id, owner: Self.localOwner) }
        } else if let owner = cacheOwner, let cache {
            Task { try? await cache.setModelRef(reference, id: id, owner: owner) }
        }
    }

    /// Restores a reopened conversation's model when it is still available.
    func restoreModel(_ reference: String?) {
        guard let reference, !isBusy,
              let model = availableModels.first(where: { $0.reference == reference }),
              allowsModel(model) else { return }
        modelRef = model.reference
    }

    /// The name shown under an answer: the model that wrote it, when known.
    func modelLabel(for message: ChatMessage) -> String? {
        guard message.role == "assistant" else { return nil }
        let latest = conversation?.messages.last(where: { $0.role == "assistant" })?.id == message.id
        // The server names the catalog model that answered; "Auto" shows where it was routed.
        if let served = message.modelName ?? (latest ? conversation?.run?.modelName : nil), !served.isEmpty {
            let requested = latest ? conversation?.run?.modelRef : nil
            return latest && requested == "cloud:default"
                ? String(format: NSLocalizedString("Auto → %@", comment: "Routed model"), served) : served
        }
        guard let reference = message.modelRef ?? (latest ? conversation?.run?.modelRef : nil) else { return nil }
        if let model = availableModels.first(where: { $0.reference == reference }) {
            return model.providerName.map { $0 + " · " + model.name } ?? model.name
        }
        if let parts = ChatProvider.parse(reference: reference) {
            return parts.model
        }
        return reference.hasPrefix("cloud:") ? String(reference.dropFirst(6)) : nil
    }

    // MARK: Private conversations

    func loadLocalHome() async {
        guard let localStore else { return }
        let summaries = (try? await localStore.summaries(owner: Self.localOwner)) ?? []
        localConversations = summaries.map(\.summary)
    }

    func openLocal(_ id: String) async {
        guard let localStore else { return }
        let selection = selectionGeneration
        isLoadingConversation = true
        defer {
            if selection == selectionGeneration {
                isLoadingConversation = false
            }
        }
        let stored = try? await localStore.conversation(id: id, owner: Self.localOwner)
        let reference = try? await localStore.modelRef(id: id, owner: Self.localOwner)
        guard selection == selectionGeneration, var value = stored else { return }
        if value.run?.isActive == true, localTasks[id] == nil {
            // The app ended while answering; the partial answer was not kept.
            value = ChatLocalConversation.finish(value, status: "failed", text: "", reasoning: "",
                                                 reasoningMilliseconds: nil, error: Self.interruptedMessage)
            try? await localStore.save(value, storage: .local, owner: Self.localOwner)
        }
        conversation = value
        restoreModel(reference ?? value.run?.modelRef)
        if !modelRef.hasPrefix(ChatProvider.referencePrefix), let first = library.models.first {
            modelRef = first.reference
        }
        await restoreDraft()
    }

    func sendLocal() async {
        guard canSend else { return }
        guard let resolved = library.resolve(modelRef) else {
            errorMessage = "Choose one of your own models."
            return
        }
        let key = library.key(for: resolved.provider.id)
        if resolved.provider.kind.requiresKey, key?.isEmpty != false {
            errorMessage = Self.missingKeyMessage
            return
        }
        let id = selectedID ?? UUID().uuidString.lowercased()
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if startsTemporary, conversationStorage == nil {
            // Kept in memory only: never written to the device store or listed.
            temporaryIDs.insert(id)
            localTemporaryIDs.insert(id)
        }
        let start = ChatLocalConversation.begin(conversationStorage == .local ? conversation : nil, id: id,
                                                text: text, image: imageDataURL, modelRef: modelRef,
                                                deviceID: deviceID)
        selectedID = id
        conversation = start
        draft = ""
        imageDataURL = nil
        errorMessage = nil
        offersLocalFallback = false
        discardNewDraft()
        await storeLocal(start)
        await runLocal(start, provider: resolved.provider, model: resolved.model.id, key: key)
    }

    /// The answer "Regenerate" or "Try again" writes again in a private conversation.
    var localRetryMessageID: String? {
        guard !isBusy, let value = conversation, let last = value.messages.last else { return nil }
        if last.role == "assistant", !last.text.isEmpty {
            return last.id
        }
        if last.role == "user", let run = value.run, run.status == "failed" || run.status == "cancelled" {
            return last.id
        }
        return nil
    }

    func regenerateLocal(messageID: String) async {
        guard let value = conversation, localRetryMessageID == messageID, composerValidation == nil,
              let resolved = library.resolve(modelRef) else { return }
        let key = library.key(for: resolved.provider.id)
        if resolved.provider.kind.requiresKey, key?.isEmpty != false {
            errorMessage = Self.missingKeyMessage
            return
        }
        let start: ChatConversation? = value.messages.last?.role == "user"
            ? ChatLocalConversation.running(value, modelRef: modelRef, deviceID: deviceID)
            : ChatLocalConversation.regenerate(value, messageID: messageID, modelRef: modelRef, deviceID: deviceID)
        guard let start else { return }
        conversation = start
        errorMessage = nil
        await storeLocal(start)
        await runLocal(start, provider: resolved.provider, model: resolved.model.id, key: key)
    }

    func deleteLocal(_ id: String) async {
        deletedLocalIDs.insert(id)
        localTasks[id]?.cancel()
        localConversations.removeAll { $0.id == id }
        try? await localStore?.delete(id: id, owner: Self.localOwner)
        if selectedID == id {
            newConversation()
        }
    }

    /// Carries an unsent cloud draft into a new private conversation with the user's model.
    func continueInPrivateConversation() {
        let reference = library.defaultModelRef.flatMap { reference in
            library.models.first { $0.reference == reference }?.reference
        } ?? library.models.first?.reference
        guard let reference else { return }
        let text = draft, image = imageDataURL
        example = nil
        changeSelection(UUID().uuidString.lowercased())
        modelRef = reference
        draft = text
        imageDataURL = image
    }

    // MARK: Streaming

    func storeLocal(_ value: ChatConversation) async {
        guard !deletedLocalIDs.contains(value.id), !localTemporaryIDs.contains(value.id) else { return }
        try? await localStore?.save(value, storage: .local, owner: Self.localOwner, modelRef: value.run?.modelRef)
        guard !deletedLocalIDs.contains(value.id) else {
            // Deleted while saving: the deletion was queued after this write, so it wins.
            return
        }
        let summary = ChatConversationSummary(id: value.id, title: value.title, updatedAt: value.updatedAt)
        localConversations.removeAll { $0.id == value.id }
        localConversations.insert(summary, at: 0)
    }

    private func runLocal(_ start: ChatConversation, provider: ChatProvider, model: String, key: String?) async {
        let request = ChatProviderRequest(provider: provider, apiKey: key, model: model,
                                          system: ChatLocalConversation.system(),
                                          messages: ChatLocalConversation.providerMessages(start))
        let task = Task { [weak self] in
            guard let self else { return }
            await stream(request, from: start)
        }
        localTasks[start.id] = task
        await task.value
        if localTasks[start.id] == task {
            localTasks[start.id] = nil
        }
    }

    private func stream(_ request: ChatProviderRequest, from start: ChatConversation) async {
        let started = Date()
        var working = start, text = "", reasoning = "", status = "completed"
        var failure: String?
        do {
            for try await event in providerService.stream(request) {
                switch event {
                case let .text(value): text += value
                case let .reasoning(value): reasoning += value
                }
                working = ChatLocalConversation.progress(working, text: text, reasoning: reasoning, started: started)
                show(working)
            }
            if Task.isCancelled {
                status = "cancelled"
            }
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                status = "cancelled"
            } else {
                status = "failed"
                failure = Self.providerMessage(for: error)
            }
        }
        let thinking = working.run?.reasoningMilliseconds
        working = ChatLocalConversation.finish(working, status: status, text: text, reasoning: reasoning,
                                               reasoningMilliseconds: thinking, error: failure)
        // A conversation deleted while it was answering must not come back.
        guard !deletedLocalIDs.contains(start.id) else { return }
        show(working)
        await storeLocal(working)
        if status == "completed" {
            requestLocalTitleIfNeeded(working, provider: request.provider, key: request.apiKey, model: request.model)
        }
    }

    /// Updates the screen only while the conversation is still selected.
    private func show(_ value: ChatConversation) {
        if selectedID == value.id {
            conversation = value
        }
    }

    nonisolated static let missingKeyMessage = "Add an API key for this provider in Settings → Model providers."
    nonisolated static let interruptedMessage = "The answer was interrupted. Try again."

    /// A sentence for a failure of the user's own provider. Provider diagnostics are not shown.
    nonisolated static func providerMessage(for error: Error) -> String {
        switch error {
        case ChatProviderError.invalidKey:
            "Your provider rejected the API key. Check it in Settings → Model providers."
        case ChatProviderError.missingKey:
            missingKeyMessage
        case ChatProviderError.notFound:
            "Your provider doesn't offer this model or address. Check the model in Settings → Model providers."
        case ChatProviderError.rateLimited:
            "Your provider is limiting requests. Wait a moment and try again."
        case ChatProviderError.redirected:
            "The provider address redirects elsewhere, so Typeflux stopped to protect your key. Use the final address."
        case ChatProviderError.invalidEndpoint:
            "This provider address isn't allowed. Use HTTPS, or HTTP on your local network."
        case let error as URLError:
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                "You're offline. Check your connection and try again."
            default:
                "Couldn't reach your provider. Check the address and your connection."
            }
        default:
            "Your provider couldn't answer right now. Please try again."
        }
    }
}

/// The sidebar's filter while conversations are kept both in Typeflux Cloud and on this iPhone.
enum ChatHistoryFilter: String, CaseIterable, Identifiable {
    case all, cloud, local

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .cloud: "Cloud"
        case .local: "On this iPhone"
        }
    }
}

/// Chats and work: work is started and run on a Mac; the phone reads it.
enum ChatKindFilter: String, CaseIterable, Identifiable {
    case all, chat, work

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .chat: "Chats"
        case .work: "Work"
        }
    }

    func includes(_ item: ChatConversationSummary) -> Bool {
        switch self {
        case .all: true
        case .chat: !item.isWork
        case .work: item.isWork
        }
    }
}

extension ChatStore {
    /// Cloud and private conversations, newest first.
    func history(_ filter: ChatHistoryFilter, kind: ChatKindFilter = .all) -> [ChatConversationSummary] {
        let cloud = filter == .local ? [] : conversations
        let local = filter == .cloud ? [] : localConversations
        return (cloud + local).filter(kind.includes).sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The kind filter is offered once a Mac has synchronized any work.
    var hasWork: Bool { conversations.contains { $0.isWork } }

    /// The filter is offered only when both kinds exist.
    var hasBothStorages: Bool {
        !conversations.isEmpty && !localConversations.isEmpty
    }
}
