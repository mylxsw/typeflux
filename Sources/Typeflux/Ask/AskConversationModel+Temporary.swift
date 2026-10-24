import AppKit

/// The temporary conversation (GUL-370): never listed in history, never reading or
/// writing memory, and kept until explicitly closed or the app quits. `cloud` records where
/// it runs, fixed by its first model: Typeflux Cloud or the engine on this Mac.
struct AskTemporaryConversation: Equatable, Sendable {
    var id: String
    var cloud: Bool
}

/// Where a composer's conversation is kept, as the storage card offers it.
enum AskStorageKind: Equatable, CaseIterable, Sendable {
    case cloud, local, temporary

    var symbol: String {
        switch self {
        case .cloud: "cloud"
        case .local: "lock"
        case .temporary: "hourglass"
        }
    }

    var titleKey: String {
        switch self {
        case .cloud: "ask.storage.cloud"
        case .local: "ask.storage.local"
        case .temporary: "ask.storage.temporary"
        }
    }

    var detailKey: String { titleKey + ".detail" }

    /// Only temporary conversations need a visible storage mark.
    static func marked(_ kind: AskStorageKind, signedIn _: Bool) -> AskStorageKind? {
        switch kind {
        case .temporary: .temporary
        case .local, .cloud: nil
        }
    }
}

extension AskConversationModel {
    /// The selected conversation, or the next one this composer starts, is temporary.
    func isTemporaryComposer(launcher: Bool) -> Bool {
        if launcher { return launcherDraft.temporary == true }
        if let id = selectedId { return isTemporary(id) }
        return draft.temporary == true
    }

    /// Whether the selected conversation is temporary.
    var showsTemporaryConversation: Bool { isTemporary(selectedId) }

    func storageKind(launcher: Bool) -> AskStorageKind {
        if isTemporaryComposer(launcher: launcher) { return .temporary }
        return storesLocally(launcher: launcher) ? .local : .cloud
    }

    /// The storage kind the header and the empty-state orb mark; see `AskStorageKind.marked`.
    func markedStorage(launcher: Bool) -> AskStorageKind? {
        AskStorageKind.marked(storageKind(launcher: launcher), signedIn: isSignedIn)
    }

    /// Only a conversation that has not started can choose; signed out, Cloud is not offered.
    func canChooseStorage(launcher: Bool) -> Bool { launcher || selectedId == nil }

    func chooseStorage(_ kind: AskStorageKind, launcher: Bool) {
        guard canChooseStorage(launcher: launcher) else { return }
        switch kind {
        case .temporary: setTemporary(true, launcher: launcher)
        case .cloud, .local:
            if isSignedIn { setStoresLocally(kind == .local, launcher: launcher) }
            else { setTemporary(false, launcher: launcher) }
        }
    }

    /// Switches the next question between temporary and the default kind. Memory is
    /// dropped from a temporary draft so the composer stops offering it.
    func setTemporary(_ on: Bool, launcher: Bool) {
        guard canChooseStorage(launcher: launcher) else { return }
        if launcher {
            launcherDraft.temporary = on ? true : nil
            if on { launcherDraft.storesLocally = nil }
        } else {
            let wasTemporary = draft.temporary == true
            draft.temporary = on ? true : nil
            if on { draft.storesLocally = nil }
            else if wasTemporary { temporaryDraft = nil }
            draft.memory = on ? AskMemory() : globalMemoryForNewDraft()
        }
        persistDrafts()
    }

    func toggleTemporary(launcher: Bool) {
        setTemporary(!isTemporaryComposer(launcher: launcher), launcher: launcher)
    }

    /// The header and history show this instead of a title: the conversation is never named.
    func displayTitle(for id: String?) -> String? {
        isTemporary(id) ? L("ask.temporary.title") : nil
    }
}

extension AskConversationModel {
    /// "End temporary chat": nothing to confirm, the user asked for exactly this.
    func endTemporaryConversation(id: String? = nil) {
        if id != nil || selectedId != nil {
            discardTemporaryConversation(id: id ?? selectedId)
        } else {
            closeTemporaryDraft()
        }
        confirm(L("ask.temporary.ended"))
    }

    func closeTemporaryDraft() {
        if selectedId == nil, draft.temporary == true { newConversation() }
        temporaryDraft = nil
        temporaryDraftPermissionMode = .standard
    }

    func resumeTemporaryDraft() {
        newConversation(temporary: true)
    }
}
