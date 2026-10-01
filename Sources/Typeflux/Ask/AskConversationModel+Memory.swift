import Foundation

/// The memory chip: on and off for a new question, and for each follow-up on
/// the memory pinned to the conversation when it started.
extension AskConversationModel {
    /// Whether the next question goes without memory. A follow-up inherits the
    /// conversation's latest choice until the user flips the chip.
    func memorySwitchedOff(launcher: Bool) -> Bool {
        if launcher { return launcherDraft.memoryOff == true }
        if selectedId == nil { return draft.memoryOff == true }
        return Self.followUpMemoryOff(draft: draft, conversation: selected)
    }

    /// Flips the memory chip. In a follow-up the choice is explicit (true or
    /// false) because nil means "as the conversation was".
    func toggleMemory(launcher: Bool) {
        let off = !memorySwitchedOff(launcher: launcher)
        if launcher {
            launcherDraft.memoryOff = off ? true : nil
        } else if selectedId == nil {
            draft.memoryOff = off ? true : nil
        } else {
            draft.memoryOff = off
        }
    }

    static func followUpMemoryOff(draft: AskDraft, conversation: AskConversation?) -> Bool {
        draft.memoryOff ?? (conversation?.memoryOff == true)
    }

    /// The opening message pins its memory; a follow-up on pinned memory says
    /// whether it goes without it. The local copy mirrors what the server stores.
    static func applyMemoryChoice(_ submitted: AskDraft, newConversation: Bool,
                                  request: inout AskSendRequest, conversation: inout AskConversation) {
        if newConversation {
            conversation.memory = request.memory
        } else if conversation.memory?.isEmpty == false {
            request.memoryOff = followUpMemoryOff(draft: submitted, conversation: conversation) ? true : nil
            conversation.memoryOff = request.memoryOff
        }
    }
}
