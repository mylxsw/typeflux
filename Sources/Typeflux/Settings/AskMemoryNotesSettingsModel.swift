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

    func remove(_ note: AskMemoryNote, from store: AskMemoryNoteStore, owner: String) {
        do {
            _ = try store.remove(id: note.id, owner: owner)
            reload(from: store, owner: owner)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
