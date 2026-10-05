import Combine
import Foundation

/// Keeps a failed deletion visible and lets the user retry it from settings.
@MainActor
final class AskMemoryNotesSettingsModel: ObservableObject {
    /// How long a correction keeps the note: unchanged, until deleted, or a number of days.
    enum Retention: Hashable {
        case keep
        case forever
        case days(Int)

        func expiry(for note: AskMemoryNote?, now: Date = Date()) -> Date? {
            switch self {
            case .keep: note?.provenance?.expiry
            case .forever: nil
            case let .days(days): now.addingTimeInterval(Double(days) * 86400)
            }
        }
    }

    /// The inline editor: a note being corrected, or a new note when `note` is nil.
    struct Draft: Equatable {
        var note: AskMemoryNote?
        var text: String
        var retention: Retention = .keep

        var canSave: Bool {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && trimmed.count <= AskMemoryNoteStore.maximumNoteLength
                && trimmed != note?.text
        }
    }

    @Published private(set) var notes: [AskMemoryNote] = []
    @Published private(set) var error: String?
    @Published var draft: Draft?
    /// The note removed last; settings offer to bring it back for a few seconds.
    @Published private(set) var recentlyRemoved: AskMemoryNote?

    func reload(from store: AskMemoryNoteStore, owner: String) {
        notes = store.list(owner: owner)
        error = nil
    }

    func beginEditing(_ note: AskMemoryNote) {
        error = nil
        draft = Draft(note: note, text: note.text)
    }

    func beginAdding() {
        error = nil
        draft = Draft(note: nil, text: "", retention: .forever)
    }

    func cancelEditing() {
        draft = nil
        error = nil
    }

    /// Saves the open draft; it stays open with an error when the store rejects it.
    @discardableResult
    func saveDraft(to store: AskMemoryNoteStore, owner: String, now: Date = Date()) -> Bool {
        guard let draft, draft.canSave else { return false }
        let saved: Bool = if let note = draft.note {
            correct(note, text: draft.text, expiry: draft.retention.expiry(for: note, now: now), from: store, owner: owner)
        } else {
            add(draft.text, expiry: draft.retention.expiry(for: nil, now: now), to: store, owner: owner, now: now)
        }
        if saved { self.draft = nil }
        return saved
    }

    @discardableResult
    func add(_ text: String, expiry: Date? = nil, to store: AskMemoryNoteStore, owner: String, now: Date = Date()) -> Bool {
        do {
            _ = try store.add(text, owner: owner, now: now, expiry: expiry)
            reload(from: store, owner: owner)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func correct(_ note: AskMemoryNote, text: String, expiry: Date?, from store: AskMemoryNoteStore, owner: String) -> Bool {
        do {
            _ = try store.correct(id: note.id, text: text, owner: owner,
                                  expectedVersion: note.provenance?.version ?? 1, expiry: expiry)
            reload(from: store, owner: owner)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func remove(_ note: AskMemoryNote, from store: AskMemoryNoteStore, owner: String) {
        do {
            _ = try store.remove(id: note.id, owner: owner)
            if draft?.note?.id == note.id { draft = nil }
            reload(from: store, owner: owner)
            recentlyRemoved = note
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Saves the removed text again as a new note; the deletion itself already stopped its use.
    func undoRemove(to store: AskMemoryNoteStore, owner: String, now: Date = Date()) {
        guard let note = recentlyRemoved else { return }
        recentlyRemoved = nil
        let expiry = note.provenance?.expiry.flatMap { $0 > now ? $0 : nil }
        add(note.text, expiry: expiry, to: store, owner: owner, now: now)
    }

    func dismissUndo() {
        recentlyRemoved = nil
    }
}
