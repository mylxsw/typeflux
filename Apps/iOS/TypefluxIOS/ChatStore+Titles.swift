import Foundation
import TypefluxChat

/// Temporary conversations, renaming and generated titles.
extension ChatStore {
    // MARK: Temporary conversations

    /// The selected conversation is temporary, or the next message starts one.
    var isTemporary: Bool {
        if let id = selectedID, temporaryIDs.contains(id) {
            return true
        }
        return startsTemporary && conversationStorage == nil
    }

    /// Temporary is chosen before the first message; private ones need no account.
    var canStartTemporary: Bool {
        conversationStorage == nil && !isBusy && (sendsLocally || isAuthenticated)
    }

    func toggleTemporary() {
        guard canStartTemporary else { return }
        startsTemporary.toggle()
    }

    /// Forgets a temporary conversation once it is left. The cloud copy is deleted;
    /// the server also expires it after 24 hours if this request never arrives.
    func discardTemporary(_ id: String) {
        temporaryIDs.remove(id)
        if localTemporaryIDs.remove(id) != nil {
            localTasks[id]?.cancel()
            return
        }
        guard isAuthenticated else { return }
        Task { [weak self] in
            guard let self else { return }
            _ = try? await authorized { [service] token in
                try await service.deleteConversation(id: id, token: token)
            }
        }
    }

    /// Turns the selected temporary conversation into an ordinary, listed one.
    func keepTemporary() async {
        guard let id = selectedID, temporaryIDs.contains(id), !isBusy else { return }
        if localTemporaryIDs.contains(id) {
            temporaryIDs.remove(id)
            localTemporaryIDs.remove(id)
            if let conversation {
                await storeLocal(conversation)
            }
            return
        }
        let generation = accountGeneration
        do {
            let value = try await authorized { [service] token in try await service.keep(conversationId: id, token: token) }
            guard generation == accountGeneration else { return }
            temporaryIDs.remove(id)
            accept(value)
            conversations.removeAll { $0.id == id }
            conversations.insert(ChatConversationSummary(id: value.id, title: value.title, updatedAt: value.updatedAt),
                                 at: 0)
        } catch {
            guard !noteConnectivity(error, generation: generation) else {
                errorMessage = Self.unavailableActionMessage
                return
            }
            report(error, generation: generation)
        }
    }

    nonisolated static let unavailableActionMessage = "Typeflux is unavailable right now. Try again when you're back online."

    // MARK: Renaming

    /// Renames a conversation. Returns false with an explanation when it cannot.
    @discardableResult
    func rename(_ id: String, to proposed: String) async -> Bool {
        guard let title = ChatConversationTitle.clean(proposed) else {
            errorMessage = "Use a single line of up to 60 characters."
            return false
        }
        if selectedID == id, isBusy {
            errorMessage = "Wait for the answer to finish, then rename the conversation."
            return false
        }
        if isLocalConversation(id) {
            var value = selectedID == id ? conversation : nil
            if value == nil {
                value = try? await localStore?.conversation(id: id, owner: Self.localOwner)
            }
            guard var value else { return false }
            value.title = title
            value.titleSource = "manual"
            if selectedID == id {
                conversation = value
            }
            await storeLocal(value)
            return true
        }
        guard isAuthenticated else { return false }
        let generation = accountGeneration
        do {
            let value = try await authorized { [service] token in
                try await service.updateTitle(conversationId: id, request: .rename(title), token: token)
            }
            guard generation == accountGeneration else { return false }
            applyCloudTitle(value)
            return true
        } catch {
            if noteConnectivity(error, generation: generation) {
                errorMessage = Self.unavailableActionMessage
            } else {
                report(error, generation: generation)
            }
            return false
        }
    }

    private func applyCloudTitle(_ value: ChatConversation) {
        if let index = conversations.firstIndex(where: { $0.id == value.id }) {
            conversations[index].title = value.title
        }
        if selectedID == value.id {
            accept(value)
        } else {
            cacheConversation(value)
        }
    }

    // MARK: Generated titles

    /// After the second completed answer, asks the server to name a cloud
    /// conversation once, then picks up the new title.
    func requestCloudTitleIfNeeded(_ value: ChatConversation) {
        guard isAuthenticated, !isLocalConversation(value.id), !temporaryIDs.contains(value.id),
              value.run?.status == "completed", ChatConversationTitle.needsTitle(value),
              titleRequestedIDs.insert(value.id).inserted else { return }
        let id = value.id, generation = accountGeneration, delay = titleRefreshDelay
        titleTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { titleTasks[id] = nil }
            do {
                _ = try await authorized { [service] token in
                    try await service.updateTitle(conversationId: id, request: .generate(), token: token)
                }
                // The server names the conversation in the background.
                try await Task.sleep(for: delay)
                let named = try await authorized { [service] token in
                    try await service.conversation(id: id, token: token)
                }
                guard generation == accountGeneration, named.titleSource == "auto" || named.title != value.title
                else { return }
                applyCloudTitle(named)
            } catch {
                // Naming is best-effort; the provisional title stays.
            }
        }
    }

    /// After the second completed answer, names a private conversation with the
    /// same model, on this device. Nothing leaves the device but the provider call.
    func requestLocalTitleIfNeeded(_ value: ChatConversation, provider: ChatProvider, key: String?, model: String) {
        guard !localTemporaryIDs.contains(value.id), ChatConversationTitle.needsTitle(value),
              let transcript = ChatConversationTitle.transcript(value),
              titleRequestedIDs.insert(value.id).inserted else { return }
        let id = value.id
        let request = ChatProviderRequest(provider: provider, apiKey: key, model: model,
                                          system: ChatConversationTitle.prompt,
                                          messages: [ChatProviderMessage(role: "user", text: transcript)],
                                          maxOutputTokens: 128)
        titleTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { titleTasks[id] = nil }
            var text = ""
            do {
                for try await event in providerService.stream(request) {
                    if case let .text(part) = event {
                        text += part
                    }
                }
            } catch {
                return
            }
            guard let title = ChatConversationTitle.clean(text), !deletedLocalIDs.contains(id) else { return }
            var latest = selectedID == id ? conversation : nil
            if latest == nil {
                latest = try? await localStore?.conversation(id: id, owner: Self.localOwner)
            }
            // A rename made meanwhile wins.
            guard var latest, latest.titleSource != "manual" else { return }
            latest.title = title
            latest.titleSource = "auto"
            if selectedID == id {
                conversation = latest
            }
            await storeLocal(latest)
        }
    }
}
