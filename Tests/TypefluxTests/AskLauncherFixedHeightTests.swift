import AppKit
import Testing
@testable import Typeflux

/// The expanded launcher keeps one height and its primary button does not
/// flicker while a search catches up.
@Suite("Launcher fixed height and steady controls", .serialized, .exclusiveUIState)
@MainActor
struct AskLauncherFixedHeightTests {
    @Test func `typing and deleting report one launcher height`() async throws {
        let apps = AskTestAppIndex((0 ..< 8).map { AskTestAppIndex.app("Alpha \($0)", id: "fixed.\($0)") })
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "", apps: apps)
        defer { launcher.close() }
        for text in ["a", "al", "alpha", "alpha 7", "zzqqxx", "al", ""] {
            launcher.fixture.model.launcherDraft.text = text
            try await AskQuickSearchSessionTests.wait { !launcher.fixture.model.quickSearch.isSearching }
            try await Task.sleep(for: .milliseconds(30))
        }
        // The reserve settles after typing pauses; it must not change the height either.
        try await Task.sleep(for: AskLauncherHeightReserve.settleDelay + .milliseconds(100))
        #expect(!launcher.heights.isEmpty)
        #expect(Set(launcher.heights) == [AskLauncherWindowMode.expandedHeight],
                "reported heights: \(Set(launcher.heights))")
    }

    @Test func `a pending search only waits and never reads as unavailable`() throws {
        let results = try #require(AskQuickResults.search("json", sources: .init(entries: [
            AskLauncherSearchEntry(keyword: .init(keyword: "js", pluginID: "json"), title: "JSON Tools",
                                   detail: "", symbol: "curlybraces")
        ])))
        let chat = AskLauncherPrimaryAction(mode: .askAI)
        let pending = AskLauncherPrimaryAction.quickResult(results, pending: true, chat: chat)
        #expect(!pending.enabled && pending.waiting, "a search catching up is drawn as ready")
        let ready = AskLauncherPrimaryAction.quickResult(results, pending: false, chat: chat)
        #expect(ready.enabled && !ready.waiting)
        let reason = L("ask.launcher.action.input")
        let unavailable = AskLauncherPrimaryAction.confirm("Run", enabled: false, reason: reason)
        #expect(!unavailable.waiting, "missing input is a real disabled state")
    }

    @Test func `file results fill the expanded launcher and overflow remains reachable`() async throws {
        let entries = (0 ..< 24).map { ("/Users/test/r/report-\($0).pdf", AskFileRecord.Kind.file, Double($0)) }
        let host = AskQuickResultsInteractionTests.FileHost(AskTestFileIndex(entries))
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "report") { host.install(in: $0) }
        defer { launcher.close() }
        launcher.window.setContentSize(NSSize(width: AskMetrics.launcherWidth, height: AskLauncherWindowMode.expandedHeight))
        try await Task.sleep(for: .milliseconds(100))
        let view = try #require(launcher.window.contentView)
        view.layoutSubtreeIfNeeded()

        func resultScroll(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, (scroll.documentView?.bounds.height ?? 0) > 600 { return scroll }
            return view.subviews.lazy.compactMap(resultScroll(in:)).first
        }
        let scroll = try #require(resultScroll(in: view))
        let document = try #require(scroll.documentView)
        #expect(scroll.contentSize.height > 400, "the list uses the room above the toolbar")
        #expect(document.bounds.height > scroll.contentSize.height, "matching files fill the viewport and scroll")
        let results = try #require(launcher.fixture.model.quickSearch.results)
        #expect(results.files.count == 20 && results.moreFiles)

        if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] {
            let root = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: root.appendingPathComponent("launcher-many-files.png"))
        }

        // Arrow navigation must reveal and open a file beyond the initial viewport.
        let target = try #require(results.rows.firstIndex(of: .file(12)))
        for _ in 0 ... target { try await launcher.press(AskQuickResultsInteractionTests.down) }
        #expect(launcher.fixture.model.quickSearch.results?.highlightedRow == .file(12))
        #expect(scroll.contentView.bounds.minY > 0)
        try await launcher.press(AskQuickResultsInteractionTests.returnKey)
        #expect(host.urls == [results.files[12].url])
        #expect(launcher.dismissed == 1)
    }
}
