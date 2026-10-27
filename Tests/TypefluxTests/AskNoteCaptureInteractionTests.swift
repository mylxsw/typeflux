import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Quick note native launcher interaction", .serialized, .exclusiveUIState)
@MainActor
struct AskNoteCaptureInteractionTests {
    @Test func `return saves without opening chat and shift return keeps the line break`() async throws {
        let store = makeTestNotes()
        let launcher = try await AskQuickResultsInteractionTests.Launcher(
            text: "n First line",
            prepare: { $0.notes = store }
        )
        defer { launcher.close() }
        let model = launcher.fixture.model
        #expect(model.isNoteCaptureMode && model.launcherDraft.text == "First line")
        #expect(try store.count(.all) == 0)
        launcher.editor.setSelectedRange(NSRange(location: launcher.editor.string.utf16.count, length: 0))
        // Text insertion needs the real Return characters; the shared navigation helper uses an empty string.
        let newline = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift,
                                                    timestamp: 0, windowNumber: launcher.window.windowNumber,
                                                    context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                                    isARepeat: false, keyCode: 36))
        launcher.editor.keyDown(with: newline)
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.launcherDraft.text == "First line\n")
        try await launcher.press(36)
        try await launcher.fixture.wait { model.noteCapture.saved != nil }
        #expect(try store.count(.all) == 1)
        #expect(model.noteCapture.saved?.body == "First line\n")
        #expect(model.launcherDraft.text.isEmpty && launcher.dismissed == 0)
        #expect(await launcher.fixture.api.sends.isEmpty)
        #expect(model.launcherInputHistory.history.entries.isEmpty)
        try await launcher.press(36)
        #expect(try store.count(.all) == 1, "Return after a receipt cannot replay the previous body")
        model.launcherDraft.text = "Second note"
        try await Task.sleep(for: .milliseconds(80))
        try await launcher.press(36, .command)
        #expect(try store.count(.all) == 1, "The AI shortcut must not send a private capture")
        try await launcher.press(36)
        try await launcher.fixture.wait { model.noteCapture.saved?.body == "Second note" }
        #expect(try store.count(.all) == 2)
        try await launcher.press(53)
        #expect(launcher.dismissed == 1)
    }

    @Test func `input method return does not submit and empty prefix restores draft`() async throws {
        let store = makeTestNotes()
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "n ", prepare: { $0.notes = store })
        defer { launcher.close() }
        let model = launcher.fixture.model
        launcher.editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                                      replacementRange: NSRange(location: NSNotFound, length: 0))
        try await launcher.press(36)
        #expect(try store.count(.all) == 0)
        launcher.editor.unmarkText()
        model.launcherDraft.text = "Keep this draft"
        try await Task.sleep(for: .milliseconds(50))
        model.recordAbandonedLauncherInput()
        model.foldLauncherKeyword()
        #expect(model.launcherInputHistory.history.entries.isEmpty)
        #expect(model.resetLauncherForPresentation())
        try await Task.sleep(for: .milliseconds(80))
        #expect(launcher.editor.string == "Keep this draft")
        try pressButton("ask.noteCapture.clear", in: launcher.window)
        try await Task.sleep(for: .milliseconds(50))
        #expect(launcher.editor.string.isEmpty && model.noteCapture.body.isEmpty)
    }

    @Test func `entering A bare prefix restores without submitting`() async throws {
        let store = makeTestNotes()
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "", prepare: { model in
            model.notes = store
            model.noteCapture.update("A retained draft")
        })
        defer { launcher.close() }
        launcher.fixture.model.launcherDraft.text = "n"
        try await Task.sleep(for: .milliseconds(80))
        try await launcher.press(36)
        #expect(launcher.fixture.model.isNoteCaptureMode)
        #expect(launcher.fixture.model.launcherDraft.text == "A retained draft")
        #expect(try store.count(.all) == 0)
        try await launcher.press(36)
        try await launcher.fixture.wait { launcher.fixture.model.noteCapture.saved != nil }
        #expect(try store.count(.all) == 1)
    }

    @Test(arguments: [false, true])
    func `preview and receipt render in both appearances`(dark: Bool) async throws {
        let previous = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previous) }
        let store = makeTestNotes()
        let launcher = try await AskQuickResultsInteractionTests.Launcher(
            text: "记：# 首页改版想法\n\n明天和设计师确认首页方案。\n- 保留清晰的入口\n- 增加最近使用的笔记", prepare: { $0.notes = store }
        )
        defer { launcher.close() }
        launcher.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        var opened: UUID?
        launcher.fixture.model.openNotes = { opened = $0 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(launcher.fixture.model.noteCapture.hasContent)
        try capture(launcher.window, name: dark ? "capture-dark" : "capture-light")
        try await launcher.press(36)
        try await launcher.fixture.wait { launcher.fixture.model.noteCapture.saved != nil }
        #expect(launcher.fixture.model.noteCapture.saved?.title == "首页改版想法")
        try capture(launcher.window, name: dark ? "saved-dark" : "saved-light")
        try pressButton("ask.noteCapture.open", in: launcher.window)
        #expect(opened == launcher.fixture.model.noteCapture.saved?.id)
        #expect(launcher.dismissed == 1)
    }

    private func pressButton(_ id: String, in window: NSWindow) throws {
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        window.contentView?.layoutSubtreeIfNeeded()
        var seen = Set<ObjectIdentifier>()
        func descendants(_ element: Any) -> [NSObject] {
            guard let object = element as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return [] }
            let children = object.responds(to: NSSelectorFromString("accessibilityChildren"))
                ? object.value(forKey: "accessibilityChildren") as? [Any] ?? [] : []
            return [object] + children.flatMap(descendants)
        }
        let button = try #require(descendants(window).first {
            $0.responds(to: NSSelectorFromString("accessibilityIdentifier"))
                && $0.value(forKey: "accessibilityIdentifier") as? String == id
        })
        let frame = try #require((button.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue)
        #expect(window.frame.contains(frame), "Capture actions must remain visible in a short launcher")
        let selector = NSSelectorFromString("accessibilityPerformPress")
        #expect(button.responds(to: selector))
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let press = unsafeBitCast(button.method(for: selector), to: Press.self)
        #expect(press(button, selector))
    }

    private func capture(_ window: NSWindow, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_CAPTURE_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let view = try #require(window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: root.appendingPathComponent(name + ".png"))
    }
}
