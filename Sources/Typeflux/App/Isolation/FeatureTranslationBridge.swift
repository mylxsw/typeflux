import Foundation

/// Only presentation values cross the channel. An in-flight provider call keeps
/// one owner, and moving its output never starts another billable request.
struct FeatureTranslationOutput: Codable, Sendable {
    let body: String
    let original: String
    let source: String
    let sourceIsAI: Bool
    let note: String?
    let translation: AskTranslationStack?
    let wordCard: AskWordCard?
    let wordBook: AskWordBookLookup?
    let starred: Bool?

    init(_ output: AskPluginOutput) {
        body = output.body; original = output.original; source = output.source
        sourceIsAI = output.sourceIsAI; note = output.note; translation = output.translation
        wordCard = output.wordCard; wordBook = output.wordBook; starred = output.starred
    }
    var output: AskPluginOutput {
        var value = AskPluginOutput(body: body, original: original, meta: [], source: source, actions: [],
                                    wordCard: wordCard, translation: translation)
        value.sourceIsAI = sourceIsAI; value.note = note; value.wordBook = wordBook; value.starred = starred
        return value
    }
}

struct FeatureTranslationTransfer: Codable, Sendable {
    let id: UUID
    let source: FeatureRole
    let sequence: Int
    let initial: Bool
    let running: Bool
    let failed: Bool
    let engine: String?
    let output: FeatureTranslationOutput
}

@MainActor
final class FeatureTranslationBridge {
    private final class Entry {
        let id = UUID()
        weak var session: AskPluginSession?
        let cancel: () -> Void
        let accepted: () -> Void
        let failed: () -> Void
        let engine: String?
        var output: AskPluginOutput
        var running: Bool
        var failure = false
        var sequence = 0
        var acknowledged = false
        var sending = false
        init(session: AskPluginSession, handoff: AskPluginHandoff, output: AskPluginOutput,
             accepted: @escaping () -> Void, failed: @escaping () -> Void) {
            self.session = session; cancel = handoff.cancel; self.output = output; running = handoff.running
            self.accepted = accepted; self.failed = failed
            engine = handoff.request.options[AskTranslatePlugin.engineOption]
        }
    }
    private var entries: [UUID: Entry] = [:]
    private var preparing = false
    var route: @MainActor (FeatureCommand) async throws -> Data

    init(route: @escaping @MainActor (FeatureCommand) async throws -> Data = { try await FeatureProcess.route($0) }) {
        self.route = route
    }

    func move(_ session: AskPluginSession, accepted: @escaping () -> Void, failed: @escaping () -> Void) -> Bool {
        if let existing = entries.values.first(where: { $0.session === session && !$0.acknowledged }) {
            deliver(existing); return true
        }
        guard !preparing, entries.count < 8, session.plugin?.id == AskTranslatePlugin.id, session.isPlanCurrent else { return false }
        preparing = true
        Task {
            defer { preparing = false }
            do {
                // Establish the destination before removing the source's ownership.
                _ = try await route(.init(destination: .translation, action: "ping"))
                guard session.isPlanCurrent else { return }
                var entryID: UUID?
                guard let handoff = session.handOff(to: { [weak self] event in
                    guard let id = entryID else { return }
                    self?.receive(event, id: id)
                }) else {
                    guard let output = session.currentOutput, output.translation != nil else { return }
                    let transfer = FeatureTranslationTransfer(id: UUID(), source: FeatureProcess.role, sequence: 0,
                        initial: true, running: false, failed: false, engine: nil, output: .init(output))
                    let data = try await route(.init(destination: .translation, action: "translationTransfer", payload: JSONEncoder().encode(transfer)))
                    if try JSONDecoder().decode(Bool.self, from: data) { accepted() }
                    return
                }
                let output = handoff.output ?? AskPluginOutput(body: "", original: handoff.request.text, meta: [], source: "", actions: [],
                    translation: .init(results: [], source: handoff.plan.values["source"], target: handoff.plan.values["target"] ?? "en",
                        interface: handoff.request.interfaceLanguage, submitted: handoff.plan.mode == .onSubmit,
                        isLookup: AskWordCard.isLookup(handoff.request.text), replacesSelection: handoff.request.origin == .selection))
                let entry = Entry(session: session, handoff: handoff, output: output, accepted: accepted, failed: failed)
                entryID = entry.id; entries[entry.id] = entry
                deliver(entry)
            } catch { failed() }
        }
        return true
    }

    func cancel(_ id: String) {
        guard let id = UUID(uuidString: id), let entry = entries.removeValue(forKey: id) else { return }
        entry.cancel()
    }

    private func receive(_ event: AskPluginHandoff.Event, id: UUID) {
        guard let entry = entries[id] else { return }
        switch event {
        case let .progress(output): entry.output = output
        case let .done(output): entry.output = output; entry.running = false
        case .failed, .cancelled: entry.running = false; entry.failure = true
        }
        entry.sequence += 1
        deliver(entry)
    }

    private func deliver(_ entry: Entry) {
        guard !entry.sending else { return }
        entry.sending = true
        Task {
            defer { entry.sending = false }
            while entries[entry.id] != nil {
                let sequence = entry.sequence
                let transfer = FeatureTranslationTransfer(id: entry.id, source: FeatureProcess.role, sequence: sequence,
                    initial: !entry.acknowledged, running: entry.running, failed: entry.failure,
                    engine: entry.engine, output: .init(entry.output))
                do {
                    let data = try await route(.init(destination: .translation, action: "translationTransfer", payload: JSONEncoder().encode(transfer)))
                    guard try JSONDecoder().decode(Bool.self, from: data) else { cancel(entry.id.uuidString); return }
                    if !entry.acknowledged { entry.acknowledged = true; entry.accepted() }
                    if sequence == entry.sequence {
                        if !entry.running { entries[entry.id] = nil }
                        return
                    }
                } catch {
                    // Retain the latest result for an explicit retry; never replay the provider call.
                    entry.failed()
                    return
                }
            }
        }
    }
}
