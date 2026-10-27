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
        try await fit(launcher)
        try capture(launcher.window, name: dark ? "capture-dark" : "capture-light")
        try await launcher.press(36)
        try await launcher.fixture.wait { launcher.fixture.model.noteCapture.saved != nil }
        #expect(launcher.fixture.model.noteCapture.saved?.title == "首页改版想法")
        try await fit(launcher)
        try capture(launcher.window, name: dark ? "saved-dark" : "saved-light")
        try pressButton("ask.noteCapture.open", in: launcher.window)
        #expect(opened == launcher.fixture.model.noteCapture.saved?.id)
        #expect(launcher.dismissed == 1)
    }

    @Test(arguments: [false, true])
    func `target picker append preview and undo work with native buttons`(dark: Bool) async throws {
        let previous = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previous) }
        let store = makeTestNotes()
        var before = makeTestNote("产品想法", at: Date().timeIntervalSince1970 - 1800)
        before.body = "## 当前方向\n让记录成为一个随手就能完成的动作。"
        before.tags = ["private"]
        try store.save(before)
        var other = makeTestNote("产品想法", at: Date().timeIntervalSince1970 - 3600)
        other.body = "访谈准备：整理问题，确认参与者和时间。"
        try store.save(other)
        let launcher = try await AskQuickResultsInteractionTests.Launcher(
            text: "记：访谈补充：保留明确的保存反馈。\n下周再验证一次。", prepare: { $0.notes = store }
        )
        defer { launcher.close() }
        let model = launcher.fixture.model
        let input = model.launcherDraft.text
        launcher.window.makeKeyAndOrderFront(nil)
        launcher.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        try pressButton("ask.noteCapture.choose", in: launcher.window)
        await model.noteCaptureSearchTask?.value
        try await launcher.fixture.wait { searchField(in: launcher.window.contentView) != nil }
        let field = try #require(searchField(in: launcher.window.contentView))
        #expect(field.maximumRecents == 0 && field.recentsAutosaveName == nil)
        field.stringValue = "产品"
        let delegate = try #require(field.delegate as? AskNoteCaptureSearchField.Coordinator)
        delegate.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        try await launcher.fixture.wait { model.noteCapture.targetQuery == "产品" && model.noteCapture.searching }
        await model.noteCaptureSearchTask?.value
        #expect(model.noteCapture.matches.count == 2 && model.launcherDraft.text == input)
        try await fit(launcher)
        try capture(launcher.window, name: dark ? "picker-dark" : "picker-light")
        try pressButton("ask.noteCapture.target." + before.id.uuidString, in: launcher.window)
        #expect(model.noteCapture.target?.id == before.id)
        #expect(try store.revisions(of: before.id).isEmpty)
        try await fit(launcher)
        try capture(launcher.window, name: dark ? "append-dark" : "append-light")
        try await launcher.press(36)
        try await launcher.fixture.wait { model.noteCapture.savedWasAppend }
        #expect(try store.note(id: before.id)?.body == before.body + "\n\n" + input)
        #expect(try store.count(.all) == 2)
        try await fit(launcher)
        try capture(launcher.window, name: dark ? "appended-dark" : "appended-light")
        try pressButton("ask.noteCapture.undo", in: launcher.window)
        try await launcher.fixture.wait { model.noteCapture.undone }
        #expect(try store.note(id: before.id)?.body == before.body)
        #expect(model.launcherInputHistory.history.entries.isEmpty)
    }

    @Test func `conflict shows the review action and keeps typed content`() async throws {
        let store = makeTestNotes()
        let before = makeTestNote("Existing", at: 10)
        try store.save(before)
        let launcher = try await AskQuickResultsInteractionTests.Launcher(
            text: "n New content",
            prepare: { $0.notes = store }
        )
        defer { launcher.close() }
        let model = launcher.fixture.model
        model.selectNoteCaptureTarget(before)
        var changed = before
        changed.body = "Other edits"
        try store.save(changed)
        try await launcher.press(36)
        try await launcher.fixture.wait { model.noteCapture.requiresReview }
        try await fit(launcher)
        try capture(launcher.window, name: "conflict")
        try pressButton("ask.noteCapture.reload", in: launcher.window)
        await model.noteCaptureTask?.value
        #expect(!model.noteCapture.requiresReview && model.launcherDraft.text == "New content")
        #expect(model.noteCapture.target?.body == changed.body)
        try await launcher.press(36)
        try await launcher.fixture.wait { model.noteCapture.savedWasAppend }
        #expect(try store.note(id: before.id)?.body == "Other edits\n\nNew content")
    }

    private func searchField(in view: NSView?) -> NSSearchField? {
        guard let view else { return nil }
        return (view as? NSSearchField) ?? view.subviews.lazy.compactMap { searchField(in: $0) }.first
    }

    @Test func `picker keyboard respects composition and selecting does not write`() async throws {
        let store = makeTestNotes()
        try store.save(makeTestNote("One", at: 10))
        let launcher = try await AskQuickResultsInteractionTests.Launcher(
            text: "n Addition",
            prepare: { $0.notes = store }
        )
        defer { launcher.close() }
        launcher.window.makeKeyAndOrderFront(nil)
        let model = launcher.fixture.model
        try pressButton("ask.noteCapture.choose", in: launcher.window)
        await model.noteCaptureSearchTask?.value
        try await launcher.fixture.wait { searchField(in: launcher.window.contentView) != nil }
        let field = try #require(searchField(in: launcher.window.contentView))
        let delegate = try #require(field.delegate as? AskNoteCaptureSearchField.Coordinator)
        let editor = NSTextView()
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(model.noteCapture.choosingTarget)
        editor.unmarkText()
        #expect(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        #expect(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:))))
        #expect(!delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))))
        #expect(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(!model.noteCapture.choosingTarget && model.launcherDraft.text == "Addition")
        model.chooseNoteCaptureTarget()
        await model.noteCaptureSearchTask?.value
        model.activateNoteCapture()
        #expect(model.noteCapture.target != nil && model.noteCapture.saved == nil)
        let target = try #require(model.noteCapture.target)
        #expect(try store.revisions(of: target.id).isEmpty)
    }

    @Test func `picker failure can retry and empty results keep the draft`() async throws {
        let store = CaptureTestStore()
        await store.setSearchFailure(true)
        let launcher = try await AskQuickResultsInteractionTests.Launcher(
            text: "n Retained",
            prepare: { $0.notes = store }
        )
        defer { launcher.close() }
        let model = launcher.fixture.model
        try pressButton("ask.noteCapture.choose", in: launcher.window)
        await model.noteCaptureSearchTask?.value
        try await fit(launcher)
        #expect(model.noteCapture.searchFailure != nil)
        await store.setSearchFailure(false)
        try pressButton("ask.noteCapture.retrySearch", in: launcher.window)
        await model.noteCaptureSearchTask?.value
        #expect(model.noteCapture.matches.isEmpty && !model.noteCapture.actionEnabled)
        try await fit(launcher)
        try capture(launcher.window, name: "picker-empty")
        try pressButton("ask.noteCapture.cancel", in: launcher.window)
        #expect(!model.noteCapture.choosingTarget && model.launcherDraft.text == "Retained")
    }

    private func fit(_ launcher: AskQuickResultsInteractionTests.Launcher) async throws {
        try await Task.sleep(for: .milliseconds(80))
        let height = launcher.heights.last ?? 420
        launcher.window.setContentSize(NSSize(width: AskMetrics.launcherWidth, height: height))
        launcher.fixture.model.launcherViewport.show(height)
        try await Task.sleep(for: .milliseconds(80))
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
