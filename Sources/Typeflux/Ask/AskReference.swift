import Foundation

struct AskReference: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString
    var messageId: String
    var text: String
    var question = ""
    /// Local notebook source; the text remains a snapshot if the note changes.
    var noteId: UUID? = nil

    var locationId: String { noteId.map { "note:" + $0.uuidString } ?? messageId }

    init(id: String = UUID().uuidString, messageId: String, text: String, question: String = "", noteId: UUID? = nil) {
        self.id = id
        self.messageId = messageId
        self.text = text
        self.question = question
        self.noteId = noteId
    }

    init(note: AskNote) {
        self.init(messageId: note.id.uuidString,
                  text: "# " + note.title + "\n\n" + AskNoteExporter.text(note, options: .init(original: true)),
                  noteId: note.id)
    }
}
