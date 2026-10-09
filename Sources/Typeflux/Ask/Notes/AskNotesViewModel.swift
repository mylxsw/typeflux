import AppKit
import Foundation

/// The notes window's state: the shelf and search, the list, the chosen note and its edits.
@MainActor
final class AskNotesViewModel: ObservableObject {
    @Published var scope: AskNoteQuery.Scope = .all { didSet { if scope != oldValue { reload() } } }
    @Published var searchText = "" { didSet { if searchText != oldValue { reload() } } }
    @Published var sort: AskNoteQuery.Sort = .updated { didSet { if sort != oldValue { reload() } } }
    @Published private(set) var notes: [AskNote] = []
    @Published private(set) var commands: [AskNoteFacet] = []
    @Published private(set) var tags: [AskNoteFacet] = []
    @Published private(set) var counts: [AskNoteQuery.Scope: Int] = [:]
    @Published var selectedID: UUID?
    /// The chosen note's text is being edited; `draftBody` holds the edit until it is saved.
    @Published private(set) var editing = false
    @Published var draftBody = ""
    /// Deleted notes, newest last, for undo.
    @Published private(set) var deleted: [AskNote] = []
    /// A short message at the bottom of the window.
    @Published var notice: String? { didSet { noticeOffersUndo = false } }
    /// The message is about a deletion, so it offers undo.
    @Published private(set) var noticeOffersUndo = false

    let store: any AskNoteStoring
    var openInWindow: @MainActor (AskNote) -> Void = { AskResultWindowController.shared.open($0) }
    var askAI: (@MainActor (String) -> Void)?
    var copy: @MainActor (String) -> Void = { AskQuickResults.copy($0) }
    var copyRich: @MainActor (String) -> Void = { AskRichCopy.copy($0) }
    var chooseExportURL: @MainActor (String) -> URL? = { name in
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
    var clock: () -> Date = Date.init
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
    }

    var selected: AskNote? { notes.first { $0.id == selectedID } }

    /// Reads the list and the sidebar again, keeping the chosen note when it is still listed.
    func reload() {
        notes = store.list(AskNoteQuery(scope: scope, text: searchText, sort: sort))
        commands = store.commands()
        tags = store.tags()
        counts = [.all: store.count(.all), .pinned: store.count(.pinned)]
        // A shelf whose last note went away falls back to all notes.
        switch scope {
        case let .command(name) where !commands.contains(where: { $0.name == name }): scope = .all
        case let .tag(tag) where !tags.contains(where: { $0.name == tag }): scope = .all
        default: break
        }
        if editing, selected == nil { editing = false }
        if selected == nil { selectedID = notes.first?.id }
    }

    /// Shows a note, leaving filters that would hide it.
    func reveal(_ id: UUID?) {
        guard let id, store.note(id: id) != nil else { return }
        if !notes.contains(where: { $0.id == id }) {
            searchText = ""
            scope = .all
        }
        select(id)
    }

    func select(_ id: UUID?) {
        guard id != selectedID else { return }
        if editing { finishEditing() }
        selectedID = id
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
        case let .command(name): name
        case let .tag(tag): "#" + tag
        }
    }

    // MARK: - Editing

    /// A new title; an empty one goes back to the default.
    func rename(_ title: String) {
        guard var note = selected else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = trimmed.isEmpty ? AskNote.title(command: note.command, input: note.input, body: note.body) : trimmed
        guard next != note.title else { return }
        note.title = next
        note.updatedAt = clock()
        update(note)
    }

    func beginEditing() {
        guard let note = selected else { return }
        draftBody = note.body
        editing = true
    }

    /// Saves the edit when it changed anything, and leaves editing.
    func finishEditing() {
        guard editing else { return }
        editing = false
        guard var note = selected, draftBody != note.body else { return }
        let now = clock()
        note.body = draftBody
        note.updatedAt = now
        note.editedAt = now
        update(note)
    }

    func cancelEditing() {
        editing = false
        draftBody = selected?.body ?? ""
    }

    func togglePin() {
        guard var note = selected else { return }
        note.pinned.toggle()
        update(note)
    }

    func addTag(_ text: String) {
        guard var note = selected, let tag = AskNote.normalizedTag(text), !note.tags.contains(tag) else { return }
        note.tags.append(tag)
        note.updatedAt = clock()
        update(note)
    }

    func removeTag(_ tag: String) {
        guard var note = selected, note.tags.contains(tag) else { return }
        note.tags.removeAll { $0 == tag }
        note.updatedAt = clock()
        update(note)
    }

    private func update(_ note: AskNote) {
        store.save(note)
        if let index = notes.firstIndex(where: { $0.id == note.id }) { notes[index] = note }
        reload()
    }

    // MARK: - Deleting

    func deleteSelected() {
        guard let note = selected else { return }
        editing = false
        let index = notes.firstIndex { $0.id == note.id } ?? 0
        store.delete(ids: [note.id])
        deleted.append(note)
        notes.removeAll { $0.id == note.id }
        selectedID = notes.isEmpty ? nil : notes[min(index, notes.count - 1)].id
        reload()
        notice = L("ask.notes.deleted", note.title)
        noticeOffersUndo = true
    }

    func undoDelete() {
        guard let note = deleted.popLast() else { return }
        store.restore([note])
        reload()
        reveal(note.id)
        notice = nil
    }

    // MARK: - Using a note

    func copySelected() {
        guard let note = selected else { return }
        copy(note.body)
        notice = L("ask.plugin.copied")
    }

    func copySelectedRich() {
        guard let note = selected else { return }
        copyRich(note.body)
        notice = L("ask.plugin.copiedRich")
    }

    func askAIAboutSelected() {
        guard let note = selected, let askAI else { return }
        askAI(L("ask.plugin.prompt.askAI", note.command, note.input, note.body))
    }

    func openSelectedInWindow() {
        guard let note = selected else { return }
        openInWindow(note)
    }

    func exportSelected() {
        guard let note = selected, let url = chooseExportURL(AskNoteExporter.fileName(note)) else { return }
        do {
            try AskNoteExporter.markdown(note).write(to: url, atomically: true, encoding: .utf8)
            notice = L("ask.notes.exported", url.lastPathComponent)
        } catch {
            notice = error.localizedDescription
        }
    }
}
