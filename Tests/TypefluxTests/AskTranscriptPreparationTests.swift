import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Transcript background preparation", .serialized, .exclusiveUIState)
@MainActor struct AskTranscriptPreparationTests {
    private final class Deferred: LatestBackgroundWorking {
        var jobs: [(work: () -> Void, complete: (Result<Void, Error>) -> Void)] = []
        func submit(_ work: @escaping () -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
            jobs.append((work, completion))
        }
        func cancel() {}
        func finish(_ index: Int) { jobs[index].work(); jobs[index].complete(.success(())) }
    }

    @Test func `parsing is deferred and late results cannot replace newer content`() {
        let editor = AskTranscriptText.Editor()
        let work = Deferred(); editor.preparation = work
        editor.requestContent("**Old**", markdown: true, dark: false)
        #expect(editor.string.isEmpty)
        editor.requestContent("**Newest**", markdown: true, dark: false)
        work.finish(1)
        #expect(editor.string == "Newest")
        work.finish(0)
        #expect(editor.string == "Newest")
        editor.requestContent("**Newest**", markdown: true, dark: false)
        #expect(work.jobs.count == 2)
    }

    @Test func `plain text invalidates an outstanding markdown result`() {
        let editor = AskTranscriptText.Editor()
        let work = Deferred(); editor.preparation = work
        editor.requestContent("**Old**", markdown: true, dark: false)
        editor.requestContent("**Literal**", markdown: false, dark: false)
        work.finish(0)
        #expect(editor.string == "**Literal**")
    }

    @Test func `dismantling cancels delivery without breaking a subsequent presentation`() {
        let editor = AskTranscriptText.Editor()
        let work = Deferred(); editor.preparation = work
        editor.requestContent("**Old**", markdown: true, dark: false)
        AskTranscriptText.dismantleNSView(editor, coordinator: ())
        work.finish(0)
        #expect(editor.string.isEmpty)
        editor.requestContent("**New**", markdown: true, dark: false)
        work.finish(1)
        #expect(editor.string == "New")
    }

    @Test func `hosting view receives asynchronously prepared text and a nonzero layout`() async throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: AskTranscriptText(text: "**First**\n\nSecond\n\nThird"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        func editor(in view: NSView) -> AskTranscriptText.Editor? {
            if let editor = view as? AskTranscriptText.Editor { return editor }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        let deadline = ContinuousClock.now + .seconds(3)
        repeat {
            host.layoutSubtreeIfNeeded()
            if editor(in: host)?.string == "First\nSecond\nThird" { break }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        let text = try #require(editor(in: host))
        #expect(text.string == "First\nSecond\nThird")
        #expect(text.frame.height > 0)
    }

    @Test func `failed preparation shows plain text and can be requested again`() {
        let editor = AskTranscriptText.Editor()
        editor.setContent("Existing", markdown: false, dark: false)
        let work = Deferred(); editor.preparation = work
        editor.requestContent("**New**", markdown: true, dark: false)
        work.jobs[0].complete(.failure(BackgroundWorkFailure.timedOut))
        #expect(editor.string == "**New**")
        editor.requestContent("**New**", markdown: true, dark: false)
        work.finish(1)
        #expect(editor.string == "New")
    }

    @Test func `real background preparation preserves markdown and selected prefix`() async throws {
        let editor = AskTranscriptText.Editor()
        editor.setContent("**Hello** 🦆", markdown: true, dark: false)
        editor.setSelectedRange(NSRange(location: 0, length: 5))
        editor.requestContent("**Hello** 🦆\n\nUpdated", markdown: true, dark: false)
        let deadline = ContinuousClock.now + .seconds(3)
        while editor.string != "Hello 🦆\nUpdated", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(editor.string == "Hello 🦆\nUpdated")
        #expect(editor.selectedRange() == NSRange(location: 0, length: 5))
        let font = try #require(editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
    }
}
