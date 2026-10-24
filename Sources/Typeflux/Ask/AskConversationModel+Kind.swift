import Foundation

extension AskConversationModel {
    func toggleConversationKind(launcher: Bool) {
        chooseConversationKind(conversationKind(launcher: launcher) == .chat ? .work : .chat, launcher: launcher)
    }

    static let lastConversationKindKey = "ask.lastConversationKind"

    /// The kind a new conversation starts as when its draft has not chosen: the last one
    /// the user started, chat at first.
    var lastConversationKind: AskConversationKind {
        get {
            modelLibrary.settings.defaults.string(forKey: Self.lastConversationKindKey)
                .map(AskConversationKind.init(stored:)) ?? .chat
        }
        set { modelLibrary.settings.defaults.set(newValue.rawValue, forKey: Self.lastConversationKindKey) }
    }

    func conversationKind(of draft: AskDraft) -> AskConversationKind {
        draft.kind.map(AskConversationKind.init(stored:)) ?? lastConversationKind
    }

    /// The open conversation's fixed kind, or what the composer's new conversation will be.
    func conversationKind(launcher: Bool) -> AskConversationKind {
        if !launcher, let id = selectedId {
            if let selected, selected.id == id { return selected.resolvedKind }
            return conversations.first { $0.id == id }?.resolvedKind ?? .chat
        }
        return conversationKind(of: launcher ? launcherDraft : draft)
    }

    /// Only a conversation that has not started can still choose its kind.
    func canChangeConversationKind(launcher: Bool) -> Bool { launcher || selectedId == nil }

    /// Switching to chat drops folders from the draft: a chat cannot work in them.
    func setConversationKind(_ kind: AskConversationKind, launcher: Bool) {
        guard canChangeConversationKind(launcher: launcher), conversationKind(launcher: launcher) != kind else { return }
        var current = launcher ? launcherDraft : draft
        current.kind = kind.rawValue
        if kind == .chat, current.attachments?.contains(where: { $0.kind == .folder }) == true {
            current.attachments?.removeAll { $0.kind == .folder }
            if current.attachments?.isEmpty == true { current.attachments = nil }
            if launcher { launcherAttachmentNotice = L("ask.kind.foldersRemoved") }
            else { attachmentNotice = L("ask.kind.foldersRemoved") }
        }
        if launcher { launcherDraft = current } else { draft = current }
        persistDrafts()
    }

    /// A folder is something to work in, so a chat cannot take one. A conversation that
    /// has not started becomes work; a started chat keeps the other items and says why.
    /// Returns the batch to add and the notice to show, if any.
    func admitFolders(_ batch: AskAttachmentBatch, launcher: Bool) -> (AskAttachmentBatch, String?) {
        guard batch.items.contains(where: { $0.kind == .folder }), conversationKind(launcher: launcher) == .chat else {
            return (batch, nil)
        }
        if canChangeConversationKind(launcher: launcher) {
            setConversationKind(.work, launcher: launcher)
            return (batch, L("ask.kind.switchedToWork"))
        }
        var kept = batch
        kept.items.removeAll { $0.kind == .folder }
        return (kept, L("ask.kind.chatFolderRefused"))
    }
}

extension AskConversationModel {
    /// The name of the other device that runs the open conversation, or nil when this
    /// Mac or Typeflux Cloud runs it. Such a conversation is read-only here.
    var selectedHostElsewhere: String? {
        guard let id = selectedId else { return nil }
        let host = selected?.id == id ? (selected?.hostDeviceId, selected?.hostDeviceName)
            : conversations.first { $0.id == id }.map { ($0.hostDeviceId, $0.hostDeviceName) } ?? (nil, nil)
        return Self.hostElsewhere(id: host.0, name: host.1, thisDevice: deviceId)
    }

    func hostElsewhere(_ summary: AskConversationSummary) -> String? {
        Self.hostElsewhere(id: summary.hostDeviceId, name: summary.hostDeviceName, thisDevice: deviceId)
    }

    nonisolated static func hostElsewhere(id: String?, name: String?, thisDevice: String) -> String? {
        guard let id, !id.isEmpty, id.caseInsensitiveCompare(thisDevice) != .orderedSame else { return nil }
        return name.flatMap { $0.isEmpty ? nil : $0 } ?? L("ask.host.anotherMac")
    }
}

extension AskConversationModel {
    /// `/chat` and `/work`: a new conversation switches; a started one of the other kind
    /// carries on in a new conversation of the chosen kind, leaving itself unchanged.
    func chooseConversationKind(_ kind: AskConversationKind, launcher: Bool) {
        if canChangeConversationKind(launcher: launcher) {
            setConversationKind(kind, launcher: launcher)
            confirm(L("ask.kind.switched", L(kind.titleKey)))
        } else if conversationKind(launcher: launcher) != kind {
            continueInNew(kind)
        }
    }

    /// Starts a new conversation of `kind` carrying the open conversation's transcript
    /// as a reference, kept where the source is kept (this Mac or Typeflux Cloud).
    /// "Continue as work" from a chat and "new chat" from another device's task use it.
    func continueInNew(_ kind: AskConversationKind) {
        guard let source = selected else { return }
        let reference = AskReference(conversation: source)
        let keepsLocally = isSignedIn && isLocal(source.id) && !isTemporary(source.id)
        guard newConversation(storesLocally: keepsLocally ? true : nil) else { return }
        setConversationKind(kind, launcher: false)
        draft.includeScreenshot = false
        draft.references = [reference]
        persistDrafts()
        confirm(L(kind == .work ? "ask.kind.continuedAsWork" : "ask.kind.continuedAsChat"))
    }

    func continueInNewChat() { continueInNew(.chat) }
}

extension AskConversationModel {
    func confirmUploadSelected() {
        guard canUploadSelected, uploadConfirmation() else { return }
        Task { await uploadSelected() }
    }
}
