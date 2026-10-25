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
        editor.renderCache = AskTranscriptRenderCache()
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
        editor.renderCache = AskTranscriptRenderCache()
        let work = Deferred(); editor.preparation = work
        editor.requestContent("**Old**", markdown: true, dark: false)
        editor.requestContent("**Literal**", markdown: false, dark: false)
        work.finish(0)
        #expect(editor.string == "**Literal**")
    }

    @Test func `dismantling cancels delivery without breaking a subsequent presentation`() {
        let editor = AskTranscriptText.Editor()
        editor.renderCache = AskTranscriptRenderCache()
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
        editor.renderCache = AskTranscriptRenderCache()
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
        editor.renderCache = AskTranscriptRenderCache()
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

extension AskTranscriptPreparationTests {
    @Test func linksRouteThroughTheConversationAndWorkspacePathsBecomeLinks() throws {
        let rendered = AskMarkdownText.render("See [the report](outputs/report.html), [site](https://example.com) "
            + "and [notes](../secret.md).", markdown: true, document: nil)
        var links: [URL] = []
        rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            if let url = value as? URL { links.append(url) }
        }
        #expect(links.map(\.absoluteString) == ["typeflux-file:outputs/report.html", "https://example.com"])

        let editor = AskTranscriptText.Editor()
        editor.renderCache = AskTranscriptRenderCache()
        var opened: [(URL, Bool)] = []
        editor.onOpenLink = { opened.append(($0, $1)) }
        editor.clicked(onLink: links[1], at: 0)
        editor.clicked(onLink: "typeflux-file:work/a.py", at: 0)
        editor.clicked(onLink: 42, at: 0)
        #expect(opened.map(\.0.absoluteString) == ["https://example.com", "typeflux-file:work/a.py"])
        #expect(opened.allSatisfy { !$0.1 }, "No ⌘ held")
        // Outside a conversation a workspace link does nothing rather than reaching Launch Services.
        editor.onOpenLink = nil
        editor.clicked(onLink: links[0], at: 0)
    }
}

@Suite("Transcript navigation reuse", .exclusiveUIState)
@MainActor struct AskTranscriptNavigationReuseTests {
    private final class CountingWork: LatestBackgroundWorking {
        var submissions = 0
        func submit(_ work: @escaping () -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
            submissions += 1
            work()
            completion(.success(()))
        }
        func cancel() {}
    }

    @Test func revisitingMessageReusesRichTextAcrossEditors() throws {
        let cache = AskTranscriptRenderCache()
        let first = AskTranscriptText.Editor()
        first.renderCache = cache
        let firstWork = CountingWork(); first.preparation = firstWork
        first.requestContent("**Saved answer**", markdown: true, dark: false)
        #expect(firstWork.submissions == 1)
        AskTranscriptText.dismantleNSView(first, coordinator: ())
        let second = AskTranscriptText.Editor()
        second.renderCache = cache
        let secondWork = CountingWork(); second.preparation = secondWork
        second.requestContent("**Saved answer**", markdown: true, dark: false)
        #expect(secondWork.submissions == 0)
        #expect(second.string == "Saved answer")
        let font = try #require(second.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
        second.requestContent("**Changed answer**", markdown: true, dark: false)
        #expect(secondWork.submissions == 1)
        #expect(second.string == "Changed answer")
    }

    @Test func cacheSeparatesThemeAndLiteralTextAndCopiesMutableInput() {
        let cache = AskTranscriptRenderCache()
        let value = NSMutableAttributedString(string: "Original")
        cache.insert(value, text: "**Original**", markdown: true, dark: false)
        value.mutableString.setString("Modified")
        #expect(cache.value(text: "**Original**", markdown: true, dark: false)?.string == "Original")
        #expect(cache.value(text: "**Original**", markdown: true, dark: true) == nil)
        #expect(cache.value(text: "**Original**", markdown: false, dark: false) == nil)
        #expect(cache.value(text: "Other", markdown: true, dark: false) == nil)
        cache.insert(value, text: "Oversized", markdown: false, dark: false)
        let oversized = NSAttributedString(string: String(repeating: "x", count: 600_000))
        cache.insert(oversized, text: "Too large", markdown: false, dark: false)
        #expect(cache.value(text: "Too large", markdown: false, dark: false) == nil)
    }

    @Test func measurementTracksWidthAndContentUsingProductionConfiguration() throws {
        let editor = AskTranscriptText.makeEditor()
        editor.renderCache = AskTranscriptRenderCache()
        editor.setContent(String(repeating: "word ", count: 120), markdown: false, dark: false)
        let wide = try #require(editor.measuredSize(width: 500))
        #expect(editor.measuredSize(width: 500) == wide)
        let narrow = try #require(editor.measuredSize(width: 100))
        #expect(narrow.height > wide.height)
        editor.setContent("Short", markdown: false, dark: false)
        let short = try #require(editor.measuredSize(width: 100))
        #expect(short.height < narrow.height)
    }
}

@Suite("Transcript hosted navigation", .exclusiveUIState)
@MainActor struct AskTranscriptHostedNavigationTests {
    private final class Selection: ObservableObject {
        @Published var index = 0
        let marker = UUID().uuidString
        func text(_ row: Int) -> String {
            "**Conversation \(index), answer \(row)**\n\n"
                + String(repeating: "This is a complete answer that must remain visible. ", count: index == 0 ? 8 : 16)
                + "\n\nEnd \(marker)-\(index)-\(row)"
        }
    }

    private struct Transcript: View {
        @ObservedObject var selection: Selection
        var body: some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(0..<2) { row in
                        AskTranscriptText(text: selection.text(row))
                            .id("\(selection.index)-\(row)")
                    }
                }
                .padding(16)
            }
        }
    }

    private func editors(in view: NSView) -> [AskTranscriptText.Editor] {
        if let editor = view as? AskTranscriptText.Editor { return [editor] }
        return view.subviews.flatMap { editors(in: $0) }
    }

    @Test func coldCachedAndRapidSwitchesKeepCompleteAnswersAfterResize() async throws {
        _ = NSApplication.shared
        let selection = Selection()
        let host = NSHostingView(rootView: Transcript(selection: selection))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 1000),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }

        func waitForCompleteAnswers() async throws {
            let deadline = ContinuousClock.now + .seconds(4)
            var complete = false
            repeat {
                host.layoutSubtreeIfNeeded()
                let views = editors(in: host)
                complete = views.count == 2 && (0..<2).allSatisfy { row in
                    guard let view = views.first(where: { $0.string.contains("End \(selection.marker)-\(selection.index)-\(row)") }),
                          let container = view.textContainer, let layout = view.layoutManager else { return false }
                    let height = layout.usedRect(for: container).height
                    return height > 80 && view.frame.height + 1 >= height && view.frame.width > 200
                }
                if complete { break }
                try await Task.sleep(for: .milliseconds(10))
            } while ContinuousClock.now < deadline
            #expect(complete, "Both complete answers must occupy their full laid-out height, including after async delivery")
        }

        // Cold parses and cache hits both use the actual NSViewRepresentable configuration.
        for index in [0, 1, 0, 1] {
            selection.index = index
            try await waitForCompleteAnswers()
        }
        window.setContentSize(NSSize(width: 540, height: 1000))
        try await waitForCompleteAnswers()
        for index in [0, 1, 0, 1, 0] {
            selection.index = index
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        try await waitForCompleteAnswers()
    }
}
