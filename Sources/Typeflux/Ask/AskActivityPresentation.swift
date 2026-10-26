import Foundation
import SwiftUI

/// A stable result row for a user turn, including interrupted or resumed work.
struct AskTaskOutcome: Equatable {
    var id: String
    var messageIDs: [String]
    var runIDs: [String]
    var changes: [AskWorkspaceFileChange]
}

/// View-local preparation. Completed tool receipts are decoded only when their evidence changes.
/// This cache is deliberately not observable: reading it must not schedule another view update.
final class AskActivityOutputCache {
    private struct Entry {
        var call: AskToolCall
        var result: AskMessage?
        var outputs: AskRunOutputs
    }
    private var entries: [String: Entry] = [:]
    private var conversationID: String?
    private var inputRevision: UInt64?

    /// The caller owns the revision and advances it whenever any transcript input changes.
    /// Autoclosures keep filtering and full-array comparisons out of unchanged view passes.
    func prepare(conversationID: String?, revision: UInt64, messages: @autoclosure () -> [AskMessage],
                 results: @autoclosure () -> [AskMessage], changes: [String: [AskWorkspaceFileChange]]) -> [AskTranscriptItem] {
        if self.conversationID == conversationID, inputRevision == revision { return prepared }
        let value = prepare(conversationID: conversationID, messages: messages(), results: results(), changes: changes)
        inputRevision = revision
        return value
    }
    private var messages: [AskMessage] = []
    private var results: [AskMessage] = []
    private var changes: [String: [AskWorkspaceFileChange]] = [:]
    private var prepared: [AskTranscriptItem] = []
    private var committedMessageIDs: Set<String> = []
    private var liveMessage: AskMessage?
    private var livePrepared: [AskTranscriptItem] = []

    /// Stream deltas have no receipts yet. Reuse historical rows and outcomes, updating
    /// only the trailing message/activity instead of regrouping and decoding history.
    func appendingProgress(_ message: AskMessage?) -> [AskTranscriptItem] {
        guard let message, !committedMessageIDs.contains(message.id) else { return prepared }
        if liveMessage == message { return livePrepared }
        liveMessage = message
        if message.role != "assistant" || changes[message.id] != nil
            || (message.toolCalls ?? []).contains(where: { resultsByID[$0.id] != nil }) {
            livePrepared = AskActivity.items(messages + [message], results: results, fileChanges: changes, cache: self)
            return livePrepared
        }
        var rows = prepared
        var outcome: AskTranscriptItem?
        if let last = rows.last, case .outcome = last.kind { outcome = rows.removeLast() }
        if !(message.toolCalls ?? []).isEmpty {
            var activity = message
            if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var note = message
                note.toolCalls = nil; note.reasoning = nil; note.reasoningMilliseconds = nil
                rows.append(.init(kind: .message(note), isProgress: true))
                activity.text = ""
            }
            if let last = rows.last, case var .activity(group) = last.kind {
                group.messages.append(activity)
                rows[rows.count - 1] = .init(kind: .activity(group))
            } else {
                rows.append(.init(kind: .activity(.init(id: message.id, messages: [activity]))))
            }
        } else { rows.append(.init(kind: .message(message))) }
        if var outcome, case var .outcome(task) = outcome.kind {
            task.messageIDs.append(message.id)
            if let runID = message.runId, !task.runIDs.contains(runID) { task.runIDs.append(runID); task.runIDs.sort() }
            outcome.kind = .outcome(task)
            rows.append(outcome)
        }
        livePrepared = rows
        return rows
    }
    private(set) var decodeCount = 0
    private(set) var preparationCount = 0
    private(set) var resultsByID: [String: AskMessage] = [:]

    func prepare(conversationID: String?, messages: [AskMessage], results: [AskMessage],
                 changes: [String: [AskWorkspaceFileChange]]) -> [AskTranscriptItem] {
        inputRevision = nil
        if self.conversationID != conversationID {
            entries = [:]
            self.messages = []
            self.results = []
            self.changes = [:]
            prepared = []
            committedMessageIDs = []; liveMessage = nil; livePrepared = []
            resultsByID = [:]
            self.conversationID = conversationID
        }
        guard self.messages != messages || self.results != results || self.changes != changes else { return prepared }
        liveMessage = nil; livePrepared = []
        committedMessageIDs = Set(messages.map(\.id))
        self.messages = messages
        self.results = results
        self.changes = changes
        resultsByID = AskActivity.resultIndex(results)
        preparationCount += 1
        prepared = AskActivity.items(messages, results: results, fileChanges: changes, cache: self)
        return prepared
    }

    func retain(messages: [AskMessage]) {
        let ids = Set(messages.flatMap { $0.toolCalls ?? [] }.map(\.id))
        entries = entries.filter { ids.contains($0.key) }
    }

    func outputs(_ group: AskActivityGroup, results: [String: AskMessage]) -> AskRunOutputs {
        var combined = AskRunOutputs()
        var images = Set<String>(), artifacts = Set<String>(), generated = Set<String>(), sources = Set<URL>()
        for message in group.messages {
            for call in message.toolCalls ?? [] {
                let result = results[call.id]
                let value: AskRunOutputs
                if let entry = entries[call.id], entry.call == call, entry.result == result {
                    value = entry.outputs
                } else {
                    var single = message
                    single.toolCalls = [call]
                    value = AskActivity.outputs(.init(id: message.id, messages: [single]), resultIndex: results)
                    entries[call.id] = Entry(call: call, result: result, outputs: value)
                    decodeCount += 1
                }
                combined.artifacts += value.artifacts.filter { images.insert($0.id).inserted }
                combined.storedArtifacts += value.storedArtifacts.filter { artifacts.insert($0.id).inserted }
                combined.generatedImages += value.generatedImages.filter { generated.insert($0.assetId).inserted }
                combined.sources += value.sources.filter { sources.insert($0).inserted }
                combined.storedArtifactNames.merge(value.storedArtifactNames, uniquingKeysWith: { _, new in new })
            }
        }
        return combined
    }
}

/// A page bounds both the number of mounted views and the amount of selectable text.
/// Page indices stay fixed while the agent appends more steps; only an explicit Latest follows it.
struct AskActivityPage {
    static let size = 20
    static func range(count: Int, page: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let start = min(max(0, page), (count - 1) / size) * size
        return start..<min(count, start + size)
    }
    static func last(count: Int) -> Int { max(0, count - 1) / size }
}

struct AskActivityDetail: Identifiable {
    enum Kind {
        case reasoning(String)
        case note(String)
        case tool(AskToolCall, messageID: String)
    }
    var id: String
    var kind: Kind

    static func rows(_ messages: [AskMessage]) -> [Self] {
        messages.flatMap { message -> [Self] in
            var rows: [Self] = []
            if let reasoning = message.reasoning, !reasoning.isEmpty {
                rows.append(.init(id: message.id + "/reasoning", kind: .reasoning(reasoning)))
            }
            if !message.text.isEmpty { rows.append(.init(id: message.id + "/note", kind: .note(message.text))) }
            rows += (message.toolCalls ?? []).filter {
                !["update_plan", AskInternalRecovery.toolName].contains($0.function.name)
            }.map { .init(id: $0.id, kind: .tool($0, messageID: message.id)) }
            return rows
        }
    }
}

/// Comparable actions avoid invalidating every historical row when the parent updates.
struct AskTranscriptInspectionAction: Equatable {
    var identity: UUID?
    var action: () -> Void = {}
    func callAsFunction() { action() }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }
}

extension EnvironmentValues {
    /// Inspecting a historical detail explicitly leaves automatic bottom-following mode.
    @Entry var askInspectTranscript = AskTranscriptInspectionAction()
}
