import Foundation

struct FeatureChatHandoff: Codable, Sendable {
    let id: String
    let owner: String
    var generation: Int = 0
    let draft: AskDraft
    let permission: String
    let reasoning: String
    let submit: Bool
    var conversationID: String?
}

extension AskConversationModel {
    /// The source remains intact until the destination has accepted the complete
    /// draft. A lost acknowledgement never causes an automatic second submit.
    func transferFeatureDraft(_ incoming: AskDraft, submit: Bool, clearingLauncher: Bool = true) async -> Bool {
        guard canOpenChatFromLauncher, let account = session()?.owner else { return false }
        _ = credentials()
        let source = launcherDraft
        let handoff = reserveChatDraft(incoming, account: account)
        let transfer = FeatureChatHandoff(id: handoff.id, owner: account, generation: AuthState.shared.sessionGeneration, draft: incoming,
            permission: launcherPermissionMode.rawValue, reasoning: reasoningEffort.rawValue, submit: submit)
        isOpeningChat = true
        defer { isOpeningChat = false }
        do {
            _ = try await stageChatDraft(incoming, account: account)
            guard !Task.isCancelled, session()?.owner == account, AuthState.shared.sessionGeneration == transfer.generation, !clearingLauncher || launcherDraft == source else { return false }
            let result = try await featureRoute(.init(destination: .chat, action: "handoff", payload: JSONEncoder().encode(transfer)))
            guard try JSONDecoder().decode(Bool.self, from: result) else { return false }
            guard session()?.owner == account, AuthState.shared.sessionGeneration == transfer.generation else { return false }
            if clearingLauncher, launcherDraft == source {
                if submit, incoming.temporary != true { recordLauncherInput(destination: .askAI) }
                pendingDraftHandoff = nil
                launcherDraft = newQuestionDraft()
                launcherPermissionMode = .standard
                plugins.deactivate()
                clearCapturedContentFeedback(launcher: true)
                persistDrafts()
                FeatureProcess.send(.init(destination: .launcher, action: "hideLauncher"))
            }
            return true
        } catch {
            confirm(L("ask.cache.failed"))
            return false
        }
    }

    func openFeatureChat(incomingDraft: AskDraft? = nil) async -> Bool {
        guard !Task.isCancelled, canOpenChatFromLauncher else { confirm(L("ask.openChat.wait")); return false }
        if incomingDraft == nil, plugins.keyword?.pluginID == AskQuickAskPlugin.id, quickAsk?.conversationId != nil {
            return await openQuickAskInChat()
        }
        var incoming = incomingDraft ?? launcherDraft
        var otherPlugin = incomingDraft == nil && (plugins.keyword.map { $0.pluginID != AskOpenChatPlugin.id && $0.pluginID != AskQuickAskPlugin.id } ?? false)
        if incomingDraft == nil, plugins.keyword == nil {
            switch AskKeywordMatcher.match(incoming.text, keywords: launcherKeywords) {
            case let .hint(keyword) where keyword.pluginID == AskOpenChatPlugin.id: incoming.text = ""
            case let .active(keyword, argument) where keyword.pluginID == AskOpenChatPlugin.id: incoming.text = argument
            case .active: otherPlugin = true
            default: break
            }
        }
        if otherPlugin || !incoming.hasChatInput {
            let source = launcherDraft, keyword = plugins.keyword
            let account = session()?.owner, generation = AuthState.shared.sessionGeneration
            isOpeningChat = true
            defer { isOpeningChat = false }
            do {
                _ = try await featureRoute(.init(destination: .chat, action: "showChat"))
                guard !Task.isCancelled, session()?.owner == account,
                      AuthState.shared.sessionGeneration == generation else { return false }
                if launcherDraft == source, plugins.keyword == keyword {
                    captureGeneration = UUID()
                    if !otherPlugin {
                        plugins.deactivate()
                        launcherDraft.text = ""
                    }
                    persistDrafts()
                    // The chat process cannot dismiss the source process's panel.
                    onDismissLauncher?()
                }
                return true
            }
            catch { confirm(L("ask.cache.failed")); return false }
        }
        return await transferFeatureDraft(incoming, submit: false)
    }

    func receiveFeatureHandoff(_ handoff: FeatureChatHandoff) async -> Bool {
        guard FeatureProcess.owns(.chat), session()?.owner == handoff.owner, AuthState.shared.sessionGeneration == handoff.generation else { return false }
        if acceptedFeatureHandoffs.contains(handoff.id) { onShowConversation?(); return true }
        guard acceptedFeatureHandoffs.count < 4096, !isOpeningChat else { return false }
        if let id = handoff.conversationID {
            isOpeningChat = true
            defer { isOpeningChat = false }
            externallyDrivenConversations.insert(id)
            onShowConversation?()
            await select(id)
            guard selectedId == id, !selectionLoadFailed else { return false }
        } else {
            launcherDraft = handoff.draft
            launcherPermissionMode = AskPermissionMode(rawValue: handoff.permission) ?? .standard
            reasoningEffort = AskReasoningEffort(rawValue: handoff.reasoning) ?? .providerDefault
            pendingDraftHandoff = .init(id: handoff.id, owner: handoff.owner, draft: handoff.draft)
            guard await openChatFromLauncher() else { return false }
        }
        guard session()?.owner == handoff.owner, AuthState.shared.sessionGeneration == handoff.generation else { return false }
        // A rejected submit keeps the source intact and may be retried explicitly.
        if handoff.submit, !submitDraft() { return false }
        acceptedFeatureHandoffs.insert(handoff.id)
        return true
    }

    func transferFeatureQuickAsk() async -> Bool {
        guard canOpenChatFromLauncher, let quick = quickAsk, quick.persisted,
              let id = quick.conversationId, let account = session()?.owner, quick.owner == account else { return false }
        let transfer = FeatureChatHandoff(id: "quick:" + quick.generation.uuidString, owner: account, generation: AuthState.shared.sessionGeneration,
            draft: .followUp, permission: AskPermissionMode.standard.rawValue,
            reasoning: reasoningEffort.rawValue, submit: false, conversationID: id)
        isOpeningChat = true
        defer { isOpeningChat = false }
        do {
            let data = try await featureRoute(.init(destination: .chat, action: "handoff", payload: JSONEncoder().encode(transfer)))
            guard try JSONDecoder().decode(Bool.self, from: data), session()?.owner == account,
                  AuthState.shared.sessionGeneration == transfer.generation, quickAsk?.generation == quick.generation else { return false }
            quickAsk?.handedOff = true
            launcherDraft = newQuestionDraft()
            plugins.deactivate()
            persistDrafts()
            FeatureProcess.send(.init(destination: .launcher, action: "hideLauncher"))
            return true
        } catch { confirm(L("ask.cache.failed")); return false }
    }
}
