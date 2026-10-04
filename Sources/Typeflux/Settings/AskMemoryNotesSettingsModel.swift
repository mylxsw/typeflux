import Combine
import Foundation

/// Keeps a failed deletion visible and lets the user retry it from settings.
@MainActor
final class AskMemoryNotesSettingsModel: ObservableObject {
    @Published private(set) var notes: [AskMemoryNote] = []
    @Published private(set) var error: String?

    func reload(from store: AskMemoryNoteStore, owner: String) {
        notes = store.list(owner: owner)
        error = nil
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
            reload(from: store, owner: owner)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
