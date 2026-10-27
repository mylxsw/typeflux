import Foundation

/// Process-local capture state. A failed submission retains its exact note and UUID for retry.
struct AskNoteCaptureState: Sendable {
    var body = ""
    var submission: AskNote?
    var saved: AskNote?
    var failure: String?
    var saving = false
    var resumeKeyword: AskKeyword?
    let generation = UUID()
    var target: AskNote?
    var submissionBase: AskNote?
    var choosingTarget = false
    var targetQuery = ""
    var matches: [AskNote] = []
    var highlightedTarget = 0
    var searching = false
    var searchFailure: String?
    var searchID = UUID()
    var requiresReview = false
    var savedWasAppend = false
    var undo: Undo?
    var undone = false

    struct Undo: Sendable {
        var before: AskNote?
        var after: AskNote
    }

    var hasContent: Bool {
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canSave: Bool {
        hasContent && !saving && !choosingTarget && !requiresReview
    }

    var panelHeight: CGFloat {
        let content: CGFloat = choosingTarget ? 340 : target != nil ? 300 : 190
        return content + (failure == nil ? 0 : 42)
    }

    var actionTitleKey: String {
        if saving {
            return "ask.noteCapture.working"
        }
        if choosingTarget {
            return "ask.noteCapture.select"
        }
        return target == nil ? "ask.noteCapture.save" : "ask.noteCapture.appendSave"
    }

    var actionEnabled: Bool {
        choosingTarget ? !saving && !searching && highlighted != nil : canSave
    }

    var highlighted: AskNote? {
        matches.indices.contains(highlightedTarget) ? matches[highlightedTarget] : nil
    }

    mutating func selectTarget(_ note: AskNote?) {
        guard !saving else { return }
        target = note
        submission = nil
        submissionBase = nil
        requiresReview = false
        failure = nil
        choosingTarget = false
        matches = []
        searching = false
        searchID = UUID()
    }

    mutating func update(_ text: String) {
        guard !saving, body != text else { return }
        body = text
        submission = nil
        submissionBase = nil
        failure = nil
        undone = false
    }

    static func title(for body: String) -> String {
        let line = body.components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let plain = AskNote.oneLine(AskNote.plainText(line))
        return plain.isEmpty ? L("ask.noteCapture.untitled") : AskNote.title(command: "", input: plain)
    }

    mutating func begin(at date: Date) -> AskNote? {
        guard canSave else { return nil }
        let note: AskNote
        if let submission {
            note = submission
        } else if var existing = target {
            guard !existing.isDeleted else { return nil }
            submissionBase = existing
            if existing.originalBody == nil, existing.source != .manual, existing.source != .import {
                existing.originalBody = existing.body
            }
            existing.body = Self.appending(body, to: existing.body)
            existing.updatedAt = date
            existing.editedAt = date
            existing.author = .user
            note = existing
        } else {
            note = AskNote(title: Self.title(for: body), body: body, command: "", keyword: "", input: "",
                           createdAt: date, updatedAt: date, source: .manual, author: .user)
        }
        submission = note
        failure = nil
        saving = true
        return note
    }

    mutating func complete(_ note: AskNote, failure: String?) {
        saving = false
        self.failure = failure
        guard failure == nil else { return }
        savedWasAppend = submissionBase != nil
        undo = submission?.body == note.body && submission?.title == note.title
            ? Undo(before: submissionBase, after: note) : nil
        saved = note
        body = ""
        submission = nil
        submissionBase = nil
        target = nil
        requiresReview = false
        undone = false
    }

    /// Preserve the addition verbatim; separators are outside the submitted text.
    static func appending(_ addition: String, to body: String) -> String {
        guard !body.isEmpty else { return addition }
        let separator = body.hasSuffix("\n\n") ? "" : body.hasSuffix("\n") ? "\n" : "\n\n"
        return body + separator + addition
    }
}
