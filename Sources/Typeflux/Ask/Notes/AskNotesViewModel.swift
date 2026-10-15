import AppKit
import Foundation
import UniformTypeIdentifiers

// swiftlint:disable file_length

/// The notes window's state: the shelves and search, the list, the chosen note and its
/// edits, picked notes, Recently Deleted (`docs/design/notebook-redesign.md`).
@MainActor
// Keep draft, selection and deletion transitions behind the same save barrier.
// swiftlint:disable:next type_body_length
final class AskNotesViewModel: ObservableObject {
    /// How the chosen note is shown.
    enum Mode: String, CaseIterable {
        /// Rendered Markdown.
        case read
        /// The Markdown source in place.
        case edit
        /// Source and preview side by side.
        case split
    }

    /// A run of list rows under one heading ("Pinned", "Today" …).
    struct Section: Identifiable, Equatable {
        var title: String
        var notes: [AskNote]
        var id: String { title }
    }

    @Published var scope: AskNoteQuery.Scope = .all {
        didSet {
            guard scope != oldValue, !restoringFilter else { return }
            let requested = scope
            restoringFilter = true; scope = oldValue; restoringFilter = false
            transition { self.restoringFilter = true; self.scope = requested; self.restoringFilter = false }
        }
    }
    @Published var searchText = "" {
        didSet {
            guard searchText != oldValue, !restoringFilter else { return }
            let requested = searchText
            restoringFilter = true; searchText = oldValue; restoringFilter = false
            transition { self.restoringFilter = true; self.searchText = requested; self.restoringFilter = false }
        }
    }
    private var transitionTask: Task<Void, Never>?
    private func setFilters(scope: AskNoteQuery.Scope? = nil, search: String? = nil) {
        restoringFilter = true
        if let scope { self.scope = scope }
        if let search { searchText = search }
        restoringFilter = false
    }

    private func transition(_ change: @escaping @MainActor () -> Void) {
        transitionTask?.cancel()
        transitionTask = Task { [weak self] in
            guard let self, await self.finishEditing(), !Task.isCancelled else { return }
            change()
            if self.scope == .trash { self.selecting = false; self.picked = [] }
            await self.reload().value
        }
    }
    @Published var sort: AskNoteQuery.Sort = .updated { didSet { if sort != oldValue { reload() } } }
    @Published private(set) var notes: [AskNote] = []
    @Published private(set) var commands: [AskNoteFacet] = []
    @Published private(set) var sources: [AskNoteSource: Int] = [:]
    @Published private(set) var tags: [AskNoteFacet] = []
    @Published private(set) var counts: [AskNoteQuery.Scope: Int] = [:]
    @Published var selectedID: UUID?
    @Published private(set) var mode: Mode = .read
    /// The chosen note's text while it is edited; saved shortly after typing stops.
    @Published var draftBody = "" { didSet { if editing, draftBody != oldValue { scheduleAutosave() } } }
    /// Edits not yet written.
    @Published private(set) var hasUnsavedDraft = false
    /// An external change cannot overwrite the text still open in the editor.
    @Published private(set) var draftConflict = false
    private var draftBaseline: AskNote?
    @Published private(set) var pendingTitle: String?
    private var titleBaseline: AskNote?
    private var restoringFilter = false
    /// Several notes are picked for one action.
    @Published private(set) var selecting = false
    @Published private(set) var picked: Set<UUID> = []
    /// Deleted notes, newest last, for undo.
    @Published private(set) var deleted: [AskNote] = []
    /// How many notes each deletion took, so undo puts back one deletion at a time.
    private var deletedBatches: [Int] = []
    /// A short message at the bottom of the window.
    @Published var notice: String? { didSet { noticeOffersUndo = false; noticeReveals = nil } }
    /// The message is about a deletion, so it offers undo.
    @Published private(set) var noticeOffersUndo = false
    /// A file or folder the message can show in Finder.
    @Published private(set) var noticeReveals: URL?
    @Published var showsOutline = true
    @Published var exportOptions = AskNoteExporter.Options()

    let store: any AskNoteStoring
    /// Where the agent switch and the hidden tags are kept; nil hides them.
    var agentSettings: SettingsStore? { didSet { readAgentSettings() } }
    /// The agent may search, read and change these notes (`notebook` tool).
    @Published private(set) var agentEnabled = true
    /// Notes with these tags do not exist for the agent.
    @Published private(set) var agentHiddenTags: [String] = []
    var openInWindow: @MainActor (AskNote) -> Void = { AskResultWindowController.shared.open($0) }
    var askAI: (@MainActor (AskNote) -> Void)?
    /// Brings the conversation a note was saved from to the front; nil when that is not possible.
    var openConversation: (@MainActor (String) -> Void)?
    var copy: @MainActor (String) -> Void = { AskQuickResults.copy($0) }
    var copyRich: @MainActor (String) -> Void = { AskRichCopy.copy($0) }
    var chooseExportURL: @MainActor (String) -> URL? = { name in
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
    var chooseFolder: @MainActor () -> URL? = {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L("ask.notes.export")
        return panel.runModal() == .OK ? panel.url : nil
    }
    var chooseImportFiles: @MainActor () -> [URL] = {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .text] + ["md", "markdown"].compactMap { .init(filenameExtension: $0) }
        return panel.runModal() == .OK ? panel.urls : []
    }
    var revealInFinder: @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    var clock: () -> Date = Date.init
    /// How long typing pauses before an edit is saved.
    var autosaveDelay: Duration = .milliseconds(600)
    @Published private var revisions: [UUID: [AskNoteRevision]] = [:]
    private var reloadTask: Task<Void, Never>?
    private var reloadGeneration = UUID()
    private var savingDraft = false
    private var savingTitle = false
    private var autosaveTask: Task<Void, Never>?
    /// The last note picked by a plain or ⌘ click, where a ⇧ click range starts.
    private var pickAnchor: UUID?
    private var observer: NSObjectProtocol?
    private let notificationCenter: NotificationCenter

    init(store: any AskNoteStoring, notificationCenter: NotificationCenter = .default) {
        self.store = store
        self.notificationCenter = notificationCenter
        observer = notificationCenter.addObserver(forName: .askNotesDidChange, object: nil,
                                                  queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.reload() }
        }
        reload()
    }

    deinit {
        if let observer { notificationCenter.removeObserver(observer) }
        autosaveTask?.cancel()
        reloadTask?.cancel()
        transitionTask?.cancel()
    }

    var selected: AskNote? {
        if let note = notes.first(where: { $0.id == selectedID }) { return note }
        if editing, draftBaseline?.id == selectedID { return draftBaseline }
        if pendingTitle != nil, titleBaseline?.id == selectedID { return titleBaseline }
        return nil
    }
    var editing: Bool { mode != .read }
    var inTrash: Bool { scope == .trash }

    /// Reads the list and the sidebar again, keeping the chosen note when it is still listed.
    @discardableResult
    func reload() -> Task<Void, Never> {
        reloadTask?.cancel()
        let generation = UUID()
        reloadGeneration = generation
        let query = AskNoteQuery(scope: scope, text: Self.parseSearch(searchText).text, sort: sort)
        let filters = Self.parseSearch(searchText).tags
        let store = store
        let task = Task { [weak self] in
            do {
                var listed = try await store.list(query)
                listed = listed.filter { note in filters.allSatisfy { wanted in
                    note.tags.contains { $0.localizedCaseInsensitiveCompare(wanted) == .orderedSame }
                } }
                let commands = try await store.commands()
                let tags = try await store.tags()
                let sourceFacets = try await store.sources()
                var counts: [AskNoteQuery.Scope: Int] = [:]
                for scope: AskNoteQuery.Scope in [.all, .pinned, .recent, .trash] {
                    counts[scope] = try await store.count(scope)
                }
                var revisions: [UUID: [AskNoteRevision]] = [:]
                for note in listed where note.author == .agent {
                    revisions[note.id] = try await store.revisions(of: note.id)
                }
                guard let self, !Task.isCancelled, self.reloadGeneration == generation else { return }
                self.notes = listed
                self.commands = commands
                self.tags = tags
                self.sources = Dictionary(sourceFacets.compactMap { facet in
                    AskNoteSource(rawValue: facet.name).map { ($0, facet.count) }
                }, uniquingKeysWith: { _, last in last })
                self.counts = counts
                self.revisions = revisions
                let emptyShelf: Bool
                switch self.scope {
                case let .command(name): emptyShelf = !commands.contains { $0.name == name }
                case let .tag(tag): emptyShelf = !tags.contains { $0.name == tag }
                case let .source(source): emptyShelf = (self.sources[source] ?? 0) == 0
                default: emptyShelf = false
                }
                if emptyShelf {
                    self.setFilters(scope: .all)
                    await self.reload().value
                    return
                }
                self.picked = self.picked.filter { id in listed.contains { $0.id == id } }
                if self.editing, !self.hasUnsavedDraft, let baseline = self.draftBaseline,
                   let current = listed.first(where: { $0.id == baseline.id }), !current.isDeleted {
                    self.draftBaseline = current
                    self.setDraftBody(current.body)
                }
                if self.selected == nil { self.selectedID = listed.first?.id }
            } catch {
                guard let self, !Task.isCancelled, self.reloadGeneration == generation else { return }
                self.notice = L("ask.notes.storageUnavailable")
            }
        }
        reloadTask = task
        return task
    }

    func waitForActions() async {
        await actionTask?.value
        await waitForNavigation()
    }

    func waitForNavigation() async {
        await transitionTask?.value
        await waitForReload()
    }

    func waitForReload() async {
        while let task = reloadTask {
            let generation = reloadGeneration
            await task.value
            if generation == reloadGeneration { return }
        }
    }

    private var actionTask: Task<Void, Never>?
    /// Serialize UI gestures without queuing or replaying mutations.
    func perform(_ operation: @escaping @MainActor () async -> Void) {
        guard actionTask == nil else { return }
        actionTask = Task { [weak self] in
            defer { self?.actionTask = nil }
            await operation()
        }
    }

    func cancelPendingReads() {
        autosaveTask?.cancel()
        actionTask?.cancel()
        reloadTask?.cancel()
        transitionTask?.cancel()
        reloadGeneration = UUID()
    }

    /// Search text without its `#tag` words, and those tags.
    static func parseSearch(_ text: String) -> (text: String, tags: [String]) {
        var words: [String] = []
        var tags: [String] = []
        for word in text.split(whereSeparator: \.isWhitespace) {
            if word.hasPrefix("#") {
                if let tag = AskNote.normalizedTag(String(word)) { tags.append(tag) }
            } else {
                words.append(String(word))
            }
        }
        return (words.joined(separator: " "), tags)
    }

    /// Shows a note, leaving filters that would hide it.
    func reveal(_ id: UUID?) async {
        do {
            guard let id, let note = try await store.note(id: id), await finishEditing() else { return }
            if !notes.contains(where: { $0.id == id }) {
                setFilters(scope: note.isDeleted ? .trash : .all, search: "")
                await reload().value
            }
            await select(id)
        } catch {
            notice = L("ask.notes.storageUnavailable")

        }
    }

    func select(_ id: UUID?) async {
        guard id != selectedID else { return }
        guard await finishEditing() else { return }
        selectedID = id
    }

    /// The arrows in the list.
    func moveSelection(_ delta: Int) async {
        guard !notes.isEmpty else { return }
        let index = notes.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : notes.count)
        await select(notes[min(max(0, index + delta), notes.count - 1)].id)
    }

    func title(of scope: AskNoteQuery.Scope) -> String {
        switch scope {
        case .all: L("ask.notes.shelf.all")
        case .pinned: L("ask.notes.shelf.pinned")
        case .recent: L("ask.notes.shelf.recent")
        case .trash: L("ask.notes.shelf.trash")
        case let .source(source): source.title
        case let .command(name): name
        case let .tag(tag): "#" + tag
        }
    }

    /// The list under headings: pinned notes, then by day of the sorted date.
    var sections: [Section] {
        Self.sections(notes, sort: sort, trash: inTrash, now: clock())
    }

    static func sections(_ notes: [AskNote], sort: AskNoteQuery.Sort, trash: Bool, now: Date,
                         calendar: Calendar = .current) -> [Section] {
        if sort == .title { return notes.isEmpty ? [] : [Section(title: L("ask.notes.group.all"), notes: notes)] }
        var result: [Section] = []
        func add(_ note: AskNote, to title: String) {
            if let index = result.firstIndex(where: { $0.title == title }) {
                result[index].notes.append(note)
            } else {
                result.append(Section(title: title, notes: [note]))
            }
        }
        for note in notes {
            if !trash, note.pinned { add(note, to: L("ask.notes.group.pinned")); continue }
            let date = trash ? (note.deletedAt ?? note.updatedAt) : (sort == .created ? note.createdAt : note.updatedAt)
            add(note, to: dayGroup(date, now: now, calendar: calendar))
        }
        return result
    }

    static func dayGroup(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return L("ask.notes.group.today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return L("ask.notes.group.yesterday")
        }
        if now.timeIntervalSince(date) < AskNoteQuery.recentInterval { return L("ask.notes.group.week") }
        return L("ask.notes.group.earlier")
    }

    // MARK: - The agent

    private func readAgentSettings() {
        agentEnabled = agentSettings?.askNotebookAgentEnabled ?? true
        agentHiddenTags = agentSettings?.askNotebookHiddenTags ?? []
    }

    func setAgentEnabled(_ enabled: Bool) {
        agentSettings?.askNotebookAgentEnabled = enabled
        readAgentSettings()
    }

    func isHiddenFromAgent(_ tag: String) -> Bool {
        agentHiddenTags.contains { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame }
    }

    /// Hides a tag's notes from the agent, or shows them again.
    func toggleHiddenFromAgent(_ tag: String) {
        guard let settings = agentSettings else { return }
        var tags = settings.askNotebookHiddenTags
        if isHiddenFromAgent(tag) {
            tags.removeAll { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame }
        } else {
            tags.append(tag)
        }
        settings.askNotebookHiddenTags = tags
        readAgentSettings()
    }

    // MARK: - Writing

    /// A new note written here, chosen and open for editing. On a tag shelf it carries that tag.
    @discardableResult
    func createNote(title: String = "", body: String = "") async -> UUID? {
        do {
            guard await finishEditing() else { return nil }
            let now = clock()
            var tags: [String] = []
            if case let .tag(tag) = scope { tags = [tag] }
            let note = AskNote(title: title.trimmingCharacters(in: .whitespacesAndNewlines), body: body, command: "",
                               keyword: "", input: "", tags: tags, createdAt: now, updatedAt: now, source: .manual)
            guard try await store.save(note) else { notice = L("ask.notes.saveFailed"); return nil }
            selecting = false
            picked = []
            switch scope {
            case .all, .recent, .tag, .source(.manual): break
            default: setFilters(scope: .all)
            }
            setFilters(search: "")
            await reload().value
            selectedID = note.id
            beginEditing()
            return note.id
        } catch {
            notice = L("ask.notes.storageUnavailable")
            return nil
        }
    }

    /// Holds title edits until they can be saved; navigation shares the body save barrier.
    func stageTitle(_ title: String, id: UUID) {
        guard let note = notes.first(where: { $0.id == id }), !note.isDeleted else { return }
        if titleBaseline == nil { titleBaseline = note }
        guard titleBaseline?.id == id else { return }
        pendingTitle = title
        if title == titleBaseline?.title {
            pendingTitle = nil
            titleBaseline = nil
            return
        }
        scheduleAutosave(bodyChanged: false)
    }

    @discardableResult
    func savePendingTitle() async -> Bool {
        guard !savingTitle else { return pendingTitle == nil }
        savingTitle = true
        defer { savingTitle = false }
        do {
            guard let title = pendingTitle, let baseline = titleBaseline else { return true }
            guard let previous = try await store.note(id: baseline.id), !previous.isDeleted else {
                draftConflict = true
                notice = L("ask.notes.saveConflict")
                return false
            }
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let next = trimmed.isEmpty ? defaultTitle(previous) : trimmed
            guard previous.title == baseline.title || previous.title == next else {
                draftConflict = true
                notice = L("ask.notes.saveConflict")
                return false
            }
            var note = previous
            note.title = next
            note.updatedAt = clock()
            note.author = .user
            let saved = next == previous.title ? true : try await store.save(note, replacing: previous, revisionAt: nil)
            guard saved else {
                notice = L("ask.notes.saveFailed")
                return false
            }
            let committed = next == previous.title ? previous : note
            if let index = notes.firstIndex(where: { $0.id == committed.id }) { notes[index] = committed }
            guard pendingTitle == title else { titleBaseline = committed; return false }
            pendingTitle = nil
            titleBaseline = nil
            draftConflict = false
            await reload().value
            return true
        } catch {
            notice = L("ask.notes.storageUnavailable")
            return false
        }
    }

    /// A new title; an empty one goes back to the default.
    func rename(_ title: String, id: UUID? = nil) async {
        do {
            guard let id = id ?? selectedID, let previous = try await store.note(id: id), !previous.isDeleted else { return }
            var note = previous
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let next = trimmed.isEmpty ? defaultTitle(note) : trimmed
            guard next != note.title else { return }
            note.title = next
            note.updatedAt = clock()
            await update(note, replacing: previous)
        } catch {
            notice = L("ask.notes.storageUnavailable")

        }
    }

    private func defaultTitle(_ note: AskNote) -> String {
        if note.source == .manual || note.source == .import {
            let body = editing && note.id == selectedID ? draftBody : note.body
            if let heading = AskNoteHeading.parse(body).first { return String(heading.text.prefix(80)) }
            let line = AskNote.oneLine(AskNote.plainText(body))
            return line.isEmpty ? L("ask.notes.untitled") : String(line.prefix(AskNote.titleLength))
        }
        return AskNote.title(command: note.command, input: note.input, body: note.body)
    }

    func beginEditing(_ mode: Mode = .edit) {
        guard let note = selected, !note.isDeleted, mode != .read else { return }
        if !editing {
            draftBaseline = note
            draftBody = note.body
            hasUnsavedDraft = false
            draftConflict = false
        }
        self.mode = mode
    }

    /// Read, edit or split; leaving editing saves.
    func setMode(_ mode: Mode) async {
        if mode == .read { await finishEditing() } else { beginEditing(mode) }
    }

    /// ⌘E: reading and editing.
    func toggleEditing() async { await setMode(editing ? .read : .edit) }

    /// Returns false when leaving would lose a draft that could not be saved.
    @discardableResult
    func finishEditing() async -> Bool {
        guard await savePendingTitle() else { return false }
        guard editing else { return true }
        guard await saveDraft() else { return false }
        guard !hasUnsavedDraft, pendingTitle == nil else { return false }
        endEditing()
        return true
    }

    /// Leaves editing; whatever was typed is kept (edits save as they are made).
    func cancelEditing() async { await finishEditing() }

    private func endEditing() {
        autosaveTask?.cancel()
        autosaveTask = nil
        hasUnsavedDraft = false
        draftConflict = false
        mode = .read
        draftBaseline = nil
    }

    private func setDraftBody(_ body: String) {
        // Setting text from the store is not a user edit and must not start a save.
        let previousMode = mode
        mode = .read
        draftBody = body
        mode = previousMode
    }

    private func scheduleAutosave(bodyChanged: Bool = true) {
        if bodyChanged { hasUnsavedDraft = true }
        autosaveTask?.cancel()
        let delay = autosaveDelay
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.saveDraft()
        }
    }

    /// Writes only against the current version, preserving concurrent metadata edits.
    @discardableResult
    func saveDraft() async -> Bool {
        guard !savingDraft else { return !hasUnsavedDraft && pendingTitle == nil }
        savingDraft = true
        defer { savingDraft = false }
        do {
            guard await savePendingTitle() else { return false }
            guard editing, let baseline = draftBaseline else { return true }
            guard hasUnsavedDraft else { return true }
            let submittedBody = draftBody
            guard let previous = try await store.note(id: baseline.id), !previous.isDeleted,
                  previous.body == baseline.body || previous.body == submittedBody else {
                draftConflict = true
                notice = L("ask.notes.saveConflict")
                return false
            }
            if submittedBody == previous.body {
                draftBaseline = previous
                guard draftBody == submittedBody else { return false }
                hasUnsavedDraft = false
                draftConflict = false
                return true
            }
            var note = previous
            let now = clock()
            if note.originalBody == nil, note.source != .manual, note.source != .import { note.originalBody = note.body }
            note.body = submittedBody
            note.updatedAt = now
            note.editedAt = now
            note.author = .user
            if note.title.isEmpty { note.title = defaultTitle(note) }
            guard try await store.save(note, replacing: previous, revisionAt: nil) else {
                notice = L("ask.notes.saveFailed")
                return false
            }
            draftBaseline = note
            guard draftBody == submittedBody else { return false }
            hasUnsavedDraft = false
            draftConflict = false
            await reload().value
            return true
        } catch {
            notice = L("ask.notes.storageUnavailable")
            return false
        }
    }

    /// Keeps both versions when the agent changed or deleted the original note.
    func saveDraftCopy() async {
        do {
            guard let baseline = draftBaseline ?? titleBaseline else { return }
            let now = clock()
            let metadata = try await store.note(id: baseline.id) ?? baseline
            let title = pendingTitle ?? metadata.title
            let body = editing ? draftBody : metadata.body
            let note = AskNote(title: title, body: body, command: "", keyword: "", input: "",
                               tags: metadata.tags, createdAt: now, updatedAt: now, source: .manual)
            guard try await store.save(note) else { notice = L("ask.notes.saveFailed"); return }
            guard (pendingTitle ?? metadata.title) == title, !editing || draftBody == body else { return }
            pendingTitle = nil
            titleBaseline = nil
            endEditing()
            setFilters(scope: .all, search: "")
            await reload().value
            selectedID = note.id
            notice = nil
        } catch {
            notice = L("ask.notes.storageUnavailable")

        }
    }

    func togglePin() async {
        do {
            guard let id = selectedID, let previous = try await store.note(id: id), !previous.isDeleted else { return }
            var note = previous
            note.pinned.toggle()
            await update(note, replacing: previous)
        } catch {
            notice = L("ask.notes.storageUnavailable")

        }
    }

    func addTag(_ text: String) async {
        do {
            guard let id = selectedID, let previous = try await store.note(id: id), !previous.isDeleted,
                  let tag = AskNote.normalizedTag(text),
                  !previous.tags.contains(where: { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame })
            else { return }
            var note = previous
            note.tags.append(tag)
            note.updatedAt = clock()
            await update(note, replacing: previous)
        } catch {
            notice = L("ask.notes.storageUnavailable")

        }
    }

    func removeTag(_ tag: String) async {
        do {
            guard let id = selectedID, let previous = try await store.note(id: id), !previous.isDeleted,
                  previous.tags.contains(tag) else { return }
            var note = previous
            note.tags.removeAll { $0 == tag }
            note.updatedAt = clock()
            await update(note, replacing: previous)
        } catch {
            notice = L("ask.notes.storageUnavailable")

        }
    }

    /// Ticks or clears the `index`th task while reading; only its box changes.
    func toggleTask(_ index: Int) async {
        do {
            guard !editing, let id = selectedID, let previous = try await store.note(id: id), !previous.isDeleted,
                  let body = AskNoteTasks.toggling(previous.body, task: index) else { return }
            var note = previous
            if note.originalBody == nil, note.source != .manual, note.source != .import { note.originalBody = note.body }
            note.body = body
            note.updatedAt = clock()
            note.editedAt = note.updatedAt
            note.author = .user
            await update(note, replacing: previous)
        } catch {
            notice = L("ask.notes.storageUnavailable")

        }
    }

    /// The text the note had before the agent last changed it, when there is one.
    var agentRevision: AskNoteRevision? {
        guard let note = selected, note.author == .agent,
              let revision = revisions[note.id]?.first,
              revision.title != note.title || revision.body != note.body else { return nil }
        return revision
    }

    /// Puts back the text from before the agent's last change.
    func revertAgentChange() async {
        do {
            guard await finishEditing(), let id = selectedID, let previous = try await store.note(id: id), !previous.isDeleted,
                  previous.author == .agent, let revision = try await store.revisions(of: id).first,
                  revision.title != previous.title || revision.body != previous.body else { return }
            var note = previous
            note.title = revision.title
            note.body = revision.body
            note.author = .user
            note.editedAt = clock()
            note.updatedAt = clock()
            guard await update(note, replacing: previous) else { return }
            try await store.deleteRevision(of: note.id, at: revision.createdAt)
            notice = L("ask.notes.agentReverted")
        } catch {
            notice = L("ask.notes.storageUnavailable")

        }
    }

    @discardableResult
    private func update(_ note: AskNote, replacing previous: AskNote) async -> Bool {
        do {
            guard try await store.save(note, replacing: previous, revisionAt: nil) else {
                notice = L("ask.notes.saveFailed")
                return false
            }
            await reload().value
            return true
        } catch {
            notice = L("ask.notes.storageUnavailable")
            return false
        }
    }

    // MARK: - Deleting

    /// Moves the chosen note to Recently Deleted; in Recently Deleted, removes it for good.
    func deleteSelected() async {
        do {
            guard await finishEditing(), let id = selectedID, let note = try await store.note(id: id) else { return }
            if note.isDeleted { await deleteForever(); return }
            guard await trash([note]) else { return }
            notice = L("ask.notes.deleted", note.title.isEmpty ? L("ask.notes.untitled") : note.title)
            noticeOffersUndo = true
        } catch {
            notice = L("ask.notes.storageUnavailable")

        }
    }

    @discardableResult
    private func trash(_ chosen: [AskNote]) async -> Bool {
        do {
            guard !chosen.isEmpty else { return false }
            let now = clock()
            let index = notes.firstIndex { $0.id == chosen.first?.id } ?? 0
            try await store.trash(ids: chosen.map(\.id), at: now)
            let removed = chosen.map { note in var removed = note; removed.deletedAt = now; return removed }
            guard !removed.isEmpty else { notice = L("ask.notes.saveFailed"); return false }
            deleted.append(contentsOf: removed)
            deletedBatches.append(removed.count)
            let gone = Set(removed.map(\.id))
            notes.removeAll { gone.contains($0.id) }
            selectedID = notes.isEmpty ? nil : notes[min(index, notes.count - 1)].id
            await reload().value
            return true
        } catch {
            notice = L("ask.notes.storageUnavailable")
            return false
        }
    }

    /// Takes back the last deletion, whether of one note or of several.
    func undoDelete() async {
        do {
            guard await finishEditing(), !deleted.isEmpty else { return }
            let size = min(deletedBatches.last ?? 1, deleted.count)
            let batch = Array(deleted.suffix(size))
            var restored: [UUID] = []
            for removed in batch {
                // A newer edit or permanent deletion must never be undone by an old snapshot.
                guard let previous = try await store.note(id: removed.id), previous.isDeleted else { continue }
                var note = previous
                note.deletedAt = nil
                guard await update(note, replacing: previous) else { return }
                restored.append(note.id)
            }
            deleted.removeLast(size)
            _ = deletedBatches.popLast()
            await reload().value
            await reveal(restored.last)
            notice = nil
        } catch {
            notice = L("ask.notes.storageUnavailable")

        }
    }

    /// Recently Deleted: puts the chosen note back.
    func restoreFromTrash() async {
        guard let previous = selected, previous.isDeleted else { return }
        var note = previous
        note.deletedAt = nil
        guard await update(note, replacing: previous) else { return }
        notice = L("ask.notes.restoredFromTrash", note.title)
    }

    /// Recently Deleted: removes the chosen note for good.
    func deleteForever() async {
        do {
            guard let note = selected, note.isDeleted else { return }
            let index = notes.firstIndex { $0.id == note.id } ?? 0
            try await store.delete(ids: [note.id])
            notes.removeAll { $0.id == note.id }
            selectedID = notes.isEmpty ? nil : notes[min(index, notes.count - 1)].id
            await reload().value
        } catch {
            notice = L("ask.notes.storageUnavailable")

        }
    }

    func emptyTrash() async {
        do {
            let ids = try await store.list(AskNoteQuery(scope: .trash, limit: Int(Int32.max))).map(\.id)
            try await store.delete(ids: ids)
            await reload().value
        } catch {
            notice = L("ask.notes.storageUnavailable")

        }
    }

    // MARK: - Picking several

    func setSelecting(_ enabled: Bool) async {
        guard !inTrash || !enabled else { return }
        if enabled, !(await finishEditing()) { return }
        selecting = enabled
        picked = enabled ? Set(selectedID.map { [$0] } ?? []) : []
        pickAnchor = enabled ? selectedID : nil
    }

    /// ⌘ click: adds or removes one note.
    func togglePick(_ id: UUID) async {
        if !selecting { await setSelecting(true) }
        guard selecting else { return }
        if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
        pickAnchor = id
    }

    /// ⇧ click: every note between the last picked one and this one.
    func pickRange(to id: UUID) async {
        if !selecting { await setSelecting(true) }
        guard selecting, let end = notes.firstIndex(where: { $0.id == id }) else { return }
        let start = pickAnchor.flatMap { anchor in notes.firstIndex { $0.id == anchor } } ?? end
        for note in notes[min(start, end) ... max(start, end)] { picked.insert(note.id) }
    }

    /// ⌘A
    func pickAll() async {
        guard !inTrash else { return }
        if !selecting { await setSelecting(true) }
        guard selecting else { return }
        picked = Set(notes.map(\.id))
    }

    /// Picked notes in list order.
    var pickedNotes: [AskNote] { notes.filter { picked.contains($0.id) } }

    func pinPicked() async {
        do {
            let chosen = pickedNotes
            let pin = !chosen.allSatisfy(\.pinned)
            for chosenNote in chosen {
                guard let previous = try await store.note(id: chosenNote.id), !previous.isDeleted else { continue }
                var note = previous
                note.pinned = pin
                await update(note, replacing: previous)
            }
            await reload().value
        } catch {
            notice = L("ask.notes.storageUnavailable")

        }
    }

    func tagPicked(_ text: String) async {
        do {
            guard let tag = AskNote.normalizedTag(text) else { return }
            let now = clock()
            for chosen in pickedNotes {
                guard let previous = try await store.note(id: chosen.id), !previous.isDeleted,
                      !previous.tags.contains(where: { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame })
                else { continue }
                var note = previous
                note.tags.append(tag)
                note.updatedAt = now
                await update(note, replacing: previous)
            }
            await reload().value
        } catch {
            notice = L("ask.notes.storageUnavailable")

        }
    }

    func copyPicked() {
        let chosen = pickedNotes
        guard !chosen.isEmpty else { return }
        copy(AskNoteExporter.merged(chosen))
        notice = L("ask.notes.copiedSeveral", chosen.count)
    }

    func exportPicked() { exportFolder(pickedNotes) }

    func trashPicked() async {
        let chosen = pickedNotes
        guard !chosen.isEmpty else { return }
        guard await trash(chosen) else { return }
        picked = []
        selecting = false
        notice = L("ask.notes.deletedSeveral", chosen.count)
        noticeOffersUndo = true
    }

    // MARK: - Using a note

    private var selectedContent: AskNote? {
        guard var note = selected else { return nil }
        if editing { note.body = draftBody }
        if titleBaseline?.id == note.id, let pendingTitle { note.title = pendingTitle }
        return note
    }

    func copySelected() {
        guard let note = selectedContent else { return }
        copy(note.body)
        notice = L("ask.plugin.copied")
    }

    func copySelectedRich() {
        guard let note = selectedContent else { return }
        copyRich(note.body)
        notice = L("ask.plugin.copiedRich")
    }

    func askAIAboutSelected() {
        guard let note = selectedContent, let askAI else { return }
        askAI(note)
    }

    func openSelectedInWindow() {
        guard let note = selectedContent else { return }
        openInWindow(note)
    }

    /// "Back to conversation" for a note saved from one.
    var canOpenSource: Bool { selected?.conversationID != nil && openConversation != nil }

    func openSource() {
        guard let id = selected?.conversationID else { return }
        openConversation?(id)
    }

    func exportSelected(_ format: AskNoteExporter.Format = .markdown) {
        guard let note = selectedContent,
              let url = chooseExportURL(AskNoteExporter.fileName(note, format: format)) else { return }
        guard let data = AskNoteExporter.data(note, format: format, options: exportOptions) else {
            notice = L("ask.notes.exportFailed")
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            notice = L("ask.notes.exported", url.lastPathComponent)
            noticeReveals = url
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Every note that is not deleted, as Markdown files in a new folder.
    func exportAll() async {
        do {
            guard await saveDraft() else { return }
            exportFolder(try await store.list(AskNoteQuery(limit: Int(Int32.max))))
        } catch {
            notice = L("ask.notes.storageUnavailable")

        }
    }

    private func exportFolder(_ chosen: [AskNote]) {
        guard !chosen.isEmpty, let directory = chooseFolder() else { return }
        do {
            let folder = try AskNoteExporter.exportFolder(chosen, into: directory,
                                                          date: clock(), options: exportOptions)
            notice = L("ask.notes.exportedSeveral", chosen.count, folder.lastPathComponent)
            noticeReveals = folder
        } catch {
            notice = error.localizedDescription
        }
    }

    func revealNoticeTarget() {
        guard let url = noticeReveals else { return }
        revealInFinder(url)
    }

    // MARK: - Importing

    func importFiles() async { await importFiles(chooseImportFiles()) }

    /// Markdown or text files as new notes; the first is chosen.
    func importFiles(_ urls: [URL]) async {
        do {
            guard !urls.isEmpty, await finishEditing() else { return }
            let result = AskNoteImporter.notes(from: urls, now: clock())
            var imported: [AskNote] = []
            for note in result.notes {
                if try await store.save(note) { imported.append(note) }
            }
            let skipped = result.skipped.count + result.notes.count - imported.count
            if !imported.isEmpty {
                selecting = false
                picked = []
                setFilters(search: "")
                if scope != .all, scope != .source(.import) { setFilters(scope: .all) }
                await reload().value
                selectedID = imported.first?.id
            }
            notice = skipped == 0
                ? L("ask.notes.imported", imported.count)
                : L("ask.notes.importedSkipped", imported.count, skipped)
        } catch {
            notice = L("ask.notes.storageUnavailable")

        }
    }
}
