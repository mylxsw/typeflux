import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Launcher reading results", .serialized, .exclusiveUIState)
@MainActor
struct AskPluginReadingLayoutTests {
    private let plan = AskPluginPlan(mode: .live, title: "Screenshot text")
    private var longText: String { (1...52).map { "Line \($0): Read the screenshot text in the launcher." }.joined(separator: "\n") }

    private func output(_ text: String) -> AskPluginOutput {
        .init(body: text, original: "Original text", meta: [.init(text: "52 lines")], source: "On this Mac",
              actions: [.init(kind: .copy(text), title: "Copy", symbol: "doc.on.doc", shortcut: .enter)])
    }

    private func display(_ output: AskPluginOutput) -> AskPluginDisplay {
        .init(title: plan.title, symbol: "text.viewfinder", phase: .done(plan, output))
    }

    @Test func readingUsesAvailableSpaceAndKeepsShortTextCompact() throws {
        let long = output(longText)
        let content = try #require(AskPluginResultsView.contentViewportHeight(for: display(long), viewportHeight: 480))
        let body = AskPluginResultsView.readingBodyHeight(long, comparing: false, contentHeight: content)
        #expect(body > 350)
        let chrome = AskPluginResultsView.cardHeight(output: long, failure: nil, comparing: false)
            - AskPluginResultsView.bodyHeight(long.body)
        #expect(body + chrome == content)
        let short = output("Copied text")
        #expect(AskPluginResultsView.readingBodyHeight(short, comparing: false, contentHeight: content)
            == AskPluginResultsView.bodyHeight(short.body))
        #expect(AskPluginResultsView.readingBodyHeight(long, comparing: false, contentHeight: nil)
            == AskPluginResultsView.maximumBodyHeight)
        #expect(AskPluginResultsView.readingBodyHeight(long, comparing: true, contentHeight: content) < body)
        var noted = long
        noted.note = "Saved locally"
        #expect(AskPluginResultsView.readingBodyHeight(noted, comparing: false, contentHeight: content) == body - 22)
        #expect(AskPluginResultsView.readingBodyHeight(long, comparing: true, contentHeight: 40) == 0)
    }

    @Test func markdownAndStreamingShareTheReadingLayoutWhileSingleEntriesRemainLists() throws {
        var markdown = output(longText)
        markdown.markdown = true
        #expect(AskPluginResultsView.markdownContentHeight(markdown.body) > AskPluginResultsView.maximumMarkdownHeight)
        #expect(AskPluginResultsView.readingBodyHeight(markdown, comparing: false, contentHeight: 480) > 350)
        var streaming = display(markdown)
        streaming.phase = .running(plan)
        streaming.previous = output("Previous result")
        streaming.partial = markdown
        #expect(AskPluginResultsView.presentedOutput(streaming) == markdown)
        #expect(!AskPluginResultsView.showsSection(for: streaming))
        #expect(!AskPluginResultsView.showsSection(for: display(markdown)))
        streaming.hint = AskScreenshotTextPlugin.keywords[0]
        #expect(AskPluginResultsView.showsSection(for: streaming))
        var entry = output("")
        entry.items = [.init(id: "app", title: "Finder")]
        #expect(!AskPluginResultsView.isReadingOutput(entry))
        #expect(AskPluginResultsView.showsSection(for: display(entry)))
        var dictionary = output("word")
        dictionary.wordCard = AskWordCard(headword: "word", translation: "词")
        #expect(!AskPluginResultsView.isReadingOutput(dictionary))
        var translation = output(longText)
        translation.translation = .init(results: [.init(service: .device, name: "Device", state: .done(longText))],
                                        source: "en", target: "zh-Hans", interface: .english,
                                        submitted: true, isLookup: false)
        #expect(!AskPluginResultsView.isReadingOutput(translation))
        #expect(!AskPluginResultsView.showsSection(for: display(translation)))
    }

    @Test func longTextScrollsWithoutMovingItsActionsInBothAppearances() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        defer { NSApp.accessibilitySetValue(false, forAttribute: .init(rawValue: "AXEnhancedUserInterface")) }
        for markdown in [false, true] {
            for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                var result = output(longText)
                result.markdown = markdown
                let shown = display(result)
                let view = AskPluginResultsView(display: shown, question: "", viewportHeight: 480,
                                               onMain: {}, onAction: { _ in }, onAskAI: {}, onHighlight: { _ in })
                    .background(AskTheme.composerSurface)
                let window = AskTestVoiceWindow(contentRect: .init(x: 0, y: 0, width: AskMetrics.launcherWidth, height: 480),
                                                styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                window.contentView = NSHostingView(rootView: view)
                window.orderFront(nil)
                defer { window.close() }
                try await Task.sleep(for: .milliseconds(150))
                let host = try #require(window.contentView)
                host.layoutSubtreeIfNeeded()
                let scroll = try #require(scrollViews(host).max(by: { $0.contentSize.height < $1.contentSize.height }))
                #expect(scroll.contentSize.height > 350, "Long text must use the space formerly left blank")
                let document = try #require(scroll.documentView)
                #expect(document.bounds.height > scroll.contentSize.height)
                if markdown {
                    let editor = try #require(markdownEditor(host))
                    #expect(editor.bounds.width > 600)
                    #expect((editor.textContainer?.containerSize.width ?? 0) > 600,
                            "Markdown must wrap across the reading area, not a narrow column")
                }
                let before = try #require(accessibilityFrame("ask.plugin.actions", in: window))
                #expect(before.minY >= window.frame.minY && before.maxY <= window.frame.minY + 50)
                document.scroll(.init(x: 0, y: document.bounds.height))
                scroll.reflectScrolledClipView(scroll.contentView)
                #expect(scroll.contentView.bounds.minY > 0, "The final lines must remain reachable")
                #expect(accessibilityFrame("ask.plugin.actions", in: window) == before)
                if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] {
                    let root = URL(fileURLWithPath: directory)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    document.scroll(.zero)
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:]))
                        .write(to: root.appendingPathComponent("reading-\(markdown ? "markdown" : "ocr")-\(name).png"))
                }
            }
        }
    }

    @Test func screenshotResultFillsTheRealLauncherAndReturnStillCopiesEverything() async throws {
        let recognized = RecognizedText(lines: longText.components(separatedBy: "\n").map {
            .init(text: $0, confidence: 1, boundingBox: .zero)
        })
        let source = AskScreenshotTextSource(pixelSize: .init(width: 2502, height: 1744), fitsQuestion: true,
                                            recognition: Task { recognized })
        let savedLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(savedLanguage) }
        try await AskQuickResultsInteractionTests().withPasteboard { pasteboard in
            AppLocalization.shared.setLanguage(.simplifiedChinese)
            let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "ocr ") { model in
                model.plugins = AskPluginSession(plugins: [AskScreenshotTextPlugin(screenshot: { source })]) {
                    AskScreenshotTextPlugin.keywords
                }
                model.plugins.debounce = .zero
            }
            defer { launcher.close() }
            launcher.window.setContentSize(.init(width: AskMetrics.launcherWidth, height: AskLauncherWindowMode.expandedHeight))
            try await launcher.fixture.wait { launcher.fixture.model.plugins.output != nil }
            try await Task.sleep(for: .milliseconds(150))
            let host = try #require(launcher.window.contentView)
            host.layoutSubtreeIfNeeded()
            let scroll = try #require(scrollViews(host).max(by: { $0.contentSize.height < $1.contentSize.height }))
            #expect(scroll.contentSize.height > 350)
            if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("reading-full-launcher.png"))
            }
            try await launcher.press(AskQuickResultsInteractionTests.returnKey)
            #expect(pasteboard.string(forType: .string) == recognized.string)
            #expect(launcher.dismissed == 1)
        }
    }

    @Test func translationUsesTheLauncherViewportInsteadOfItsNaturalHeightCap() async throws {
        _ = NSApplication.shared
        var result = output(longText)
        result.translation = .init(results: [.init(service: .device, name: "Device", state: .done(longText))],
                                    source: "en", target: "zh-Hans", interface: .english,
                                    submitted: true, isLookup: false)
        let view = AskPluginResultsView(display: display(result), question: "", viewportHeight: 480,
                                       onMain: {}, onAction: { _ in }, onAskAI: {}, onHighlight: { _ in })
        let window = AskTestVoiceWindow(contentRect: .init(x: 0, y: 0, width: AskMetrics.launcherWidth, height: 480),
                                        styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        let host = try #require(window.contentView)
        host.layoutSubtreeIfNeeded()
        let scroll = try #require(scrollViews(host).first)
        #expect(scroll.contentSize.height > 400)
        #expect(scroll.contentSize.height < 450, "The language controls must fit above the scroll area")
        #expect((scroll.documentView?.bounds.height ?? 0) > scroll.contentSize.height)
    }

    private func scrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }

    private func markdownEditor(_ view: NSView) -> AskTranscriptText.Editor? {
        (view as? AskTranscriptText.Editor) ?? view.subviews.lazy.compactMap(markdownEditor).first
    }

    private func accessibilityFrame(_ identifier: String, in root: Any) -> NSRect? {
        var seen = Set<ObjectIdentifier>()
        func find(_ node: Any) -> NSRect? {
            guard let object = node as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            if object.responds(to: NSSelectorFromString("accessibilityIdentifier")),
               object.value(forKey: "accessibilityIdentifier") as? String == identifier,
               object.responds(to: NSSelectorFromString("accessibilityFrame")) {
                return (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue
            }
            guard object.responds(to: NSSelectorFromString("accessibilityChildren")) else { return nil }
            for child in object.value(forKey: "accessibilityChildren") as? [Any] ?? [] {
                if let frame = find(child) { return frame }
            }
            return nil
        }
        return find(root)
    }
}
