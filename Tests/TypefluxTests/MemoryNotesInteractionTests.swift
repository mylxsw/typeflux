import AppKit
import SwiftUI
@testable import Typeflux
import XCTest

@MainActor
final class MemoryNotesInteractionTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testInlineCorrectionRetriesAndPersistsLineage() async throws {
        let storage = FailingMemoryNoteFileStorage()
        let store = AskMemoryNoteStore(fileURL: directory.appendingPathComponent("notes.json"), storage: storage)
        let note = try store.add("Uses imperial units", owner: "a")
        let model = AskMemoryNotesSettingsModel()
        model.reload(from: store, owner: "a")
        let (window, host) = show(MemoryNotesEditorView(model: model, store: store, owner: "a", correctionsEnabled: true))
        defer { window.close() }

        model.beginEditing(note)
        XCTAssertEqual(model.draft?.text, note.text)
        XCTAssertFalse(model.draft?.canSave ?? true, "An unchanged note cannot be saved")
        model.draft?.text = "Uses metric units"
        try await settle(host)

        storage.failure = .write
        XCTAssertFalse(model.saveDraft(to: store, owner: "a"))
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.notes, [note])
        XCTAssertNotNil(model.draft, "A failed save keeps the editor open")

        storage.failure = nil
        XCTAssertTrue(model.saveDraft(to: store, owner: "a"))
        XCTAssertNil(model.error)
        XCTAssertNil(model.draft)
        XCTAssertEqual(model.notes.first?.text, "Uses metric units")
        XCTAssertEqual(model.notes.first?.provenance?.supersedes, note.id)
        try await settle(host)
        snapshot(host, name: "memory-corrected-note.png")

        let reopened = AskMemoryNoteStore(fileURL: directory.appendingPathComponent("notes.json"))
        XCTAssertEqual(reopened.list(owner: "a").first?.text, "Uses metric units")
        XCTAssertEqual(reopened.list(owner: "a").first?.provenance?.supersedes, note.id)
    }

    func testAddingNotesWithRetentionAndCancelling() async throws {
        let store = AskMemoryNoteStore(fileURL: directory.appendingPathComponent("notes.json"))
        let model = AskMemoryNotesSettingsModel()
        model.reload(from: store, owner: "a")
        let (window, host) = show(MemoryNotesEditorView(model: model, store: store, owner: "a"))
        defer { window.close() }
        try await settle(host)

        model.beginAdding()
        XCTAssertNil(model.draft?.note)
        XCTAssertEqual(model.draft?.retention, .forever)
        XCTAssertFalse(model.draft?.canSave ?? true, "An empty note cannot be saved")
        model.draft?.text = String(repeating: "x", count: AskMemoryNoteStore.maximumNoteLength + 1)
        XCTAssertFalse(model.draft?.canSave ?? true, "An over-long note cannot be saved")
        model.cancelEditing()
        XCTAssertNil(model.draft)
        XCTAssertTrue(store.list(owner: "a").isEmpty)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        model.beginAdding()
        model.draft?.text = "  Replies in Chinese  "
        model.draft?.retention = .days(7)
        try await settle(host)
        XCTAssertTrue(model.saveDraft(to: store, owner: "a", now: now))
        let saved = try XCTUnwrap(store.list(owner: "a", at: now).first)
        XCTAssertEqual(saved.text, "Replies in Chinese")
        XCTAssertEqual(saved.provenance?.expiry, now.addingTimeInterval(7 * 86400))
        XCTAssertFalse(model.saveDraft(to: store, owner: "a"), "Nothing to save once the draft closed")
    }

    func testRemovalCanBeUndone() async throws {
        let store = AskMemoryNoteStore(fileURL: directory.appendingPathComponent("notes.json"))
        let now = Date()
        let note = try store.add("Prefers dark mode", owner: "a", now: now, expiry: now.addingTimeInterval(86400))
        let model = AskMemoryNotesSettingsModel()
        model.reload(from: store, owner: "a")
        let (window, host) = show(MemoryNotesEditorView(model: model, store: store, owner: "a"))
        defer { window.close() }

        model.beginEditing(note)
        model.remove(note, from: store, owner: "a")
        XCTAssertNil(model.draft, "Removing the note being edited closes its editor")
        XCTAssertTrue(model.notes.isEmpty)
        XCTAssertEqual(model.recentlyRemoved, note)
        try await settle(host)

        model.undoRemove(to: store, owner: "a", now: now)
        XCTAssertNil(model.recentlyRemoved)
        XCTAssertEqual(model.notes.map(\.text), ["Prefers dark mode"])
        XCTAssertEqual(model.notes.first?.provenance?.expiry, note.provenance?.expiry)

        model.remove(try XCTUnwrap(model.notes.first), from: store, owner: "a")
        model.dismissUndo()
        model.undoRemove(to: store, owner: "a")
        XCTAssertTrue(model.notes.isEmpty, "Undo does nothing once dismissed")
    }

    func testRetentionExpiry() {
        let now = Date(timeIntervalSince1970: 1_000)
        let expiry = Date(timeIntervalSince1970: 9_000)
        let note = AskMemoryNote(id: "n", text: "t", createdAt: now,
                                 provenance: .init(id: "n", source: .explicit, owner: "a", scope: "account",
                                                   createdAt: now, updatedAt: now, expiry: expiry))
        XCTAssertEqual(AskMemoryNotesSettingsModel.Retention.keep.expiry(for: note, now: now), expiry)
        XCTAssertNil(AskMemoryNotesSettingsModel.Retention.keep.expiry(for: nil, now: now))
        XCTAssertNil(AskMemoryNotesSettingsModel.Retention.forever.expiry(for: note, now: now))
        XCTAssertEqual(AskMemoryNotesSettingsModel.Retention.days(30).expiry(for: note, now: now),
                       now.addingTimeInterval(30 * 86400))
        XCTAssertTrue(MemoryNotesEditorView.provenance(note).contains(L("agent.memory.explicit")))
        var corrected = note
        corrected.provenance?.source = .correction
        corrected.provenance?.expiry = nil
        XCTAssertTrue(MemoryNotesEditorView.provenance(corrected).contains(L("agent.memory.corrected")))
        XCTAssertTrue(MemoryNotesEditorView.provenance(corrected).contains(L("memory.forever")))
    }

    private func show(_ view: MemoryNotesEditorView) -> (NSWindow, NSView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 760, height: 520),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: view
            .padding(24).frame(width: 760, height: 520, alignment: .topLeading).background(ModelVisualStyle.canvas))
        window.contentView = host
        window.orderFront(nil)
        return (window, host)
    }

    private func settle(_ host: NSView) async throws {
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }

    private func snapshot(_ view: NSView, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_MEMORY_NOTES_SNAPSHOTS"],
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }
}
