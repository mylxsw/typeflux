import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Typeflux

/// The launcher's results area never stays empty: context gets the canvas, an empty
/// home greets, and a search without matches says so (`AskLauncherContextHome`).
@Suite("Ask launcher empty results", .exclusiveUIState)
@MainActor
struct AskLauncherEmptyResultsTests {
    private typealias Context = AskLauncherContextHome

    private static func screenshot(_ count: Int = 1) -> [AskAttachment] {
        (0 ..< count).map { _ in AskAttachment(kind: .image, name: "Screenshot", image: "data:,", screenshot: true) }
    }

    private static let image = AskAttachment(kind: .image, name: "photo.png", byteSize: 2048)
    private static let pdf = AskAttachment(kind: .file, name: "Report.pdf", byteSize: 3_400_000, pages: 24)
    private static let folder = AskAttachment(kind: .folder, name: "docs", path: "/tmp/docs")
    private static let quote = AskReference(messageId: "m", text: "quoted")
    private static let settings = SettingsStore(
        defaults: UserDefaults(suiteName: "AskLauncherEmptyResultsTests") ?? .standard)

    private func draft(_ attachments: [AskAttachment] = [], references: [AskReference] = [], text: String = "",
                       skills: [String]? = nil, mcp: [String]? = nil) -> AskDraft {
        var draft = AskDraft()
        draft.text = text
        draft.attachments = attachments.isEmpty ? nil : attachments
        draft.references = references.isEmpty ? nil : references
        draft.skills = skills
        draft.mcpServers = mcp
        return draft
    }

    @Test func conversationCanvasSurvivesPendingAndUnsearchableInput() async throws {
        let accessibility = AskWorkspaceTestAccessibility()
        defer { accessibility.restore() }
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "ssssdddddddd")
        defer { launcher.close() }
        let model = launcher.fixture.model
        try await Task.sleep(for: .milliseconds(350))
        func hasCanvas() -> Bool {
            launcher.window.contentView?.layoutSubtreeIfNeeded()
            return SettingsBehaviorTestSupport.elements(in: launcher.window).contains {
                $0.value("accessibilityIdentifier") as? String == "ask.launcher.empty.title"
            }
        }
        for text in ["hello, world may be more", String(repeating: "long question ", count: 8),
                     "你好，世界", "ssssdddddddd"] {
            model.launcherDraft.text = text
            try await Task.sleep(for: .milliseconds(100))
            // Simulate the interval after native input changes but before search
            // accepts that text. The canvas must not depend on query equality.
            model.quickSearch.update(text: "previous query", chinese: false, calculator: false, sources: .init())
            model.quickSearch.results = nil
            try await Task.sleep(for: .milliseconds(50))
            #expect(!model.quickSearch.isCurrent(text: text))
            #expect(hasCanvas(), "The real launcher must show its canvas for: \(text)")
        }
    }

    @Test func briefResultGapsDoNotFlashTheConversationCanvas() async throws {
        let accessibility = AskWorkspaceTestAccessibility()
        defer { accessibility.restore() }
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "unmatched")
        defer { launcher.close() }
        let model = launcher.fixture.model
        func hasCanvas() -> Bool {
            launcher.window.contentView?.layoutSubtreeIfNeeded()
            return SettingsBehaviorTestSupport.elements(in: launcher.window).contains {
                $0.value("accessibilityIdentifier") as? String == "ask.launcher.empty.title"
            }
        }
        // A visible indexing notice owns the results area just like a match.
        var visible = AskQuickResults(apps: [], lead: false)
        visible.notice = .indexing(found: 1, progress: nil)
        for _ in 0 ..< 4 {
            model.quickSearch.results = visible
            try await Task.sleep(for: .milliseconds(60))
            #expect(!hasCanvas())
            model.quickSearch.results = nil
            try await Task.sleep(for: .milliseconds(60))
            #expect(!hasCanvas(), "A short empty batch must not flash the orb")
        }
        try await Task.sleep(for: .milliseconds(350))
        #expect(hasCanvas(), "A sustained empty result still shows the canvas")
        model.launcherDraft.text = "another unmatched question"
        try await Task.sleep(for: .milliseconds(60))
        #expect(hasCanvas(), "Typing must not hide an already visible canvas")
    }

    @Test func pendingSearchKeepsOrbAndDestinationPositions() async throws {
        let accessibility = AskWorkspaceTestAccessibility()
        defer { accessibility.restore() }
        let destination = AskLauncherNoMatch.Destination(
            keyword: AskKeyword(keyword: "f", pluginID: AskFileSearchPlugin.id),
            title: "Search in files", detail: "f query", symbol: "doc.text.magnifyingglass")
        func content(_ query: String, searched: Bool) -> some View {
            AskLauncherNoMatchView(query: query, searched: searched, destinations: [destination],
                                  highlighted: .constant(nil), viewportHeight: 500,
                                  onAskAI: {}, onPick: { _ in })
                .frame(width: 700, height: 500)
        }
        let host = NSHostingView(rootView: content("initial question", searched: true))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        func positions() throws -> [NSRect] {
            host.layoutSubtreeIfNeeded()
            let title = try #require(SettingsBehaviorTestSupport.elements(in: window).first {
                $0.value("accessibilityIdentifier") as? String == "ask.launcher.empty.title"
            })
            let button = try SettingsBehaviorTestSupport.button("Search in files", in: window)
            #expect(title.frame.height > 0)
            #expect(button.frame.height > 0)
            return [title.frame, button.frame]
        }
        try await Task.sleep(for: .milliseconds(50))
        let original = try positions()
        // Append, delete, and settle: none may shift the visible canvas.
        for (query, searched) in [("initial question more", false), ("initial", false),
                                  ("initial", true), (String(repeating: "long ", count: 40), false)] {
            host.rootView = content(query, searched: searched)
            try await Task.sleep(for: .milliseconds(50))
            #expect(try positions() == original)
        }
    }

    // MARK: - Subject

    @Test func theSubjectFollowsWhatRidesWithTheQuestion() {
        #expect(Context.subject(attachments: [], references: [], tools: 0, loading: false) == nil)
        #expect(Context.subject(attachments: [], references: [], tools: 0, loading: true)! == (.pending, 0))
        #expect(Context.subject(attachments: [], references: [], tools: 2, loading: false)! == (.tools, 2))
        // The pieces of one long screenshot are one screenshot.
        #expect(Context.subject(attachments: Self.screenshot(3), references: [], tools: 0, loading: false)!
            == (.screenshot, 1))
        #expect(Context.subject(attachments: [Self.image, Self.image], references: [], tools: 0, loading: false)!
            == (.image, 2))
        #expect(Context.subject(attachments: Self.screenshot() + [Self.image], references: [], tools: 0,
                                loading: false)! == (.image, 2))
        #expect(Context.subject(attachments: [Self.pdf], references: [], tools: 0, loading: false)! == (.file, 1))
        #expect(Context.subject(attachments: [Self.folder], references: [], tools: 1, loading: true)! == (.folder, 1))
        #expect(Context.subject(attachments: [Self.pdf, Self.folder], references: [], tools: 0, loading: false)!
            == (.mixed, 2))
        #expect(Context.subject(attachments: [], references: [Self.quote], tools: 0, loading: false)! == (.quote, 1))
        #expect(Context.subject(attachments: [Self.pdf], references: [Self.quote, Self.quote], tools: 0,
                                loading: false)! == (.mixed, 3))
    }

    @Test func idleContextOffersStartersAndTypingHidesThem() throws {
        #expect(Context.content(draft(), loading: false) == nil)

        let idle = try #require(Context.content(draft(Self.screenshot()), loading: false))
        #expect(idle.subject == .screenshot && !idle.typing)
        #expect(idle.title == L("ask.launcher.context.title.screenshot"))
        #expect(idle.subtitle == L("ask.launcher.context.subtitle"))
        #expect(idle.starters.count == Context.maximumStarters)
        #expect(idle.starters.first?.prompt == L("ask.launcher.context.screenshot.ocr"))

        let typing = try #require(Context.content(draft(Self.screenshot(), text: "why?"), loading: false))
        #expect(typing.typing && typing.starters.isEmpty)
        #expect(typing.title == L("ask.launcher.context.typing", L("ask.launcher.context.noun.screenshot")))
        #expect(typing.subtitle == L("ask.launcher.context.subtitle.typing"))

        let pending = try #require(Context.content(draft(), loading: true))
        #expect(pending.subject == .pending && pending.starters.isEmpty)
        #expect(pending.title == L("ask.launcher.context.title.pending"))
        #expect(Context.content(draft(text: "typed"), loading: true)?.title == L("ask.launcher.context.title.pending"))

        let tools = try #require(Context.content(draft(skills: ["s"], mcp: ["m"]), loading: false))
        #expect(tools.subject == .tools && tools.count == 2 && tools.starters.isEmpty)
        #expect(tools.title == L("ask.empty") && tools.subtitle == L("ask.launcher.context.subtitle.tools"))
        #expect(Context.content(draft(text: "q", skills: ["s"]), loading: false)?.title
            == L("ask.launcher.context.typing.tools"))
    }

    @Test func headlinesAndNounsCountWhatTheyName() {
        #expect(Context.headline(.image, count: 1) == L("ask.launcher.context.title.image"))
        #expect(Context.headline(.image, count: 3) == L("ask.launcher.context.title.images", 3))
        #expect(Context.headline(.file, count: 1) == L("ask.launcher.context.title.file"))
        #expect(Context.headline(.file, count: 2) == L("ask.launcher.context.title.files", 2))
        #expect(Context.headline(.folder, count: 1) == L("ask.launcher.context.title.folder"))
        #expect(Context.headline(.folder, count: 2) == L("ask.launcher.context.title.folders", 2))
        #expect(Context.headline(.quote, count: 4) == L("ask.launcher.context.title.quote"))
        #expect(Context.headline(.mixed, count: 4) == L("ask.launcher.context.title.mixed", 4))
        #expect(Context.headline(.pending, count: 0) == L("ask.launcher.context.title.pending"))
        #expect(Context.noun(.image, count: 2) == L("ask.launcher.context.noun.images", 2))
        #expect(Context.noun(.file, count: 2) == L("ask.launcher.context.noun.files", 2))
        #expect(Context.noun(.folder, count: 2) == L("ask.launcher.context.noun.folders", 2))
        #expect(Context.noun(.quote, count: 2) == L("ask.launcher.context.noun.quotes", 2))
        #expect(Context.noun(.mixed, count: 2) == L("ask.launcher.context.noun.items", 2))
    }

    @Test func everySubjectHasDistinctLocalizedStarters() {
        let subjects: [Context.Subject] = [.screenshot, .image, .file, .folder, .quote, .mixed]
        for subject in subjects {
            let starters = Context.starters(for: subject)
            #expect((3 ... Context.maximumStarters).contains(starters.count), "\(subject)")
            #expect(Set(starters.map(\.id)).count == starters.count)
            for starter in starters {
                #expect(!starter.title.hasPrefix("ask.launcher.context."), "\(starter.id)")
                #expect(!starter.detail.hasPrefix("ask.launcher.context."), "\(starter.id)")
                #expect(!starter.symbol.isEmpty)
            }
        }
        #expect(Context.starters(for: .tools).isEmpty)
        #expect(Context.starters(for: .pending).isEmpty)
    }

    // MARK: - Keyboard

    @Test func arrowsEnterTheStartersAndReturnToTheEditor() {
        #expect(Context.move(nil, by: 1, count: 4) == 0)
        #expect(Context.move(nil, by: -1, count: 4) == nil)
        #expect(Context.move(0, by: 1, count: 4) == 1)
        #expect(Context.move(0, by: -1, count: 4) == nil)
        #expect(Context.move(3, by: 1, count: 4) == 3)
        #expect(Context.move(2, by: -1, count: 4) == 1)
        #expect(Context.move(nil, by: 1, count: 0) == nil)
        #expect(AskLauncherNoMatch.move(nil, by: 1, count: 2) == 0)
        #expect(AskLauncherNoMatch.move(0, by: -1, count: 2) == nil)
    }

    @Test func aFilledStarterKeepsItsFirstWordFromKeywordMode() {
        #expect(Context.plainTextLead(of: "Summarize the key points") == "Summarize ")
        #expect(Context.plainTextLead(of: "总结要点") == "总结要点")
    }

    @Test func welcomeChipsTakeTheArrowsOnlyOnceEntered() {
        typealias Welcome = AskLauncherWelcome
        #expect(Welcome.move(nil, key: .vertical(1), count: 3) == (true, 0))
        #expect(Welcome.move(2, key: .vertical(1), count: 3) == (true, 2))
        #expect(Welcome.move(nil, key: .vertical(-1), count: 3) == (false, nil))
        #expect(Welcome.move(1, key: .vertical(-1), count: 3) == (true, nil))
        #expect(Welcome.move(nil, key: .horizontal(1), count: 3) == (true, 0))
        #expect(Welcome.move(nil, key: .horizontal(-1), count: 3) == (false, nil))
        #expect(Welcome.move(2, key: .horizontal(1), count: 3) == (true, 0))
        #expect(Welcome.move(0, key: .horizontal(-1), count: 3) == (true, 2))
        #expect(Welcome.move(1, key: .number(1), count: 3) == (false, 1))
        #expect(Welcome.move(1, key: .tab, count: 3) == (false, 1))
        #expect(Welcome.move(nil, key: .vertical(1), count: 0) == (false, nil))
    }

    @Test func tabReachesTheMonitorWithoutModifiers() {
        typealias Monitor = AskLauncherHomeKeyMonitor
        #expect(Monitor.key(keyCode: Monitor.tabKeyCode, modifiers: [], characters: "\t") == .tab)
        #expect(Monitor.key(keyCode: Monitor.tabKeyCode, modifiers: .shift, characters: "\t") == nil)
    }

    // MARK: - Layout

    @Test func smallViewportsDropTheOrbThenShrinkThePreview() {
        #expect(Context.layout(viewport: 400) == .init(showsOrb: true, compactPreview: false))
        #expect(Context.layout(viewport: 300) == .init(showsOrb: true, compactPreview: true))
        #expect(Context.layout(viewport: 200) == .init(showsOrb: false, compactPreview: true))
        #expect(AskLauncherWelcome.layout(viewport: 420) == .init(orbSize: 72, showsHint: true))
        #expect(AskLauncherWelcome.layout(viewport: 340) == .init(orbSize: 52, showsHint: true))
        #expect(AskLauncherWelcome.layout(viewport: 250) == .init(orbSize: 0, showsHint: true))
        #expect(AskLauncherWelcome.layout(viewport: 150) == .init(orbSize: 0, showsHint: false))
    }

    // MARK: - Preview

    @Test func thePreviewNamesAndMeasuresWhatItShows() {
        typealias Preview = AskLauncherContextPreview
        #expect(Preview.title([]) == "")
        #expect(Preview.title(Self.screenshot(2)) == L("screenshot.ask.attachmentName"))
        #expect(Preview.detail(Self.screenshot(2)) == L("ask.launcher.context.preview.pieces", 2))
        #expect(Preview.detail(Self.screenshot()) == nil)
        #expect(Preview.title([Self.pdf]) == "Report.pdf")
        #expect(Preview.title([Self.pdf, Self.image]) == L("ask.launcher.context.preview.more", "Report.pdf", 1))
        let pdf = Preview.detail([Self.pdf]) ?? ""
        #expect(pdf.hasPrefix(L("ask.launcher.context.preview.pages", 24) + " · "))
        #expect(Preview.detail([Self.folder]) == "/tmp/docs")
        #expect(Preview.detail([Self.pdf, Self.image]) == nil)
        #expect(Preview.detail([AskAttachment(kind: .file, name: "a")]) == nil)
        #expect(Preview.symbol(for: .image) == "photo" && Preview.symbol(for: .folder) == "folder.fill")
        #expect(Preview.symbol(for: .file) == Preview.symbol(for: nil))
    }

    // MARK: - No match

    @Test func aSearchWithoutMatchesOffersTheWebAndFiles() {
        let google = AskKeyword(keyword: "g", pluginID: AskWebSearchPlugin.id,
                                options: [AskWebSearchPlugin.engineOption: "google"])
        let github = AskKeyword(keyword: "gh", pluginID: AskWebSearchPlugin.id,
                                options: [AskWebSearchPlugin.engineOption: "github"])
        let files = AskKeyword(keyword: "f", pluginID: AskFileSearchPlugin.id)
        let translate = AskKeyword(keyword: "fy", pluginID: AskTranslatePlugin.id)
        let choices = [translate, google, github, files].map {
            AskLauncherHome.KeywordChoice(keyword: $0, title: $0.keyword.uppercased(), symbol: "star")
        }
        let destinations = AskLauncherNoMatch.destinations(choices, query: "weekly")
        #expect(destinations.map(\.keyword) == [google, files])
        #expect(destinations[0].title == L("ask.launcher.noMatch.web", "G", "weekly"))
        #expect(destinations[0].detail == "g weekly")
        #expect(destinations[1].title == L("ask.launcher.noMatch.files"))
        #expect(destinations.map(\.id) == [google.id, files.id])
        #expect(AskLauncherNoMatch.destinations(Array(choices.prefix(1)), query: "q").isEmpty)
    }

    // MARK: - Sending

    @Test func theScreenshotMarkStaysOnThisMac() {
        var draft = draft(Self.screenshot())
        draft.text = "q"
        let request = draft.request(deviceId: "d", tools: [])
        #expect(request.attachments?.first?.screenshot == nil)
        #expect(draft.attachments?.first?.screenshot == true)
    }

    // MARK: - Rendering

    @Test func theEmptyResultViewsRenderAtLauncherSizes() {
        let content = Context.content(draft(Self.screenshot()), loading: false)!
        for height in [420, 300, 200] as [CGFloat] {
            render(AskLauncherContextCanvas(content: content, attachments: Self.screenshot(),
                                            highlighted: .constant(1), viewportHeight: height,
                                            onSend: { _ in }, onFill: { _ in }, onRemove: {}), height: height)
        }
        let pending = Context.content(draft(), loading: true)!
        render(AskLauncherContextCanvas(content: pending, attachments: [], highlighted: .constant(nil),
                                        viewportHeight: 400, onSend: { _ in }, onFill: { _ in }), height: 400)
        let files = Context.content(draft([Self.pdf, Self.folder]), loading: false)!
        render(AskLauncherContextCanvas(content: files, attachments: [Self.pdf, Self.folder],
                                        highlighted: .constant(nil), viewportHeight: 400,
                                        onSend: { _ in }, onFill: { _ in }), height: 400)

        let chips = [AskLauncherHome.Chip(keyword: AskKeyword(keyword: "fy", pluginID: AskTranslatePlugin.id),
                                          title: "Translate", symbol: "character.bubble")]
        for height in [420, 250, 150] as [CGFloat] {
            render(AskLauncherWelcomeView(chips: chips, teaching: height < 300, highlighted: .constant(0),
                                          settings: Self.settings, viewportHeight: height, onPick: { _ in },
                                          onEnableApps: height > 400 ? {} : nil), height: height)
        }
        let destination = AskLauncherNoMatch.Destination(
            keyword: AskKeyword(keyword: "f", pluginID: AskFileSearchPlugin.id), title: "Search in files",
            detail: "f q", symbol: "doc.text.magnifyingglass")
        render(AskLauncherNoMatchView(query: "q", searched: true, destinations: [destination],
                                      highlighted: .constant(0), onAskAI: {}, onPick: { _ in }), height: 400)
        render(AskLauncherNoMatchView(query: "q", searched: false, destinations: [], highlighted: .constant(nil),
                                      onAskAI: {}, onPick: { _ in }), height: 400)
    }

    private func render(_ view: some View, height: CGFloat) {
        let host = NSHostingView(rootView: view.frame(width: 700, height: height))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: height)
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        if let bitmap { host.cacheDisplay(in: host.bounds, to: bitmap) }
        #expect(host.fittingSize.width > 0)
    }
}
