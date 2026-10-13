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
            guard finishEditing() else {
                restoringFilter = true; scope = oldValue; restoringFilter = false
                return
            }
            scopeChanged()
        }
    }
    @Published var searchText = "" {
        didSet {
            guard searchText != oldValue, !restoringFilter else { return }
            guard finishEditing() else {
                restoringFilter = true; searchText = oldValue; restoringFilter = false
                return
            }
            reload()
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
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    deinit {
        if let observer { notificationCenter.removeObserver(observer) }
        autosaveTask?.cancel()
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
    func reload() {
        let (text, tagFilters) = Self.parseSearch(searchText)
        var listed = store.list(AskNoteQuery(scope: scope, text: text, sort: sort))
        if !tagFilters.isEmpty {
            listed = listed.filter { note in
                tagFilters.allSatisfy { wanted in
                    note.tags.contains { $0.localizedCaseInsensitiveCompare(wanted) == .orderedSame }
                }
            }
        }
        // A note being edited keeps its draft on screen while the store catches up.
        notes = listed
        commands = store.commands()
        tags = store.tags()
        var bySource: [AskNoteSource: Int] = [:]
        for facet in store.sources() {
            if let source = AskNoteSource(rawValue: facet.name) { bySource[source] = facet.count }
        }
        sources = bySource
        counts = [.all: store.count(.all), .pinned: store.count(.pinned), .recent: store.count(.recent),
                  .trash: store.count(.trash)]
        // A shelf whose last note went away falls back to all notes.
        switch scope {
        case let .command(name) where !commands.contains(where: { $0.name == name }): scope = .all
        case let .tag(tag) where !tags.contains(where: { $0.name == tag }): scope = .all
        case let .source(source) where (sources[source] ?? 0) == 0: scope = .all
        default: break
        }
        picked = picked.filter { id in notes.contains { $0.id == id } }
        // Filtering or a change from the agent must not discard the active draft.
        // A clean editor can follow external text; a dirty editor keeps its baseline.
        if editing, let baseline = draftBaseline, !hasUnsavedDraft,
           let current = store.note(id: baseline.id), !current.isDeleted {
            draftBaseline = current
            setDraftBody(current.body)
        }
        if selected == nil { selectedID = notes.first?.id }
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

    private func scopeChanged() {
        if scope == .trash { selecting = false; picked = [] }
        reload()
        selectedID = notes.first?.id
    }

    /// Shows a note, leaving filters that would hide it.
    func reveal(_ id: UUID?) {
        guard let id, let note = store.note(id: id), finishEditing() else { return }
        if !notes.contains(where: { $0.id == id }) {
            searchText = ""
            scope = note.isDeleted ? .trash : .all
        }
        select(id)
    }

    func select(_ id: UUID?) {
        guard id != selectedID else { return }
        guard finishEditing() else { return }
        selectedID = id
    }

    /// Native List selection preserves the same save barrier as keyboard navigation.
    var listSelection: Set<UUID> {
        selecting ? picked : Set(selectedID.map { [$0] } ?? [])
    }

    func selectFromList(_ selection: Set<UUID>) {
        let visible = selection.intersection(Set(notes.map(\.id)))
        guard selection.isEmpty || !visible.isEmpty, visible != listSelection else { return }
        if inTrash || (!selecting && visible.count <= 1) {
            select(notes.first { visible.contains($0.id) }?.id)
        } else {
            guard finishEditing() else { return }
            selecting = true
            picked = visible
            pickAnchor = notes.first { visible.contains($0.id) }?.id
        }
    }

    /// The arrows in the list.
    func moveSelection(_ delta: Int) {
        guard !notes.isEmpty else { return }
        let index = notes.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : notes.count)
        select(notes[min(max(0, index + delta), notes.count - 1)].id)
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
    func createNote(title: String = "", body: String = "") -> UUID? {
        guard finishEditing() else { return nil }
        let now = clock()
        var tags: [String] = []
        if case let .tag(tag) = scope { tags = [tag] }
        let note = AskNote(title: title.trimmingCharacters(in: .whitespacesAndNewlines), body: body, command: "",
                           keyword: "", input: "", tags: tags, createdAt: now, updatedAt: now, source: .manual)
        guard store.save(note) else { notice = L("ask.notes.saveFailed"); return nil }
        selecting = false
        picked = []
        switch scope {
        case .all, .recent, .tag, .source(.manual): break
        default: scope = .all
        }
        searchText = ""
        reload()
        selectedID = note.id
        beginEditing()
        return note.id
    }

    /// Holds title edits until they can be saved; navigation shares the body save barrier.
    func stageTitle(_ title: String, id: UUID) {
        guard let note = store.note(id: id), !note.isDeleted else { return }
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
    func savePendingTitle() -> Bool {
        guard let title = pendingTitle, let baseline = titleBaseline else { return true }
        guard let previous = store.note(id: baseline.id), !previous.isDeleted else {
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
        guard next == previous.title || store.save(note, replacing: previous, revisionAt: nil) else {
            notice = L("ask.notes.saveFailed")
            return false
        }
        pendingTitle = nil
        titleBaseline = nil
        draftConflict = false
        reload()
        return true
    }

    /// A new title; an empty one goes back to the default.
    func rename(_ title: String, id: UUID? = nil) {
        guard let id = id ?? selectedID, let previous = store.note(id: id), !previous.isDeleted else { return }
        var note = previous
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = trimmed.isEmpty ? defaultTitle(note) : trimmed
        guard next != note.title else { return }
        note.title = next
        note.updatedAt = clock()
        update(note, replacing: previous)
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
    func setMode(_ mode: Mode) {
        if mode == .read { finishEditing() } else { beginEditing(mode) }
    }

    /// ⌘E: reading and editing.
    func toggleEditing() { setMode(editing ? .read : .edit) }

    /// Returns false when leaving would lose a draft that could not be saved.
    @discardableResult
    func finishEditing() -> Bool {
        guard savePendingTitle() else { return false }
        guard editing else { return true }
        guard saveDraft() else { return false }
        endEditing()
        return true
    }

    /// Leaves editing; whatever was typed is kept (edits save as they are made).
    func cancelEditing() { finishEditing() }

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
            self?.saveDraft()
        }
    }

    /// Writes only against the current version, preserving concurrent metadata edits.
    @discardableResult
    func saveDraft() -> Bool {
        guard savePendingTitle() else { return false }
        guard editing, let baseline = draftBaseline else { return true }
        guard hasUnsavedDraft else { return true }
        guard let previous = store.note(id: baseline.id), !previous.isDeleted,
              previous.body == baseline.body || previous.body == draftBody else {
            draftConflict = true
            notice = L("ask.notes.saveConflict")
            return false
        }
        if draftBody == previous.body {
            draftBaseline = previous
            hasUnsavedDraft = false
            draftConflict = false
            return true
        }
        var note = previous
        let now = clock()
        if note.originalBody == nil, note.source != .manual, note.source != .import { note.originalBody = note.body }
        note.body = draftBody
        note.updatedAt = now
        note.editedAt = now
        note.author = .user
        if note.title.isEmpty { note.title = defaultTitle(note) }
        guard store.save(note, replacing: previous, revisionAt: nil) else {
            notice = L("ask.notes.saveFailed")
            return false
        }
        draftBaseline = note
        hasUnsavedDraft = false
        draftConflict = false
        reload()
        return true
    }

    /// Keeps both versions when the agent changed or deleted the original note.
    func saveDraftCopy() {
        guard let baseline = draftBaseline ?? titleBaseline else { return }
        let now = clock()
        let metadata = store.note(id: baseline.id) ?? baseline
        let title = pendingTitle ?? metadata.title
        let body = editing ? draftBody : metadata.body
        let note = AskNote(title: title, body: body, command: "", keyword: "", input: "",
                           tags: metadata.tags, createdAt: now, updatedAt: now, source: .manual)
        guard store.save(note) else { notice = L("ask.notes.saveFailed"); return }
        pendingTitle = nil
        titleBaseline = nil
        endEditing()
        searchText = ""
        scope = .all
        reload()
        selectedID = note.id
        notice = nil
    }

    func togglePin() {
        guard let id = selectedID, let previous = store.note(id: id), !previous.isDeleted else { return }
        var note = previous
        note.pinned.toggle()
        update(note, replacing: previous)
    }

    func addTag(_ text: String) {
        guard let id = selectedID, let previous = store.note(id: id), !previous.isDeleted,
              let tag = AskNote.normalizedTag(text),
              !previous.tags.contains(where: { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame })
        else { return }
        var note = previous
        note.tags.append(tag)
        note.updatedAt = clock()
        update(note, replacing: previous)
    }

    func removeTag(_ tag: String) {
        guard let id = selectedID, let previous = store.note(id: id), !previous.isDeleted,
              previous.tags.contains(tag) else { return }
        var note = previous
        note.tags.removeAll { $0 == tag }
        note.updatedAt = clock()
        update(note, replacing: previous)
    }

    /// Ticks or clears the `index`th task while reading; only its box changes.
    func toggleTask(_ index: Int) {
        guard !editing, let id = selectedID, let previous = store.note(id: id), !previous.isDeleted,
              let body = AskNoteTasks.toggling(previous.body, task: index) else { return }
        var note = previous
        if note.originalBody == nil, note.source != .manual, note.source != .import { note.originalBody = note.body }
        note.body = body
        note.updatedAt = clock()
        note.editedAt = note.updatedAt
        note.author = .user
        update(note, replacing: previous)
    }

    /// The text the note had before the agent last changed it, when there is one.
    var agentRevision: AskNoteRevision? {
        guard let note = selected, note.author == .agent,
              let revision = store.revisions(of: note.id).first,
              revision.title != note.title || revision.body != note.body else { return nil }
        return revision
    }

    /// Puts back the text from before the agent's last change.
    func revertAgentChange() {
        guard finishEditing(), let id = selectedID, let previous = store.note(id: id), !previous.isDeleted,
              previous.author == .agent, let revision = store.revisions(of: id).first,
              revision.title != previous.title || revision.body != previous.body else { return }
        var note = previous
        note.title = revision.title
        note.body = revision.body
        note.author = .user
        note.editedAt = clock()
        note.updatedAt = clock()
        guard update(note, replacing: previous) else { return }
        store.deleteRevision(of: note.id, at: revision.createdAt)
        notice = L("ask.notes.agentReverted")
    }

    @discardableResult
    private func update(_ note: AskNote, replacing previous: AskNote) -> Bool {
        guard store.save(note, replacing: previous, revisionAt: nil) else {
            notice = L("ask.notes.saveFailed")
            return false
        }
        reload()
        return true
    }

    // MARK: - Deleting

    /// Moves the chosen note to Recently Deleted; in Recently Deleted, removes it for good.
    func deleteSelected() {
        guard finishEditing(), let id = selectedID, let note = store.note(id: id) else { return }
        if note.isDeleted { deleteForever(); return }
        guard trash([note]) else { return }
        notice = L("ask.notes.deleted", note.title.isEmpty ? L("ask.notes.untitled") : note.title)
        noticeOffersUndo = true
    }

    @discardableResult
    private func trash(_ chosen: [AskNote]) -> Bool {
        guard !chosen.isEmpty else { return false }
        let now = clock()
        let index = notes.firstIndex { $0.id == chosen.first?.id } ?? 0
        store.trash(ids: chosen.map(\.id), at: now)
        let removed = chosen.compactMap { store.note(id: $0.id) }.filter(\.isDeleted)
        guard !removed.isEmpty else { notice = L("ask.notes.saveFailed"); return false }
        deleted.append(contentsOf: removed)
        deletedBatches.append(removed.count)
        let gone = Set(removed.map(\.id))
        notes.removeAll { gone.contains($0.id) }
        selectedID = notes.isEmpty ? nil : notes[min(index, notes.count - 1)].id
        reload()
        return true
    }

    /// Takes back the last deletion, whether of one note or of several.
    func undoDelete() {
        guard finishEditing(), !deleted.isEmpty else { return }
        let size = min(deletedBatches.last ?? 1, deleted.count)
        let batch = Array(deleted.suffix(size))
        var restored: [UUID] = []
        for removed in batch {
            // A newer edit or permanent deletion must never be undone by an old snapshot.
            guard let previous = store.note(id: removed.id), previous.isDeleted else { continue }
            var note = previous
            note.deletedAt = nil
            guard update(note, replacing: previous) else { return }
            restored.append(note.id)
        }
        deleted.removeLast(size)
        _ = deletedBatches.popLast()
        reload()
        reveal(restored.last)
        notice = nil
    }

    /// Recently Deleted: puts the chosen note back.
    func restoreFromTrash() {
        guard let previous = selected, previous.isDeleted else { return }
        var note = previous
        note.deletedAt = nil
        guard update(note, replacing: previous) else { return }
        notice = L("ask.notes.restoredFromTrash", note.title)
    }

    /// Recently Deleted: removes the chosen note for good.
    func deleteForever() {
        guard let note = selected, note.isDeleted else { return }
        let index = notes.firstIndex { $0.id == note.id } ?? 0
        store.delete(ids: [note.id])
        notes.removeAll { $0.id == note.id }
        selectedID = notes.isEmpty ? nil : notes[min(index, notes.count - 1)].id
        reload()
    }

    func emptyTrash() {
        let ids = store.list(AskNoteQuery(scope: .trash, limit: Int(Int32.max))).map(\.id)
        store.delete(ids: ids)
        reload()
    }

    // MARK: - Picking several

    func setSelecting(_ enabled: Bool) {
        guard !inTrash || !enabled else { return }
        guard !enabled || finishEditing() else { return }
        selecting = enabled
        picked = enabled ? Set(selectedID.map { [$0] } ?? []) : []
        pickAnchor = enabled ? selectedID : nil
    }

    /// ⌘ click: adds or removes one note.
    func togglePick(_ id: UUID) {
        if !selecting { setSelecting(true) }
        guard selecting else { return }
        if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
        pickAnchor = id
    }

    /// ⇧ click: every note between the last picked one and this one.
    func pickRange(to id: UUID) {
        if !selecting { setSelecting(true) }
        guard selecting, let end = notes.firstIndex(where: { $0.id == id }) else { return }
        let start = pickAnchor.flatMap { anchor in notes.firstIndex { $0.id == anchor } } ?? end
        for note in notes[min(start, end) ... max(start, end)] { picked.insert(note.id) }
    }

    /// ⌘A
    func pickAll() {
        guard !inTrash else { return }
        if !selecting { setSelecting(true) }
        guard selecting else { return }
        picked = Set(notes.map(\.id))
    }

    /// Picked notes in list order.
    var pickedNotes: [AskNote] { notes.filter { picked.contains($0.id) } }

    func pinPicked() {
        let chosen = pickedNotes
        let pin = !chosen.allSatisfy(\.pinned)
        for chosenNote in chosen {
            guard let previous = store.note(id: chosenNote.id), !previous.isDeleted else { continue }
            var note = previous
            note.pinned = pin
            update(note, replacing: previous)
        }
        reload()
    }

    func tagPicked(_ text: String) {
        guard let tag = AskNote.normalizedTag(text) else { return }
        let now = clock()
        for chosen in pickedNotes {
            guard let previous = store.note(id: chosen.id), !previous.isDeleted,
                  !previous.tags.contains(where: { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame })
            else { continue }
            var note = previous
            note.tags.append(tag)
            note.updatedAt = now
            update(note, replacing: previous)
        }
        reload()
    }

    func copyPicked() {
        let chosen = pickedNotes
        guard !chosen.isEmpty else { return }
        copy(AskNoteExporter.merged(chosen))
        notice = L("ask.notes.copiedSeveral", chosen.count)
    }

    func exportPicked() { exportFolder(pickedNotes) }

    func trashPicked() {
        let chosen = pickedNotes
        guard !chosen.isEmpty else { return }
        guard trash(chosen) else { return }
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
    func exportAll() {
        guard saveDraft() else { return }
        exportFolder(store.list(AskNoteQuery(limit: Int(Int32.max))))
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

    func importFiles() { importFiles(chooseImportFiles()) }

    /// Markdown or text files as new notes; the first is chosen.
    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty, finishEditing() else { return }
        let result = AskNoteImporter.notes(from: urls, now: clock())
        let imported = result.notes.filter { store.save($0) }
        let skipped = result.skipped.count + result.notes.count - imported.count
        if !imported.isEmpty {
            selecting = false
            picked = []
            searchText = ""
            if scope != .all, scope != .source(.import) { scope = .all }
            reload()
            selectedID = imported.first?.id
        }
        notice = skipped == 0
            ? L("ask.notes.imported", imported.count)
            : L("ask.notes.importedSkipped", imported.count, skipped)
    }
}
