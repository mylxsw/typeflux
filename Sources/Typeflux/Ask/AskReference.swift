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

    /// Another conversation's transcript, so a new chat or task can carry on from it.
    /// User and assistant text only, newest kept, bounded well inside the reference limit.
    init(conversation: AskConversation, limit: Int = 16000) {
        var lines: [String] = []
        var used = 0
        for message in conversation.messages.reversed() where ["user", "assistant"].contains(message.role) {
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let line = (message.role == "user" ? "User: " : "Assistant: ") + text
            guard used + line.utf8.count <= limit else { break }
            lines.insert(line, at: 0)
            used += line.utf8.count + 2
        }
        self.init(messageId: conversation.id, text: "# " + conversation.title + "\n\n" + lines.joined(separator: "\n\n"))
    }

    init(note: AskNote) {
        self.init(messageId: note.id.uuidString,
                  text: "# " + note.title + "\n\n" + AskNoteExporter.text(note, options: .init(original: true)),
                  noteId: note.id)
    }
}
