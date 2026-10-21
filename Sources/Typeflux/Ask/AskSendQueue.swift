import Foundation

/// A follow-up typed while its conversation was still working.
struct AskQueuedMessage: Identifiable, Equatable {
    /// Also the message ID once sent, so a retried send stays idempotent.
    let id: String
    var draft: AskDraft
    var revision = UUID()
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

    /// Reservations outlive removal of local intent until the request is reconciled.
    struct Claim: Equatable {
        let attempt = UUID()
        let epoch: UUID
        let item: AskQueuedMessage
        let originalRunID: String?
    }
    private var epochs: [String: UUID] = [:]
    private var claims: [String: [String: Claim]] = [:]
    private var discarded: Set<UUID> = []
    private var supplementRuns: [String: [String: String]] = [:]
    private(set) var items: [String: [AskQueuedMessage]] = [:]
    private(set) var steered: [String: [AskQueuedMessage]] = [:]
    private(set) var paused: Set<String> = []
    var editing: Editing?
    /// The last run whose end was handled, so a failed run pauses the queue only once.
    private var settledRuns: [String: String] = [:]

    func messages(_ conversationId: String) -> [AskQueuedMessage] { items[conversationId] ?? [] }
    func steeredMessages(_ conversationId: String) -> [AskQueuedMessage] { steered[conversationId] ?? [] }
    func isPaused(_ conversationId: String) -> Bool { paused.contains(conversationId) }
    func canEnqueue(_ conversationId: String) -> Bool { Set(messages(conversationId).map(\.id)).union(claims[conversationId]?.keys.map { $0 } ?? []).count < Self.limit }
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
        if let claim = claims[conversationId]?[itemId] { discarded.insert(claim.attempt) }
        items[conversationId]?.removeAll { $0.id == itemId }
        supplementRuns[conversationId]?[itemId] = nil
        if items[conversationId]?.isEmpty == true { items[conversationId] = nil; paused.remove(conversationId) }
        if editing?.conversationId == conversationId, editing?.itemId == itemId { editing = nil }
    }

    /// An emptied message is removed rather than kept as a blank entry.
    mutating func update(_ itemId: String, in conversationId: String, draft: AskDraft) {
        guard claims[conversationId]?[itemId] == nil else { return }
        guard let index = items[conversationId]?.firstIndex(where: { $0.id == itemId }) else { return }
        if draft.canSend { items[conversationId]?[index].draft = draft; items[conversationId]?[index].revision = UUID() } else { remove(itemId, from: conversationId) }
    }

    mutating func clear(_ conversationId: String) {
        epochs[conversationId] = UUID()
        for claim in claims[conversationId]?.values.map({ $0 }) ?? [] { discarded.insert(claim.attempt) }
        supplementRuns[conversationId] = nil
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

    mutating func markSteered(_ item: AskQueuedMessage, in conversationId: String, runID: String? = nil) {
        if let runID { supplementRuns[conversationId, default: [:]][item.id] = runID }
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
        let delivered = Set(transcript.filter { message in
            guard let original = supplementRuns[conversationId]?[message.id] else { return true }
            return message.runId == original
        }.map(\.id))
        items[conversationId]?.removeAll { delivered.contains($0.id) }
        for id in delivered { supplementRuns[conversationId]?[id] = nil }
        let waiting = steeredMessages(conversationId).filter { !delivered.contains($0.id) }
        steered[conversationId] = waiting.isEmpty ? nil : waiting
        guard let run, ["completed", "failed", "cancelled"].contains(run.status), !run.needsRecoveryInspection else { return }
        let restored = waiting.filter { supplementRuns[conversationId]?[$0.id] == nil || supplementRuns[conversationId]?[$0.id] == run.id }
        if !restored.isEmpty {
            for item in restored { supplementRuns[conversationId]?[item.id] = nil }
            steered[conversationId] = waiting.filter { item in !restored.contains { $0.id == item.id } }
            items[conversationId] = restored + messages(conversationId).filter { item in !restored.contains { $0.id == item.id } }
            if ["failed", "cancelled"].contains(run.status) { paused.insert(conversationId) }
        }
        guard settledRuns[conversationId] != run.id else { return }
        settledRuns[conversationId] = run.id
        if ["failed", "cancelled"].contains(run.status), !messages(conversationId).isEmpty {
            paused.insert(conversationId)
        }
    }

    /// Records a run that ended before anything was queued, so it never pauses later items.
    mutating func noteSettled(_ conversationId: String, run: AskRun?) {
        guard let run, ["completed", "failed", "cancelled"].contains(run.status), !run.needsRecoveryInspection else { return }
        settledRuns[conversationId] = run.id
    }

    mutating func claim(_ itemID: String, in conversationID: String, runID: String? = nil) -> Claim? {
        guard claims[conversationID]?[itemID] == nil,
              let item = messages(conversationID).first(where: { $0.id == itemID }) else { return nil }
        let epoch = epochs[conversationID] ?? UUID()
        epochs[conversationID] = epoch
        let claim = Claim(epoch: epoch, item: item, originalRunID: runID)
        claims[conversationID, default: [:]][itemID] = claim
        return claim
    }

    func owns(_ claim: Claim, in conversationID: String) -> Bool {
        claims[conversationID]?[claim.item.id] == claim && epochs[conversationID] == claim.epoch
            && !discarded.contains(claim.attempt)
    }

    /// A matching attempt alone can release a reservation; a late defer cannot release its replacement.
    mutating func release(_ claim: Claim, in conversationID: String) {
        guard claims[conversationID]?[claim.item.id]?.attempt == claim.attempt else { return }
        claims[conversationID]?[claim.item.id] = nil
        discarded.remove(claim.attempt)
    }

    mutating func restore(_ claim: Claim, in conversationID: String) {
        guard owns(claim, in: conversationID) else { return }
        putFirst(claim.item, in: conversationID)
        pause(conversationID)
    }
}

/// Shared policy for automatic advancement and the explicit queue action.
enum AskQueueDisposition: Equatable {
    enum Block: Equatable { case recovery, approval, credits, otherDevice, active, flight, paused }
    case blocked(Block), ready, empty

    static func resolve(run: AskRun?, recoveryBlocked: Bool, submitting: Bool, steering: Bool,
                        pendingApproval: Bool, deviceID: String, paused: Bool, hasItems: Bool) -> Self {
        guard hasItems else { return .empty }
        if recoveryBlocked || run?.needsRecoveryInspection == true
            || run.map({ $0.id.isEmpty || $0.deviceId.isEmpty }) == true { return .blocked(.recovery) }
        if pendingApproval { return .blocked(.approval) }
        if run?.isPausedForCredits == true { return .blocked(.credits) }
        if let run, ["waiting_tool", "waiting_inference"].contains(run.status), run.deviceId != deviceID {
            return .blocked(.otherDevice)
        }
        if submitting || steering { return .blocked(.flight) }
        if run?.isActive == true { return .blocked(.active) }
        if paused { return .blocked(.paused) }
        return .ready
    }
}
