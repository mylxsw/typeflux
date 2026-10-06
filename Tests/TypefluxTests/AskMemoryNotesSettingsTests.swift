import AppKit
import SwiftUI
@testable import Typeflux
import XCTest

@MainActor
final class AskMemoryNotesSettingsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ask-notes-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testFailedRemovalKeepsVisibleNotesAndReportsErrorUntilRetrySucceeds() throws {
        let file = root.appendingPathComponent("notes.json")
        let storage = FailingMemoryNoteFileStorage()
        let store = AskMemoryNoteStore(fileURL: file, storage: storage)
        let note = try store.add("Prefers dark mode", owner: "a")
        let other = try store.add("Other account", owner: "b")
        let model = AskMemoryNotesSettingsModel()
        model.reload(from: store, owner: "a")
        XCTAssertEqual(model.notes, [note])
        XCTAssertNil(model.error)

        for failure in FailingMemoryNoteFileStorage.Failure.allCases {
            storage.failure = failure
            model.remove(note, from: store, owner: "a")
            XCTAssertEqual(model.notes, [note])
            XCTAssertEqual(model.error, failure.localizedDescription)
            XCTAssertEqual(AskMemoryNoteStore(fileURL: file).list(owner: "a"), [note])
        }

        storage.failure = nil
        model.remove(note, from: store, owner: "a")
        XCTAssertTrue(model.notes.isEmpty)
        XCTAssertNil(model.error)
        XCTAssertTrue(AskMemoryNoteStore(fileURL: file).list(owner: "a").isEmpty)
        XCTAssertEqual(store.list(owner: "b"), [other])
    }

    func testReloadForAnotherOwnerResetsTheRemovalError() throws {
        let storage = FailingMemoryNoteFileStorage()
        let store = AskMemoryNoteStore(fileURL: root.appendingPathComponent("notes.json"), storage: storage)
        let note = try store.add("First account", owner: "a")
        let other = try store.add("Other account", owner: "b")
        let model = AskMemoryNotesSettingsModel()
        model.reload(from: store, owner: "a")
        storage.failure = .replace
        model.remove(note, from: store, owner: "a")
        XCTAssertNotNil(model.error)
        model.reload(from: store, owner: "b")
        XCTAssertEqual(model.notes, [other])
        XCTAssertNil(model.error)
    }

    func testLocalToolPropagatesRememberAndForgetFailures() async throws {
        let storage = FailingMemoryNoteFileStorage()
        let file = root.appendingPathComponent("notes.json")
        let store = AskMemoryNoteStore(fileURL: file, storage: storage)
        let defaults = UserDefaults(suiteName: "ask-memory-tools-\(UUID().uuidString)")!
        let registry = MCPRegistry(settingsStore: MCPSettingsStore(defaults: defaults))
        let tools = AskLocalTools(registry: registry, notes: store, owner: { "a" })

        func call(_ arguments: [String: String]) throws -> AskToolCall {
            let data = try JSONSerialization.data(withJSONObject: arguments)
            return AskToolCall(id: UUID().uuidString, function: .init(name: "memory", arguments: String(decoding: data, as: UTF8.self)))
        }

        storage.failure = .write
        do {
            _ = try await tools.execute(call(["action": "remember", "text": "A fact"]), conversationId: "c")
            XCTFail("A failed write must not return a saved-note result")
        } catch {
            XCTAssertEqual(error as? FailingMemoryNoteFileStorage.Failure, .write)
        }
        XCTAssertTrue(store.list(owner: "a").isEmpty)
        storage.failure = nil
        let saved = try await tools.execute(call(["action": "remember", "text": "A fact"]), conversationId: "c")
        XCTAssertFalse(saved.isError)
        XCTAssertTrue(saved.content.hasPrefix("Saved note "))
        let note = try XCTUnwrap(store.list(owner: "a").first)

        storage.failure = .replace
        do {
            _ = try await tools.execute(call(["action": "forget", "id": note.id]), conversationId: "c")
            XCTFail("A failed replacement must not return a forgot-note result")
        } catch {
            XCTAssertEqual(error as? FailingMemoryNoteFileStorage.Failure, .replace)
        }
        XCTAssertEqual(store.list(owner: "a"), [note])
        storage.failure = nil
        let forgotten = try await tools.execute(call(["action": "forget", "id": note.id]), conversationId: "c")
        XCTAssertFalse(forgotten.isError)
        XCTAssertEqual(forgotten.content, "Forgot note \(note.id).")
        XCTAssertTrue(AskMemoryNoteStore(fileURL: file).list(owner: "a").isEmpty)
    }

    /// Opt-in screenshot using the production settings view and a failed file write.
    func testRenderRemovalFailure() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_MEMORY_NOTES_SNAPSHOTS"] else {
            throw XCTSkip("Set TYPEFLUX_MEMORY_NOTES_SNAPSHOTS to render the memory settings error")
        }
        let destination = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let storage = FailingMemoryNoteFileStorage()
        let store = AskMemoryNoteStore(fileURL: root.appendingPathComponent("notes.json"), storage: storage)
        let note = try store.add("Prefers concise answers and metric units", owner: "a")
        let model = AskMemoryNotesSettingsModel()
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "ask-notes-render-\(UUID().uuidString)")!)
        let view = AskToolsSettingsView(settings: settings, notes: store, owner: { "a" }, memoryNotes: model, pane: .memory)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let hosting = NSHostingView(rootView: view.padding(24).frame(width: 640, height: 300, alignment: .topLeading)
            .background(ModelVisualStyle.canvas))
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        storage.failure = .replace
        model.remove(note, from: store, owner: "a")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.notes, [note])
        XCTAssertEqual(model.error, FailingMemoryNoteFileStorage.Failure.replace.localizedDescription)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: destination.appendingPathComponent("memory-note-removal-error.png"))
        XCTAssertGreaterThan(png.count, 4000)
    }
}
