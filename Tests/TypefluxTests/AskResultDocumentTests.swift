import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Typeflux

/// Records what a result window asked the rest of the app to do.
@MainActor
final class AskResultServicesRecorder {
    var saved: [AskNoteDraft] = []
    var removed: [UUID] = []
    var existing: Set<UUID> = []
    var keepsEdited = false
    var openedNotes: [UUID?] = []
    var inserted: [(String, String?)] = []
    var insertSucceeds = true
    var copied: [String] = []
    var copiedRich: [String] = []
    var asked: [String] = []
    var running: Set<String> = ["com.apple.Notes"]

    var services: AskResultDocument.Services {
        AskResultDocument.Services(
            saveNote: { [self] draft in
                saved.append(draft)
                let id = UUID()
                existing.insert(id)
                return id
            },
            removeNote: { [self] id in
                guard !keepsEdited else { return false }
                removed.append(id)
                existing.remove(id)
                return true
            },
            noteExists: { [self] in existing.contains($0) },
            openNotes: { [self] in openedNotes.append($0) },
            insert: { [self] text, bundle in
                inserted.append((text, bundle))
                return insertSucceeds
            },
            copy: { [self] in copied.append($0) },
            copyRich: { [self] in copiedRich.append($0) },
            askAI: { [self] in asked.append($0) },
            isRunning: { [self] in running.contains($0) }
        )
    }
}

@Suite("Ask result windows", .exclusiveUIState)
@MainActor
struct AskResultDocumentTests {
    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 1000 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }

    private func document(_ recorder: AskResultServicesRecorder, state: AskResultDocument.State = .done,
                          body: String = "Result",
                          regenerate: AskResultDocument.Regenerate? = nil) -> AskResultDocument {
        AskResultDocument(title: "Explain", keyword: "ex", model: "gpt-test", input: "Input", body: body, state: state,
                          sourceApp: "Notes", sourceBundleID: "com.apple.Notes", regenerate: regenerate,
                          services: recorder.services)
    }

    private func output(_ body: String) -> AskPluginOutput {
        AskPluginOutput(body: body, original: "Input", meta: [], source: "AI", actions: [])
    }

    @Test func streamingResultsArriveAndFinish() {
        let recorder = AskResultServicesRecorder()
        let doc = document(recorder, state: .streaming, body: "")
        var cancelled = 0
        doc.adopt { cancelled += 1 }
        #expect(doc.isStreaming && !doc.canInsert && !doc.canRegenerate)
        doc.receive(.progress(output("Hel")))
        #expect(doc.body == "Hel")
        doc.toggleNote()
        #expect(doc.savesWhenDone && doc.notice == L("ask.notes.saveWhenDone"))
        doc.receive(.done(output("Hello")))
        #expect(doc.state == .done && doc.body == "Hello" && !doc.savesWhenDone)
        #expect(recorder.saved.map(\.body) == ["Hello"], "⌘S while streaming saves once done")
        #expect(doc.noteID != nil && doc.notice == L("ask.notes.saved"))
        doc.stop()
        #expect(cancelled == 0, "a finished run has nothing to stop")
    }

    @Test func failuresStopsAndCancellations() {
        let recorder = AskResultServicesRecorder()
        let failing = document(recorder, state: .streaming, body: "")
        failing.receive(.failed(AskPluginFailure(message: "boom")))
        #expect(failing.state == .failed("boom"))
        let stopped = document(recorder, state: .streaming, body: "Part")
        var cancelled = 0
        stopped.adopt { cancelled += 1 }
        stopped.toggleNote()
        stopped.stop()
        #expect(cancelled == 1 && stopped.state == .done && stopped.body == "Part" && !stopped.savesWhenDone)
        stopped.receive(.progress(output("Late")))
        #expect(stopped.body == "Part", "text still in flight after stopping is dropped")
        let empty = document(recorder, state: .streaming, body: "")
        empty.close()
        #expect(empty.state == .failed(L("ask.result.stopped")))
        let cancelledRun = document(recorder, state: .streaming, body: "")
        cancelledRun.receive(.cancelled)
        #expect(cancelledRun.state == .failed(L("ask.result.stopped")))
        let partial = document(recorder, state: .streaming, body: "Some")
        partial.receive(.cancelled)
        #expect(partial.state == .done)
    }

    @Test func savingRemovingAndKeepingEditedNotes() {
        let recorder = AskResultServicesRecorder()
        let doc = document(recorder)
        doc.toggleNote()
        let id = try? #require(doc.noteID)
        #expect(recorder.saved.first == AskNoteDraft(command: "Explain", keyword: "ex", input: "Input", body: "Result",
                                                      model: "gpt-test", sourceApp: "Notes",
                                                      sourceBundleID: "com.apple.Notes"))
        recorder.keepsEdited = true
        doc.toggleNote()
        #expect(doc.noteID == id && doc.notice == L("ask.notes.editedKept"))
        recorder.keepsEdited = false
        doc.toggleNote()
        #expect(doc.noteID == nil && recorder.removed == [id].compactMap { $0 } && doc.notice == L("ask.notes.removed"))
        doc.toggleNote()
        let again = doc.noteID
        recorder.existing.removeAll()
        doc.refreshNote()
        #expect(again != nil && doc.noteID == nil, "a note deleted in the notes window clears the star")
        doc.toggleNote()
        #expect(recorder.saved.count == 3, "a gone note saves anew")
        let blank = document(recorder, body: "  ")
        blank.toggleNote()
        #expect(blank.noteID == nil && recorder.saved.count == 3)
    }

    @Test func copyingInsertingAskingAndOpeningNotes() async throws {
        let recorder = AskResultServicesRecorder()
        let doc = document(recorder)
        doc.copy()
        doc.copyRich()
        doc.askAI()
        doc.openNotes()
        #expect(recorder.copied == ["Result"] && recorder.copiedRich == ["Result"] && doc.notice == L("ask.plugin.copiedRich"))
        #expect(recorder.asked == [L("ask.plugin.prompt.askAI", "Explain", "Input", "Result")])
        #expect(recorder.openedNotes == [nil])
        #expect(doc.canInsert)
        doc.insert()
        try await settle { recorder.inserted.count == 1 }
        #expect(recorder.inserted.first?.0 == "Result" && recorder.inserted.first?.1 == "com.apple.Notes")
        recorder.insertSucceeds = false
        doc.insert()
        try await settle { recorder.copied.count == 2 }
        #expect(doc.notice == L("ask.plugin.writeBack.failed"), "a failed insert copies instead")
        recorder.running = []
        #expect(!doc.canInsert, "the source app quit")
        doc.insert()
        #expect(recorder.inserted.count == 2)
        try await settle { doc.notice == nil }
    }

    @Test func regeneratingStreamsANewResult() async throws {
        let recorder = AskResultServicesRecorder()
        var runs = 0
        var fails = false
        let doc = document(recorder, regenerate: { progress in
            runs += 1
            if fails { throw AskPluginFailure(message: "nope") }
            try await Task.sleep(for: .milliseconds(20))
            progress("New")
            return "New result"
        })
        doc.toggleNote()
        #expect(doc.noteID != nil && doc.canRegenerate)
        doc.regenerate()
        #expect(doc.isStreaming && doc.dimmed && doc.noteID == nil, "the old result dims; the new one is not saved")
        try await settle { doc.state == .done }
        #expect(doc.body == "New result" && !doc.dimmed && runs == 1)
        fails = true
        doc.regenerate()
        try await settle { doc.state == .failed("nope") }
        let none = document(recorder)
        none.regenerate()
        #expect(none.state == .done && !none.canRegenerate)
        fails = false
        doc.regenerate()
        doc.stop()
        #expect(doc.state == .done, "stopping keeps what had arrived")
    }

    @Test func notesOpenReadOnlyAndLinkBack() {
        let recorder = AskResultServicesRecorder()
        let note = makeTestNote()
        recorder.existing.insert(note.id)
        let doc = AskResultDocument(note: note, services: recorder.services)
        #expect(doc.fromNote && doc.noteID == note.id && doc.body == note.body && doc.title == note.command)
        #expect(doc.updatedAt == note.updatedAt && !doc.canRegenerate)
        doc.openNotes()
        #expect(recorder.openedNotes == [note.id])
    }

    @Test func aHandoffBecomesADocument() async throws {
        let recorder = AskResultServicesRecorder()
        let generator = AskTestTextGenerator()
        generator.pieces = ["Again"]
        let plugin = AskPromptPlugin(generator: generator, modelName: { "m" })
        let request = AskPluginRequest(text: "teh", origin: .argument, keyword: AskPromptPlugin.keywords[0],
                                       options: [AskPromptPlugin.presetOption: "polish"], interfaceLanguage: .english)
        let plan = await plugin.plan(request)
        let note = UUID()
        let done = AskResultDocument(
            handoff: AskPluginHandoff(plugin: plugin, plan: plan, request: request, output: output("The"), running: false,
                                      cancel: {}),
            model: "m", sourceApp: "Mail", sourceBundleID: "com.apple.mail", noteID: note, services: recorder.services)
        #expect(done.title == plan.values[AskPromptPlugin.titleOption] && done.keyword == "rw" && done.input == "teh")
        #expect(done.state == .done && done.body == "The" && done.noteID == note && done.sourceApp == "Mail")
        done.regenerate()
        try await settle { done.body == "Again" && done.state == .done }
        var cancelled = 0
        let running = AskResultDocument(
            handoff: AskPluginHandoff(plugin: plugin, plan: plan, request: request, output: nil, running: true,
                                      cancel: { cancelled += 1 }),
            model: nil, sourceApp: nil, sourceBundleID: nil, noteID: note, services: recorder.services)
        #expect(running.isStreaming && running.body.isEmpty && running.noteID == nil)
        running.close()
        #expect(cancelled == 1)
    }

    @Test func windowsOpenCascadeAndRememberTheirSize() throws {
        let controller = AskResultWindowController()
        let suite = "ask.result.window.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        controller.defaults = defaults
        let recorder = AskResultServicesRecorder()
        controller.services = recorder.services
        // Runs before the domain is removed, so a close that saves a size cannot outlive it,
        // and on every exit, including a failed `#require` after windows are open.
        defer { for window in NSApp.windows where window.delegate === controller { window.close() } }
        let first = document(recorder)
        controller.present(first)
        let second = controller.open(makeTestNote())
        #expect(controller.documents.count == 2)
        #expect(controller.open(makeTestNote()) !== second, "another note opens its own window")
        let note = makeTestNote()
        let shown = controller.open(note)
        #expect(controller.open(note) === shown, "the same note comes forward instead of opening twice")
        first.pinned = true
        let windows = NSApp.windows.filter { ($0.contentView as? NSHostingView<AskResultWindowView>) != nil }
        #expect(windows.contains { $0.level == .floating })
        // A saved height the display can hold, so AppKit does not shrink the window to fit.
        let visible = try #require(NSScreen.main?.visibleFrame)
        let savedHeight = min(700, (visible.height - 100).rounded(.down))
        #expect(savedHeight > AskResultWindowController.minimumSize.height)
        defaults.set(NSStringFromSize(NSSize(width: 100, height: savedHeight)),
                     forKey: AskResultWindowController.sizeKey)
        let third = document(recorder)
        controller.present(third)
        let sized = NSApp.windows.first { window in
            window.delegate === controller
                && (window.contentView as? NSHostingView<AskResultWindowView>)?.rootView.document === third
        }
        #expect(sized?.frame.width ?? 0 >= AskResultWindowController.minimumSize.width, "too small a size is widened")
        #expect(sized?.frame.height == savedHeight, "the saved height is remembered")
        for window in NSApp.windows where window.delegate === controller { window.close() }
        #expect(controller.documents.isEmpty)
    }
}
