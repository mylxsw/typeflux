import Foundation
import TypefluxChat

/// The device's copy of Typeflux Cloud: history, conversations, the model catalog
/// and the account card are shown from it at launch and whenever Typeflux cannot
/// be reached. The server stays the source of truth; nothing is queued or replayed.
extension ChatStore {
    nonisolated static let catalogCacheKey = "catalog"
    nonisolated static let profileCacheKey = "profile"
    nonisolated static let creditsCacheKey = "credits"
    nonisolated static let syncedCacheKey = "synced"
    /// Cloud conversations whose full content stays on the device.
    nonisolated static let cachedConversationLimit = 200
    nonisolated static let localOwner = "local"

    /// The signed-in account's partition of the cache.
    var cacheOwner: String? {
        guard isAuthenticated else { return nil }
        let account = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "account:" + (account.isEmpty ? "unknown" : account)
    }

    /// Shown above the conversation and in the sidebar while Typeflux is unreachable.
    var connectivityNotice: String? {
        guard isAuthenticated else { return nil }
        switch connectivity {
        case .online: return nil
        case .serviceUnavailable: return "Typeflux is unavailable. Showing the copy on this iPhone."
        case .offline: return "You're offline. Showing the copy on this iPhone."
        }
    }

    // MARK: Loading and saving the copy

    func loadCachedHome() async {
        guard let owner = cacheOwner, let cache else { return }
        let generation = accountGeneration
        let summaries = (try? await cache.summaries(owner: owner)) ?? []
        let catalog = try? await cache.value([ChatModel].self, key: Self.catalogCacheKey, owner: owner)
        let profile = try? await cache.value(ChatProfile.self, key: Self.profileCacheKey, owner: owner)
        let credits = try? await cache.value(ChatCreditUsage.self, key: Self.creditsCacheKey, owner: owner)
        let synced = try? await cache.value(Date.self, key: Self.syncedCacheKey, owner: owner)
        guard generation == accountGeneration else { return }
        if conversations.isEmpty {
            conversations = summaries.filter { $0.storage == .cloud }.map(\.summary)
        }
        if models.isEmpty, let catalog {
            models = catalog.value
        }
        self.profile = self.profile ?? profile?.value
        creditUsage = creditUsage ?? credits?.value
        cloudSyncedAt = synced?.value
        adoptPreferredModelIfUnset()
        await restoreDraft()
    }

    func cacheHome(_ page: [ChatConversationSummary], catalog: [ChatModel], generation: Int) async {
        guard let owner = cacheOwner, let cache, generation == accountGeneration else { return }
        let now = Date()
        try? await cache.syncCloudPage(page, owner: owner, firstPage: true, complete: page.count < historyPageSize)
        try? await cache.saveValue(catalog, key: Self.catalogCacheKey, owner: owner, at: now)
        try? await cache.saveValue(now, key: Self.syncedCacheKey, owner: owner, at: now)
        try? await cache.prune(owner: owner, keep: Self.cachedConversationLimit)
        if generation == accountGeneration {
            cloudSyncedAt = now
        }
    }

    func cacheValue(_ value: some Encodable & Sendable, key: String) {
        guard let owner = cacheOwner, let cache else { return }
        Task { try? await cache.saveValue(value, key: key, owner: owner) }
    }

    /// Saves settled cloud snapshots; a streaming run is saved once it ends.
    func cacheConversation(_ value: ChatConversation) {
        guard let owner = cacheOwner, let cache, !isLocalConversation(value.id), !temporaryIDs.contains(value.id),
              value.run?.isActive != true, !value.messages.isEmpty else { return }
        Task { try? await cache.save(value, storage: .cloud, owner: owner, modelRef: value.run?.modelRef) }
    }

    /// Shows the cached copy of a cloud conversation while the server is asked for the latest one.
    func showCachedCopy(_ id: String) async {
        guard let owner = cacheOwner, let cache else { return }
        let selection = selectionGeneration
        let stored = try? await cache.conversation(id: id, owner: owner)
        let reference = try? await cache.modelRef(id: id, owner: owner)
        guard selection == selectionGeneration, selectedID == id, conversation == nil, let stored else { return }
        conversation = stored
        restoreModel(reference ?? stored.run?.modelRef)
    }

    // MARK: Connectivity

    func markOnline() {
        connectivity = .online
        if errorMessage == Self.unavailableMessage || errorMessage == Self.offlineMessage {
            errorMessage = nil
        }
    }

    /// Records an outage. Returns true when the error was one, so the caller shows the
    /// device's copy instead of an error.
    @discardableResult
    func noteConnectivity(_ error: Error, generation: Int) -> Bool {
        guard generation == accountGeneration, let issue = ChatConnectivity.classify(error) else { return false }
        connectivity = issue
        return true
    }

    nonisolated static let unavailableMessage =
        "Typeflux is unavailable right now. Your message wasn't sent; your draft is kept."
    nonisolated static let offlineMessage =
        "You're offline. Your message wasn't sent; your draft is kept."

    /// A cloud message failed before Typeflux accepted it. It is never sent again
    /// automatically; the draft stays and a private conversation is offered.
    func noteUnsent(_ issue: ChatConnectivity) {
        connectivity = issue
        errorMessage = issue == .offline ? Self.offlineMessage : Self.unavailableMessage
        offersLocalFallback = !library.models.isEmpty
    }

    /// Called by the path monitor. Regaining a network refreshes what is on screen.
    func networkChanged(available: Bool) async {
        guard isAuthenticated else { return }
        if !available {
            connectivity = .offline
        } else if connectivity != .online {
            await retryConnection()
        }
    }

    func retryConnection() async {
        await refreshHome()
        if connectivity == .online, let id = selectedID, !isLocalConversation(id),
           conversation != nil || requiresConversationSnapshot {
            await reloadConversation(reportFailure: false)
        }
    }

    // MARK: Clearing

    /// Removes the signed-in account's copy and drafts (sign-out and account deletion).
    func forgetAccountData() async {
        guard let owner = cacheOwner else { return }
        try? await cache?.deleteAll(owner: owner)
        try? await localStore?.deleteAll(owner: owner)
    }

    /// Settings → Storage. Private conversations and drafts are not affected.
    func clearCloudCopies() async {
        guard let owner = cacheOwner else { return }
        try? await cache?.deleteAll(owner: owner)
        cloudSyncedAt = nil
    }

    func cachedContentSize() async -> Int {
        guard let owner = cacheOwner else { return 0 }
        return (try? await cache?.contentSize(owner: owner)) ?? 0
    }

    // MARK: Drafts

    /// Drafts of a conversation that has not started are kept under one key.
    nonisolated static let newDraftKey = "new"

    var draftOwner: String { cacheOwner ?? Self.localOwner }

    var draftKey: String {
        guard let id = selectedID else { return Self.newDraftKey }
        let started = conversation?.messages.isEmpty == false || conversations.contains { $0.id == id } ||
            localConversations.contains { $0.id == id }
        return started ? id : Self.newDraftKey
    }

    func saveDraft() async {
        guard !isTemporary else { return }
        try? await localStore?.saveDraft(ChatDraft(text: draft, image: imageDataURL), id: draftKey, owner: draftOwner)
    }

    func saveDraftInBackground() {
        // Temporary conversations leave nothing behind, drafts included.
        guard let localStore, !isTemporary else { return }
        let value = ChatDraft(text: draft, image: imageDataURL), key = draftKey, owner = draftOwner
        Task { try? await localStore.saveDraft(value, id: key, owner: owner) }
    }

    /// The new-conversation draft was sent; it must not come back.
    func discardNewDraft() {
        guard let localStore else { return }
        let owner = draftOwner
        Task { try? await localStore.saveDraft(nil, id: Self.newDraftKey, owner: owner) }
    }

    /// Restores the selected conversation's draft unless the user has already typed.
    func restoreDraft() async {
        let selection = selectionGeneration, key = draftKey
        guard let saved = try? await localStore?.draft(id: key, owner: draftOwner),
              selection == selectionGeneration, key == draftKey,
              draft.isEmpty, imageDataURL == nil else { return }
        draft = saved.text
        imageDataURL = saved.image
    }
}
