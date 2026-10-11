import AppKit
import Testing
@testable import Typeflux

@Suite("Launcher Esc with result focus", .exclusiveUIState)
@MainActor
struct AskLauncherEscapeMonitorTests {
    @Test func escapeReturnsFromScreenshotResultThenClosesLauncher() async throws {
        let text = "Recognized screenshot text"
        let source = AskScreenshotTextSource(pixelSize: CGSize(width: 400, height: 200), fitsQuestion: true,
                                            recognition: Task {
            RecognizedText(lines: [.init(text: text, confidence: 1, boundingBox: .zero)])
        })
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "", prepare: { model in
            let image = ScreenshotFollowUpImage(image: ScreenCaptureTestSupport.image(width: 400, height: 200),
                                               scale: 2, isLongImage: false)
            model.launcherScreenshot = AskLauncherScreenshot(image: image, source: source)
            model.showScreenshotText()
        })
        defer { launcher.close() }
        let model = launcher.fixture.model
        try await launcher.fixture.wait { model.plugins.output?.body == text }
        launcher.window.makeKeyAndOrderFront(nil)
        // A read-only result text view owns the keyboard after selecting its text.
        let result = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        result.string = text
        result.isEditable = false
        result.isSelectable = true
        launcher.window.contentView?.addSubview(result)
        #expect(launcher.window.makeFirstResponder(result))
        result.setSelectedRange(NSRange(location: 0, length: 10))
        #expect(launcher.window.firstResponder === result)

        NSApp.sendEvent(try event(in: launcher.window))
        try await launcher.fixture.wait { !model.plugins.isActive }
        #expect(launcher.dismissed == 0, "Esc exits the result before dismissing the launcher")
        #expect(launcher.window.firstResponder === launcher.editor)
        launcher.editor.insertText("next question", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(model.launcherDraft.text == "next question")

        NSApp.sendEvent(try event(in: launcher.window))
        #expect(launcher.dismissed == 1, "Esc is handled once when the editor already has focus")
    }

    @Test func leavesOtherKeysWindowsAndMarkedTextToTheirResponder() throws {
        _ = NSApplication.shared
        let window = AskTestVoiceWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                                        styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: window.contentLayoutRect)
        let editor = AskComposerTextView.Editor(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        let result = NSTextView(frame: NSRect(x: 0, y: 50, width: 200, height: 40))
        let monitor = AskLauncherEscapeMonitor.MonitorView()
        content.addSubview(editor)
        content.addSubview(result)
        content.addSubview(monitor)
        window.contentView = content
        var escaped = 0
        editor.onDismiss = { escaped += 1 }
        #expect(window.makeFirstResponder(result))
        #expect(!monitor.handle(try event(in: window, code: 36)))
        #expect(!monitor.handle(try event(in: window, modifiers: .command)))
        #expect(!monitor.handle(try event(in: nil)))
        result.setMarkedText("composing", selectedRange: NSRange(location: 9, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(result.hasMarkedText())
        #expect(!monitor.handle(try event(in: window)))
        #expect(window.firstResponder === result)
        #expect(escaped == 0)
        result.unmarkText()
        #expect(monitor.handle(try event(in: window)))
        #expect(escaped == 1)
        #expect(!monitor.handle(try event(in: window)), "The focused editor handles Esc itself")
        monitor.removeFromSuperview()
        #expect(!monitor.handle(try event(in: window)))
    }

    private func event(in window: NSWindow?, code: UInt16 = 53,
                       modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: code))
    }
}
