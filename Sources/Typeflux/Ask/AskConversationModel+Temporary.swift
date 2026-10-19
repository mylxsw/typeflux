import AppKit

/// The temporary conversation (GUL-370): never listed in history, never reading or
/// writing memory, and gone once the user leaves it or quits. `cloud` records where
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

    /// The kind the window marks in colour, or nil when nothing needs telling apart:
    /// Cloud is the quiet default, and signed out every conversation is on this Mac.
    static func marked(_ kind: AskStorageKind, signedIn: Bool) -> AskStorageKind? {
        switch kind {
        case .temporary: .temporary
        case .local: signedIn ? .local : nil
        case .cloud: nil
        }
    }
}

/// What the user chose when leaving a temporary conversation that has messages.
struct AskTemporaryLeaveDecision: Equatable, Sendable {
    enum Choice: Equatable, Sendable { case end, keep, cancel }

    var choice: Choice
    /// "Don't ask again" was checked.
    var suppress = false
}

enum AskTemporaryLeaveConfirmation {
    /// Button order: End is the default, Keep saves it first, Cancel stays.
    @MainActor static func confirm() -> AskTemporaryLeaveDecision {
        let alert = NSAlert()
        alert.messageText = L("ask.temporary.leave.title")
        alert.informativeText = L("ask.temporary.leave.body")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("ask.temporary.end"))
        alert.addButton(withTitle: L("ask.temporary.keep"))
        alert.addButton(withTitle: L("common.cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L("ask.temporary.leave.dontAsk")
        let response = alert.runModal()
        return decision(for: response, suppress: alert.suppressionButton?.state == .on)
    }

    /// Cancelling never stores "don't ask again": nothing was decided.
    static func decision(for response: NSApplication.ModalResponse, suppress: Bool) -> AskTemporaryLeaveDecision {
        switch response {
        case .alertFirstButtonReturn: .init(choice: .end, suppress: suppress)
        case .alertSecondButtonReturn: .init(choice: .keep, suppress: suppress)
        default: .init(choice: .cancel)
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

    /// The temporary conversation is the one on screen, so leaving it ends it.
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
            draft.temporary = on ? true : nil
            if on { draft.storesLocally = nil }
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
    func endTemporaryConversation() {
        discardTemporaryConversation()
        confirm(L("ask.temporary.ended"))
    }
}
