import Foundation

/// The explicit capture boundary: append and its revision commit together, against the reviewed snapshot.
struct AskNoteCaptureWriter: Sendable {
    enum Failure: Error { case missing, conflict, saveFailed }
    var store: any AskNoteStoring

    func save(_ note: AskNote, replacing before: AskNote?, retrying: Bool) async throws -> AskNote {
        if let before {
            guard let current = try await store.note(id: note.id), !current.isDeleted else { throw Failure.missing }
            // A retry after an uncertain commit must never append twice, including when only tags changed afterwards.
            if retrying, current.body == note.body, current.title == note.title {
                return current
            }
            guard try await store.save(note, replacing: before, revisionAt: note.updatedAt)
            else { throw Failure.conflict }
        } else if retrying, let existing = try await store.note(id: note.id) {
            guard !existing.isDeleted else { throw Failure.missing }
            return existing
        } else {
            guard try await store.save(note) else { throw Failure.saveFailed }
        }
        return note
    }

    func undo(_ receipt: AskNoteCaptureState.Undo, at date: Date) async throws {
        guard let current = try await store.note(id: receipt.after.id) else { throw Failure.conflict }
        if receipt.before == nil, current.isDeleted {
            return
        }
        if let before = receipt.before, !current.isDeleted, current.body == before.body,
           current.title == before.title, current.originalBody == before.originalBody {
            return
        }
        var replacement = receipt.after
        if receipt.before == nil {
            replacement.deletedAt = date
        } else if let before = receipt.before {
            replacement.body = before.body
            replacement.originalBody = before.originalBody
            replacement.updatedAt = date
            replacement.editedAt = date
            replacement.author = .user
        }
        guard try await store.save(replacement, replacing: receipt.after, revisionAt: nil)
        else { throw Failure.conflict }
    }
}
