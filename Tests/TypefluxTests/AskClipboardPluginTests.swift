import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct AskClipboardPluginTests {
    @Test func `large histories remain searchable and navigable`() async throws {
        let rows = (0 ..< 300).map { index in
            ClipboardTestSupport.entry(.text, date: Date().addingTimeInterval(Double(-index * 600)),
                                       text: "History entry \(index)")
        }
        let session = AskPluginSession(plugins: [AskClipboardPlugin(entries: { rows })],
                                       keywords: { AskClipboardPlugin.keywords })
        session.enter(AskClipboardPlugin.keywords[0])
        session.update(text: "", selection: nil, language: .english)
        for _ in 0 ..< 100 where session.output == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.output?.items.count == rows.count)
        for _ in 0 ..< 50 {
            #expect(session.moveSelection(1))
        }
        #expect(session.output?.selected?.id == rows[50].id)
        session.update(text: "entry 299", selection: nil, language: .english)
        for _ in 0 ..< 100 where session.output?.original != "entry 299" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.output?.items.map(\.id) == [rows[299].id])
    }

    /// Opt-in timing uses synthetic history, never the user's clipboard contents.
    @Test func `measures first rendering of A large image history`() async throws {
        guard ProcessInfo.processInfo.environment["TYPEFLUX_CLIP_TIMING"] != nil else { return }
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sample = NSImage(size: CGSize(width: 800, height: 600))
        sample.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 800, height: 600).fill()
        sample.unlockFocus()
        let tiff = try #require(sample.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let rows = try (0 ..< 300).map { index in
            let date = Date().addingTimeInterval(Double(-index * 600))
            if index % 5 < 2 {
                let path = directory.appendingPathComponent("\(index).png")
                try png.write(to: path)
                return ClipboardTestSupport.entry(.image, date: date, imagePath: path.path)
            }
            return ClipboardTestSupport.entry(.text, date: date, text: "History entry \(index)")
        }
        let plugin = AskClipboardPlugin(entries: { rows })
        let clock = ContinuousClock()
        let started = clock.now
        let plan = await plugin.plan(request())
        let output = try await plugin.run(request(), plan: plan)
        let prepared = clock.now
        let display = AskPluginDisplay(title: plugin.title, symbol: plugin.symbol,
                                       phase: .done(plan, output), offersAskAI: false)
        let host = NSHostingView(rootView: AskPluginResultsView(
            display: display, question: "", onMain: {}, onAction: { _ in }, onAskAI: {}, onHighlight: { _ in }
        ))
        let frame = NSRect(x: 0, y: 0, width: 620, height: 400)
        let window = AskTestVoiceWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.isReleasedWhenClosed = false
        defer { window.close() }
        host.frame = frame
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        let rendered = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rendered)
        print(
            "CLIP_TIMING rows=300 images=120 prepare=\(started.duration(to: prepared)) render=\(prepared.duration(to: clock.now))"
        )
        #expect(output.items.count == 300)
    }

    private func request(text: String = "", origin: AskPluginRequest.Origin = .argument) -> AskPluginRequest {
        .init(text: text, origin: origin, keyword: AskClipboardPlugin.keywords[0], options: [:],
              interfaceLanguage: .english, selection: "Unrelated selection")
    }

    @Test func `searches content file names and apps and keeps pinned first`() async throws {
        let pinned = ClipboardTestSupport.entry(.text, date: .distantPast, text: "Project plan", isPinned: true)
        let text = ClipboardTestSupport.entry(.text, text: "PROJECT notes", sourceAppName: "Notes")
        let file = ClipboardTestSupport.entry(.files, filePaths: ["/tmp/项目设计.pdf"], sourceAppName: "Finder")
        let plugin = AskClipboardPlugin(entries: { [text, file, pinned] })
        let plan = await plugin.plan(request())
        #expect(plan.mode == .live && plugin.runsWithoutInput && plugin.entersOnReturn && !plugin.usesSelectionInput)
        #expect(plan.debounce == .zero)
        #expect(await plugin.plan(request(text: "project")).debounce == .milliseconds(100))
        let found = try await plugin.run(request(text: " project "), plan: plan)
        #expect(found.items.map(\.id) == [pinned.id, text.id])
        #expect(found.action(for: .enter)?.kind == .pasteClipboard(pinned.id))
        #expect(found.action(for: .commandC)?.kind == .copyClipboard(pinned.id))
        #expect(found.action(for: .optionEnter)?.kind == .previewClipboard(pinned.id))
        #expect(try await plugin.run(request(text: "项目"), plan: plan).items.map(\.id) == [file.id])
        #expect(try await plugin.run(request(text: "finder"), plan: plan).items.map(\.id) == [file.id])
        #expect(try await plugin.run(request(text: "ignore", origin: .selection), plan: plan).items.count == 3)
        #expect(!plugin.placeholder(selectionLines: 2).isEmpty)
        #expect(plugin.chipDetail(for: request().keyword, language: .english) == nil)
        #expect(plugin.nextOptions(after: plan, request: request(), step: 1) == nil)
    }

    @Test func `empty and no match rows do not paste`() async throws {
        var rows: [ClipboardEntry] = []
        let plugin = AskClipboardPlugin(entries: { rows })
        let plan = await plugin.plan(request())
        let empty = try await plugin.run(request(), plan: plan)
        #expect(empty.items.first?.title == L("ask.plugin.clip.empty"))
        #expect(empty.action(for: .enter) == nil && empty.action(for: .commandC) == nil)
        rows = [ClipboardTestSupport.entry(.text, text: "hello")]
        let missing = try await plugin.run(request(text: "missing"), plan: plan)
        #expect(missing.items.first?.title == L("ask.plugin.clip.noMatch"))
        #expect(missing.items.allSatisfy { !$0.valid })
        #expect(try await plugin.run(request(text: "hello"), plan: plan).items.first?.id == rows[0].id)
    }

    @Test func `media rows preserve image and file types`() async throws {
        let image = ClipboardTestSupport.entry(.image, imagePath: "/tmp/shot.png")
        let file = ClipboardTestSupport.entry(.files, filePaths: ["/tmp/report.pdf"])
        let plugin = AskClipboardPlugin(entries: { [image, file] })
        let output = try await plugin.run(request(), plan: plugin.plan(request()))
        #expect(output.items.first { $0.id == image.id }?.icon == .image(URL(fileURLWithPath: "/tmp/shot.png")))
        #expect(output.items.first { $0.id == file.id }?.icon == .fileIcon(URL(fileURLWithPath: "/tmp/report.pdf")))
    }

    @Test func `keyword migrates and honors existing names and workflow reservations`() {
        let previous = AskPluginRegistry.defaultKeywords.filter { $0.pluginID != AskClipboardPlugin.id }
        let known = AskPluginRegistry.coveredGroups.filter { $0 != AskClipboardPlugin.id }
        let migrated = AskPluginRegistry.keywords(saved: previous, known: known)
        #expect(migrated.contains(AskClipboardPlugin.keywords[0]))
        let custom = AskKeyword(keyword: "CLIP", pluginID: AskWebSearchPlugin.id)
        #expect(!AskPluginRegistry.keywords(saved: previous + [custom], known: known)
            .contains { $0.pluginID == AskClipboardPlugin.id })
        #expect(!AskPluginRegistry.keywords(saved: previous, known: known, reserved: ["clip"])
            .contains { $0.pluginID == AskClipboardPlugin.id })
        #expect(AskKeywordMatcher.match("clipboard", keywords: migrated) == nil)
        let draft = AskKeywordDraft(editing: AskClipboardPlugin.keywords[0])
        #expect(draft.kind == .clip && draft.fieldProblem == nil && draft.result() == AskClipboardPlugin.keywords[0])
        #expect(draft.displayName == AskKeywordKind.clip.title)
        #expect(AskKeywordSection.typeflux.kinds.contains(.clip))
    }

    @Test func `entering clip shows history without sending A question`() async throws {
        let f = try AskTestFixture()
        let entry = ClipboardTestSupport.entry(.text, text: "Local clipboard")
        f.model.clipboardEntries = { [entry] }
        f.model.launcherDraft = AskDraft(text: "clip", selection: "Selected text")
        #expect(f.model.enterLauncherKeywordFromText(pluginID: AskClipboardPlugin.id))
        try await f.wait { f.model.plugins.output != nil }
        #expect(f.model.plugins.output?.items.first?.id == entry.id)
        #expect(await f.api.sends.isEmpty)
        f.model.plugins.deactivate()
        let searchEntry = try #require(f.model.launcherSearchEntries(language: .english)
            .first { $0.keyword.pluginID == AskClipboardPlugin.id })
        f.model.enterLauncherSearchEntry(searchEntry)
        try await f.wait { f.model.plugins.output != nil }
        #expect(f.model.plugins.output?.items.first?.id == entry.id)
    }

    @Test func `text pastes after closing and copy keeps launcher open`() async throws {
        let f = try AskTestFixture()
        let entry = ClipboardTestSupport.entry(.text, text: "Exact\ncontent")
        f.model.clipboardEntries = { [entry] }
        var delivered: [String] = []
        f.model.deliverText = { delivered.append($0) }
        f.model.plugins.enter(AskClipboardPlugin.keywords[0])
        f.model.launcherDraft.text = "clip"
        let board = NSPasteboard(name: .init("AskClipboardPluginTests-" + UUID().uuidString))
        let previous = AskQuickResults.pasteboard
        AskQuickResults.pasteboard = board
        defer { AskQuickResults.pasteboard = previous; board.releaseGlobally() }
        #expect(f.model.applyLauncherClipboard(id: entry.id, paste: false) == .stay)
        #expect(board.string(forType: .string) == entry.text && f.model.plugins.isActive && delivered.isEmpty)
        #expect(f.model.applyLauncherClipboard(id: entry.id, paste: true) == .close)
        #expect(!f.model.plugins.isActive && f.model.launcherDraft.text.isEmpty && delivered.isEmpty)
        try await f.wait { delivered == [entry.text!] }
    }

    @Test func `files copy and paste through existing content actions`() async throws {
        let f = try AskTestFixture()
        let directory = ClipboardTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = ClipboardTestSupport.makeFile(named: "report.pdf", in: directory)
        let entry = ClipboardTestSupport.entry(.files, filePaths: [file.path])
        let actions = ClipboardPluginTestActions()
        f.model.clipboardContentActions = actions
        f.model.clipboardEntries = { [entry] }
        f.model.plugins.enter(AskClipboardPlugin.keywords[0])
        #expect(f.model.applyLauncherClipboard(id: entry.id, paste: false) == .stay)
        #expect(actions.writes == [entry] && actions.pastes == 0 && f.model.plugins.isActive)
        #expect(f.model.applyLauncherClipboard(id: entry.id, paste: true) == .close)
        #expect(actions.writes == [entry, entry] && actions.pastes == 0 && !f.model.plugins.isActive)
        try await f.wait { actions.pastes == 1 }
        actions.succeeds = false
        #expect(f.model.applyLauncherClipboard(id: entry.id, paste: true) == .stay)
    }

    @Test func `deleted entries and missing files cannot change clipboard or paste`() throws {
        let f = try AskTestFixture()
        let entry = ClipboardTestSupport.entry(.files, filePaths: ["/missing/clip-test.pdf"])
        let actions = ClipboardPluginTestActions()
        f.model.clipboardContentActions = actions
        f.model.clipboardEntries = { [entry] }
        #expect(f.model.applyLauncherClipboard(id: entry.id, paste: true) == .stay)
        f.model.clipboardEntries = { [] }
        #expect(f.model.applyLauncherClipboard(id: entry.id, paste: false) == .stay)
        #expect(actions.writes.isEmpty && actions.pastes == 0)
    }

    @Test func `preview shows full content and clears when launcher closes`() throws {
        let f = try AskTestFixture()
        let entry = ClipboardTestSupport.entry(.text, text: "First line\nSecond line")
        f.model.clipboardEntries = { [entry] }
        let action = AskPluginAction(kind: .previewClipboard(entry.id), title: "", symbol: "")
        #expect(f.model.performPluginAction(action) == .stay)
        #expect(f.model.launcherClipboardPreview == entry)
        f.model.finishPluginResult()
        #expect(f.model.launcherClipboardPreview == nil)
        _ = f.model.performPluginAction(action)
        f.model.foldLauncherKeyword()
        #expect(f.model.launcherClipboardPreview == nil)
        f.model.clipboardEntries = { [] }
        #expect(f.model.performPluginAction(action) == .stay && f.model.launcherClipboardPreview == nil)
    }

    @Test func `render clipboard launcher and preview`() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment["TYPEFLUX_CLIP_SNAPSHOTS"] else { return }
        let output = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let f = try AskTestFixture()
        let text = ClipboardTestSupport.entry(.text, text: "项目待办\n检查剪贴板搜索、预览和粘贴。\n保留原始内容与换行。",
                                              sourceAppName: "备忘录", isPinned: true)
        let link = ClipboardTestSupport.entry(.link, text: "https://typeflux.ai", sourceAppName: "Safari")
        f.model.clipboardEntries = { [text, link] }
        f.model.launcherDraft.text = "clip"
        #expect(f.model.enterLauncherKeywordFromText(pluginID: AskClipboardPlugin.id))
        try await f.wait { f.model.plugins.output != nil }
        #expect(f.model.plugins.output?.items.first?.title == "项目待办 检查剪贴板搜索、预览和粘贴。 保留原始内容与换行。")
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let window = AskTestVoiceWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 400),
                                            styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            let hosting = NSHostingView(rootView: AskLauncherView(model: f.model, onDismiss: {}))
            hosting.frame = NSRect(x: 0, y: 0, width: 620, height: 400)
            window.contentView = hosting
            window.orderFront(nil)
            defer { window.orderOut(nil); window.close() }
            try await Task.sleep(for: .milliseconds(500))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("clip-\(name).png"))
            _ = f.model.performPluginAction(.init(kind: .previewClipboard(text.id), title: "", symbol: ""))
            try await Task.sleep(for: .milliseconds(500))
            let previewWindow = try #require(window.childWindows?.first { $0.isVisible })
            let preview = try #require(previewWindow.contentView)
            preview.layoutSubtreeIfNeeded()
            // Scroll views draw through layers that view caching can omit. Capture this test's own window.
            let previewImage = try #require(CGWindowListCreateImage(
                .null, .optionIncludingWindow, CGWindowID(previewWindow.windowNumber),
                [.boundsIgnoreFraming, .bestResolution]
            ))
            let previewBitmap = NSBitmapImageRep(cgImage: previewImage)
            try #require(previewBitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("clip-preview-\(name).png"))
            f.model.launcherClipboardPreview = nil
        }
        f.model.finishPluginResult()
    }
}

private final class ClipboardPluginTestActions: ClipboardContentActing {
    var writes: [ClipboardEntry] = []
    var pastes = 0
    var succeeds = true
    func writeToPasteboard(_ entry: ClipboardEntry, asPlainText _: Bool) -> Bool {
        writes.append(entry)
        return succeeds
    }

    func sendPasteShortcut() {
        pastes += 1
    }

    func revealInFinder(_: [URL]) {}
    func saveToDownloads(_: URL) -> URL? {
        nil
    }

    func recognizeText(in _: URL) async -> String? {
        nil
    }
}
