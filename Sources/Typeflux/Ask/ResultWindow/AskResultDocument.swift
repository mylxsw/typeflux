import Foundation

/// One result shown in a window of its own (⌘O from the launcher, or a saved note): its
/// Markdown, where it came from, and what can be done with it there. A result handed over
/// mid-stream keeps streaming into it (`docs/design/ai-command-results.md`).
@MainActor
final class AskResultDocument: ObservableObject, Identifiable {
    enum State: Equatable {
        case streaming
        case done
        case failed(String)
    }

    /// What the window does through the rest of the app; tests record calls instead.
    struct Services {
        /// Saves a result as a note, returning its id; nil when it could not be saved.
        var saveNote: @MainActor (AskNoteDraft) -> UUID? = { _ in nil }
        /// Takes a saved result out of the notes. False when it stays (the user edited it).
        var removeNote: @MainActor (UUID) -> Bool = { _ in false }
        /// Whether a note still exists, to keep the star honest after the notes window deleted it.
        var noteExists: @MainActor (UUID) -> Bool = { _ in false }
        var openNotes: @MainActor (UUID?) -> Void = { _ in }
        /// Writes text into the app with this bundle id (it is brought forward first).
        var insert: @MainActor (String, String?) async -> Bool = { _, _ in false }
        var copy: @MainActor (String) -> Void = { AskQuickResults.copy($0) }
        var copyRich: @MainActor (String) -> Void = { AskRichCopy.copy($0) }
        var askAI: @MainActor (String) -> Void = { _ in }
        /// Whether the source app is still running.
        var isRunning: @MainActor (String) -> Bool = { _ in false }
    }

    /// Runs the result's prompt again, reporting the text as it grows.
    typealias Regenerate = @MainActor (@escaping @MainActor (String) -> Void) async throws -> String

    let id = UUID()
    /// The keyword's name: "Explain".
    let title: String
    let keyword: String
    let model: String?
    /// The text the prompt worked on.
    let input: String
    let sourceApp: String?
    let sourceBundleID: String?
    @Published private(set) var body: String
    @Published private(set) var state: State
    /// The saved note this result is, when it is one.
    @Published private(set) var noteID: UUID?
    /// ⌘S came while streaming: saved once done.
    @Published private(set) var savesWhenDone = false
    /// A regenerated result has not started arriving yet: the old one is drawn dimmed.
    @Published private(set) var dimmed = false
    /// Kept above other windows.
    @Published var pinned = false
    /// A short confirmation at the bottom of the window.
    @Published private(set) var notice: String?
    @Published private(set) var updatedAt: Date

    /// Opened from the notes: it shows the note and links back to it instead of regenerating.
    let fromNote: Bool
    var services: Services
    private let regenerator: Regenerate?
    private var cancelRun: (@MainActor () -> Void)?
    private var task: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    var clock: () -> Date = Date.init

    init(title: String, keyword: String, model: String?, input: String, body: String, state: State,
         sourceApp: String? = nil, sourceBundleID: String? = nil, noteID: UUID? = nil, fromNote: Bool = false,
         regenerate: Regenerate? = nil, services: Services = Services()) {
        self.title = title
        self.keyword = keyword
        self.model = model
        self.input = input
        self.body = body
        self.state = state
        self.sourceApp = sourceApp
        self.sourceBundleID = sourceBundleID
        self.noteID = noteID
        self.fromNote = fromNote
        regenerator = regenerate
        self.services = services
        updatedAt = Date()
    }

    /// A saved note, read-only here; the notes window edits it.
    convenience init(note: AskNote, services: Services) {
        self.init(title: note.command, keyword: note.keyword, model: note.model, input: note.input, body: note.body,
                  state: .done, sourceApp: note.sourceApp, sourceBundleID: note.sourceBundleID, noteID: note.id,
                  fromNote: true, services: services)
        updatedAt = note.updatedAt
    }

    /// A result the launcher hands over (⌘O), streaming or done. Regenerating runs its plugin again.
    convenience init(handoff: AskPluginHandoff, model: String?, sourceApp: String?, sourceBundleID: String?,
                     noteID: UUID? = nil, services: Services) {
        let plugin = handoff.plugin, plan = handoff.plan, request = handoff.request
        self.init(title: plan.values[AskPromptPlugin.titleOption] ?? plugin.title, keyword: request.keyword.keyword,
                  model: model, input: request.text, body: handoff.output?.body ?? "",
                  state: handoff.running ? .streaming : .done, sourceApp: sourceApp, sourceBundleID: sourceBundleID,
                  noteID: handoff.running ? nil : noteID,
                  regenerate: { progress in
                      try await plugin.run(request, plan: plan) { partial in progress(partial.body) }.body
                  },
                  services: services)
        if handoff.running { adopt(cancel: handoff.cancel) }
    }

    var isStreaming: Bool { state == .streaming }
    var canRegenerate: Bool { regenerator != nil && !isStreaming && !fromNote }
    var canInsert: Bool {
        guard !isStreaming, !body.isEmpty, let bundle = sourceBundleID else { return false }
        return services.isRunning(bundle)
    }

    /// The draft this result saves as.
    var draft: AskNoteDraft {
        AskNoteDraft(command: title, keyword: keyword, input: input, body: body, model: model,
                     sourceApp: sourceApp, sourceBundleID: sourceBundleID)
    }

    // MARK: - Streaming

    /// Takes over a run the launcher handed over (`AskPluginSession.handOff`).
    func adopt(cancel: @escaping @MainActor () -> Void) {
        cancelRun = cancel
    }

    func receive(_ event: AskPluginHandoff.Event) {
        switch event {
        case let .progress(output):
            // Stopped: text still in flight is dropped.
            guard isStreaming else { return }
            body = output.body
            dimmed = false
        case let .done(output):
            finish(output.body)
        case let .failed(failure):
            cancelRun = nil
            dimmed = false
            state = .failed(failure.message)
            savesWhenDone = false
        case .cancelled:
            cancelRun = nil
            dimmed = false
            if state == .streaming { state = body.isEmpty ? .failed(L("ask.result.stopped")) : .done }
            savesWhenDone = false
        }
    }

    /// Stops a run in progress and keeps what has arrived.
    func stop() {
        task?.cancel()
        task = nil
        cancelRun?()
        cancelRun = nil
        guard isStreaming else { return }
        dimmed = false
        state = body.isEmpty ? .failed(L("ask.result.stopped")) : .done
        savesWhenDone = false
    }

    /// The window closed: nothing may keep running for it.
    func close() {
        stop()
        noticeTask?.cancel()
    }

    func regenerate() {
        guard canRegenerate, let regenerator else { return }
        noteID = nil
        state = .streaming
        dimmed = true
        task = Task { [weak self] in
            do {
                let text = try await regenerator { [weak self] partial in
                    guard let self, self.isStreaming else { return }
                    self.body = partial
                    self.dimmed = false
                }
                guard !Task.isCancelled else { return }
                self?.finish(text)
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.dimmed = false
                self.state = .failed((error as? AskPluginFailure)?.message ?? error.localizedDescription)
            }
        }
    }

    private func finish(_ text: String) {
        cancelRun = nil
        task = nil
        body = text
        dimmed = false
        state = .done
        updatedAt = clock()
        if savesWhenDone {
            savesWhenDone = false
            save()
        }
    }

    // MARK: - Actions

    /// ⌘S: save to the notes, or take it out; while streaming, save once done.
    func toggleNote() {
        if isStreaming {
            savesWhenDone.toggle()
            show(L(savesWhenDone ? "ask.notes.saveWhenDone" : "ask.notes.saveWhenDone.cancelled"))
            return
        }
        if let noteID, services.noteExists(noteID) {
            if services.removeNote(noteID) {
                self.noteID = nil
                show(L("ask.notes.removed"))
            } else {
                show(L("ask.notes.editedKept"))
            }
            return
        }
        save()
    }

    private func save() {
        guard case .done = state, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let id = services.saveNote(draft) else { return }
        noteID = id
        show(L("ask.notes.saved"))
    }

    /// The notes window deleted or restored notes: the star follows.
    func refreshNote() {
        if let noteID, !services.noteExists(noteID) { self.noteID = nil }
    }

    func copy() {
        services.copy(body)
        show(L("ask.plugin.copied"))
    }

    func copyRich() {
        services.copyRich(body)
        show(L("ask.plugin.copiedRich"))
    }

    func insert() {
        guard canInsert else { return }
        let text = body
        Task { [weak self] in
            guard let self else { return }
            let delivered = await self.services.insert(text, self.sourceBundleID)
            if !delivered {
                self.services.copy(text)
                self.show(L("ask.plugin.writeBack.failed"))
            }
        }
    }

    func askAI() {
        services.askAI(L("ask.plugin.prompt.askAI", title, input, body))
    }

    func openNotes() {
        services.openNotes(noteID)
    }

    func show(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}
