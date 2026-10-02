import Foundation

/// A follow-up typed while its conversation was still working.
struct AskQueuedMessage: Identifiable, Equatable {
    /// Also the message ID once sent, so a retried send stays idempotent.
    let id: String
    var draft: AskDraft
}

/// Follow-ups waiting for a busy conversation, per conversation, plus the ones
/// already handed to the running run ("jumped the queue") until the run reads them.
/// The queue lives on this Mac only and sends in order once the run is done.
struct AskSendQueue: Equatable {
    static let limit = 5

    struct Editing: Equatable {
        var conversationId: String
        var itemId: String
        /// The composer text the user had before opening the queued message.
        var stash: AskDraft
    }

    private(set) var items: [String: [AskQueuedMessage]] = [:]
    private(set) var steered: [String: [AskQueuedMessage]] = [:]
    private(set) var paused: Set<String> = []
    var editing: Editing?
    /// The last run whose end was handled, so a failed run pauses the queue only once.
    private var settledRuns: [String: String] = [:]

    func messages(_ conversationId: String) -> [AskQueuedMessage] { items[conversationId] ?? [] }
    func steeredMessages(_ conversationId: String) -> [AskQueuedMessage] { steered[conversationId] ?? [] }
    func isPaused(_ conversationId: String) -> Bool { paused.contains(conversationId) }
    func canEnqueue(_ conversationId: String) -> Bool { messages(conversationId).count < Self.limit }
    func isEditing(_ conversationId: String, itemId: String) -> Bool {
        editing?.conversationId == conversationId && editing?.itemId == itemId
    }

    @discardableResult
    mutating func enqueue(_ draft: AskDraft, to conversationId: String, id: String = UUID().uuidString) -> AskQueuedMessage? {
        guard draft.canSend, canEnqueue(conversationId) else { return nil }
        let item = AskQueuedMessage(id: id, draft: draft)
        items[conversationId, default: []].append(item)
        return item
    }

    mutating func remove(_ itemId: String, from conversationId: String) {
        items[conversationId]?.removeAll { $0.id == itemId }
        if items[conversationId]?.isEmpty == true { items[conversationId] = nil; paused.remove(conversationId) }
        if editing?.conversationId == conversationId, editing?.itemId == itemId { editing = nil }
    }

    /// An emptied message is removed rather than kept as a blank entry.
    mutating func update(_ itemId: String, in conversationId: String, draft: AskDraft) {
        guard let index = items[conversationId]?.firstIndex(where: { $0.id == itemId }) else { return }
        if draft.canSend { items[conversationId]?[index].draft = draft } else { remove(itemId, from: conversationId) }
    }

    mutating func clear(_ conversationId: String) {
        items[conversationId] = nil
        steered[conversationId] = nil
        paused.remove(conversationId)
        if editing?.conversationId == conversationId { editing = nil }
    }

    mutating func resume(_ conversationId: String) { paused.remove(conversationId) }
    mutating func pause(_ conversationId: String) { paused.insert(conversationId) }

    /// The message to send now: none while paused, or while the first one is being edited.
    func next(for conversationId: String) -> AskQueuedMessage? {
        guard !paused.contains(conversationId), let first = messages(conversationId).first,
              !isEditing(conversationId, itemId: first.id) else { return nil }
        return first
    }

    mutating func take(_ itemId: String, from conversationId: String) -> AskQueuedMessage? {
        guard let item = messages(conversationId).first(where: { $0.id == itemId }) else { return nil }
        items[conversationId]?.removeAll { $0.id == itemId }
        if items[conversationId]?.isEmpty == true { items[conversationId] = nil }
        return item
    }

    /// Puts a message back at the front, e.g. when a jump arrived after the run ended.
    mutating func putFirst(_ item: AskQueuedMessage, in conversationId: String) {
        items[conversationId, default: []].removeAll { $0.id == item.id }
        items[conversationId, default: []].insert(item, at: 0)
    }

    mutating func markSteered(_ item: AskQueuedMessage, in conversationId: String) {
        items[conversationId]?.removeAll { $0.id == item.id }
        if items[conversationId]?.isEmpty == true { items[conversationId] = nil }
        if !steeredMessages(conversationId).contains(where: { $0.id == item.id }) {
            steered[conversationId, default: []].append(item)
        }
    }

    /// Drops jumped messages the conversation now holds. Once the run has ended,
    /// the ones it never read go back to the front of the queue to be sent normally.
    /// A run that failed or was stopped pauses the queue, once per run.
    mutating func reconcile(_ conversationId: String, transcript: [AskMessage], run: AskRun?) {
        let delivered = Set(transcript.map(\.id))
        let waiting = steeredMessages(conversationId).filter { !delivered.contains($0.id) }
        steered[conversationId] = waiting.isEmpty ? nil : waiting
        guard let run, !run.isActive else { return }
        if !waiting.isEmpty {
            steered[conversationId] = nil
            items[conversationId] = waiting + messages(conversationId).filter { item in !waiting.contains { $0.id == item.id } }
        }
        guard settledRuns[conversationId] != run.id else { return }
        settledRuns[conversationId] = run.id
        if ["failed", "cancelled"].contains(run.status), !messages(conversationId).isEmpty {
            paused.insert(conversationId)
        }
    }

    /// Records a run that ended before anything was queued, so it never pauses later items.
    mutating func noteSettled(_ conversationId: String, run: AskRun?) {
        guard let run, !run.isActive else { return }
        settledRuns[conversationId] = run.id
    }
}
