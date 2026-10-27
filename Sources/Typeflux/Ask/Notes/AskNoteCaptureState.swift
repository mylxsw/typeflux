import Foundation

/// Process-local capture state. A failed submission retains its exact note and UUID for retry.
struct AskNoteCaptureState {
    var body = ""
    var submission: AskNote?
    var saved: AskNote?
    var failure: String?
    var saving = false
    var resumeKeyword: AskKeyword?
    let generation = UUID()

    var hasContent: Bool {
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    mutating func update(_ text: String) {
        guard !saving, body != text else { return }
        body = text
        submission = nil
        failure = nil
    }

    static func title(for body: String) -> String {
        let line = body.components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let plain = AskNote.oneLine(AskNote.plainText(line))
        return plain.isEmpty ? L("ask.noteCapture.untitled") : AskNote.title(command: "", input: plain)
    }

    mutating func begin(at date: Date) -> AskNote? {
        guard !saving, hasContent else { return nil }
        let note = submission ?? AskNote(title: Self.title(for: body), body: body, command: "", keyword: "", input: "",
                                         createdAt: date, updatedAt: date, source: .manual, author: .user)
        submission = note
        failure = nil
        saving = true
        return note
    }

    mutating func complete(_ note: AskNote, failure: String?) {
        saving = false
        self.failure = failure
        guard failure == nil else { return }
        saved = note
        body = ""
        submission = nil
    }
}
