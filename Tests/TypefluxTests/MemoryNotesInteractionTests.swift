import AppKit
import SwiftUI
@testable import Typeflux
import XCTest

@MainActor
final class MemoryNotesInteractionTests: XCTestCase {
    func testCorrectionSheetRetriesAndPersistsLineage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = FailingMemoryNoteFileStorage()
        let store = AskMemoryNoteStore(fileURL: directory.appendingPathComponent("notes.json"), storage: storage)
        let note = try store.add("Uses imperial units", owner: "a")
        let model = AskMemoryNotesSettingsModel()
        model.reload(from: store, owner: "a")
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: MemoryNotesEditorView(model: model, store: store, owner: "a", correctionsEnabled: true)
            .padding(24).frame(width: 640, height: 420, alignment: .topLeading).background(ModelVisualStyle.canvas))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        click(window, x: 553, y: 420 - 118)
        try await Task.sleep(for: .milliseconds(250))
        let sheet = try XCTUnwrap(window.attachedSheet)
        let editor = try XCTUnwrap(findTextView(sheet.contentView!))
        editor.string = "Uses metric units"
        editor.didChangeText()
        sheet.makeKey()
        try await Task.sleep(for: .milliseconds(200))
        storage.failure = .write
        click(sheet, x: 400, y: 36)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.notes, [note])
        XCTAssertNotNil(window.attachedSheet)
        storage.failure = nil
        click(sheet, x: 400, y: 36)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNil(model.error)
        XCTAssertEqual(model.notes.first?.text, "Uses metric units")
        XCTAssertEqual(model.notes.first?.provenance?.supersedes, note.id)
        for _ in 0 ..< 100 where window.attachedSheet != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(window.attachedSheet)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(host)
        try await Task.sleep(for: .milliseconds(100))
        snapshot(host, name: "memory-corrected-note.png")
        let reopened = AskMemoryNoteStore(fileURL: directory.appendingPathComponent("notes.json"))
        XCTAssertEqual(reopened.list(owner: "a").first?.text, "Uses metric units")
        XCTAssertEqual(reopened.list(owner: "a").first?.provenance?.supersedes, note.id)
    }

    private func snapshot(_ view: NSView, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_MEMORY_NOTES_SNAPSHOTS"],
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    private func findTextView(_ view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        return view.subviews.lazy.compactMap(findTextView).first
    }

    private func click(_ window: NSWindow, x: Double, y: Double) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: .init(x: x, y: y), modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                          clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
    }
}
