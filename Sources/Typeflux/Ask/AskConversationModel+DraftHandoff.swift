import Foundation

/// A durable copy of an unsent handoff, never an execution request or approval.
struct AskDraftHandoff: Equatable, Sendable {
    let id: String
    let owner: String
    let draft: AskDraft
}

struct AskDraftHandoffSubmission: Sendable {
    let key: String
    let owner: String
    let messageID: String
}

struct AskChatDraftWrite {
    let id = UUID()
    let task: Task<Void, Error>
}

extension AskConversationModel {
    /// Preserve write order for each recovery copy across debounce and navigation.
    /// A cancelled caller still waits for its in-flight storage call before a
    /// newer write can begin. Other drafts/accounts have independent chains.
    func saveChatDraft(_ value: AskDraft, key: String, account: String) async throws {
        let previous = chatDraftWrites[account]?[key]?.task
        let write = AskChatDraftWrite(task: Task { [cache] in
            _ = try? await previous?.value
            try Task.checkCancellation()
            try await cache.saveDraft(value, key: key, owner: account)
        })
        chatDraftWrites[account, default: [:]][key] = write
        defer {
            if chatDraftWrites[account]?[key]?.id == write.id {
                chatDraftWrites[account]?[key] = nil
                if chatDraftWrites[account]?.isEmpty == true { chatDraftWrites[account] = nil }
            }
        }
        try await withTaskCancellationHandler {
            try await write.task.value
        } onCancel: {
            write.task.cancel()
        }
    }

    /// Stage before clearing the source editor. Reuse the same identity after an
    /// uncertain storage response; retrying cannot create another recovery copy.
    func reserveChatDraft(_ incoming: AskDraft, account: String) -> AskDraftHandoff {
        if let pending = pendingDraftHandoff, pending.owner == account, pending.draft == incoming { return pending }
        let handoff = AskDraftHandoff(id: "saved-chat:handoff:" + UUID().uuidString, owner: account, draft: incoming)
        pendingDraftHandoff = handoff
        return handoff
    }

    func stageChatDraft(_ incoming: AskDraft, account: String) async throws -> String? {
        guard incoming.temporary != true else { return nil }
        let handoff = reserveChatDraft(incoming, account: account)
        try await saveChatDraft(incoming, key: handoff.id, account: account)
        try Task.checkCancellation()
        // A discarding/unavailable cache cannot acknowledge a durable handoff.
        guard let saved = try await cache.draft(key: handoff.id, owner: account) else { throw AskRecoveryError.storage }
        let matches = try await Task.detached(priority: .utility) {
            let encoder = AskCoding.encoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(saved) == encoder.encode(incoming)
        }.value
        guard matches else { throw AskRecoveryError.storage }
        try Task.checkCancellation()
        return handoff.id
    }

    func displacedChatDraft(_ value: AskDraft, handoffID: String? = nil) -> AskSavedChatDraft {
        let key = activeChatDraftID ?? handoffID.map { "saved-chat:displaced:" + $0 } ?? "saved-chat:" + UUID().uuidString
        return .init(id: key, draft: value)
    }

    /// Navigation releases presentation ownership, not the durable recovery copy.
    /// A late write cannot resurrect a consumed copy because delete installs a tombstone.
    func detachChatDraft() {
        guard let key = activeChatDraftID else { return }
        activeChatDraftID = nil
        let value = draft, account = owner
        Task { [self] in
            do {
                if value.temporary == true { try await cache.delete(id: key, owner: account) }
                else { try await saveChatDraft(value, key: key, account: account) }
            } catch {
                if owner == account { self.error = L("ask.cache.failed") }
            }
        }
    }

    /// Only an authenticated response containing this exact submitted message
    /// consumes its backup. A timeout, cancellation or failed send keeps it.
    func acknowledgeChatDraft(_ response: AskConversation, route: AskRoute) async {
        guard let pending = chatDraftSubmissions[response.id], pending.owner == route.account,
              response.run != nil, response.messages.contains(where: { $0.id == pending.messageID && $0.role == "user" })
        else { return }
        do {
            // Commit the destination before deleting the source recovery copy.
            try await cache.save(response, owner: route.owner)
            try await cache.delete(id: pending.key, owner: pending.owner)
            if chatDraftSubmissions[response.id]?.key == pending.key { chatDraftSubmissions[response.id] = nil }
        } catch {
            // A cleanup failure leaves an explicit unsent recovery copy. It must
            // not block an already admitted run or cause an automatic resend.
            ErrorLogStore.shared.log("Ask draft handoff acknowledgment could not be saved")
        }
    }
}
