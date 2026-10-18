import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Application continue history")
@MainActor
struct AskAppContinueHistoryTests {
    @Test func recordsOnlyKnownApplicationAndKeepsMostRecentFileFirst() throws {
        let defaults = try #require(UserDefaults(suiteName: "app-continue-\(UUID().uuidString)"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first.txt")
        let second = folder.appendingPathComponent("second.txt")
        try Data().write(to: first)
        try Data().write(to: second)
        let app = AskTestAppIndex.app("Editor", id: "test.editor")
        let other = AskTestAppIndex.app("Other", id: "test.other")
        let history = AskAppContinueHistory(defaults: defaults)
        history.record(first, applicationID: app.id)
        history.record(second, applicationID: other.id)
        history.record(second, applicationID: app.id)
        history.record(first, applicationID: app.id)
        #expect(history.recent(for: app).map(\.path) == [first.path, second.path])
        #expect(history.recent(for: other).map(\.path) == [second.path])
        #expect(AskAppContinueHistory(defaults: defaults).recent(for: app).map(\.path) == [first.path, second.path])
        try FileManager.default.removeItem(at: first)
        #expect(history.recent(for: app).map(\.path) == [second.path])
    }

    @Test func filterMatchesTitleAndLocation() {
        let record = AskAppContinueHistory.Record(applicationID: "editor", path: "/Projects/Typeflux/Plan.md",
                                                  openedAt: Date())
        let item = AskAppContinueItem.file(record)
        #expect(item.matches("Plan"))
        #expect(item.matches("Typeflux"))
        #expect(!item.matches("unrelated"))
    }
}

extension AskQuickResultsInteractionTests {
    @Test func appRightArrowOpensContinueListAndReturnOpensRecordedFile() async throws {
        try await withPasteboard { _ in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("Plan.md")
            try Data().write(to: file)
            let app = AskTestAppIndex.app("Editor", id: "test.editor")
            var opened: [(URL, URL)] = []
            let launcher = try await Launcher(text: "Editor", apps: AskTestAppIndex([app]), prepare: { model in
                model.appContinueHistory.record(file, applicationID: app.id)
                model.openFileWith = { opened.append(($0, $1)) }
            })
            defer { launcher.close() }
            try await launcher.press(124)
            try await launcher.press(Self.returnKey)
            #expect(opened.count == 1)
            #expect(opened.first?.0 == file && opened.first?.1 == app.url)
            #expect(launcher.dismissed == 1)
            #expect(await launcher.fixture.api.sends.isEmpty)
        }
    }
}

@Suite("Application continue preview", .serialized, .exclusiveUIState)
@MainActor
struct AskAppContinuePreviewTests {
    @Test func renderDarkAndLight() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_APP_CONTINUE_SNAPSHOTS"] else { return }
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let chromeURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: AskSearchBrowser.chrome.bundleID)
            ?? URL(fileURLWithPath: "/Applications/Google Chrome.app")
        let app = AskAppEntry(name: "Google Chrome", url: chromeURL,
                              bundleID: AskSearchBrowser.chrome.bundleID, names: ["Google Chrome"])
        let tab = AskBrowserSearchEntry(id: "design", kind: .tab, browser: .chrome,
                                        title: "Typeflux · 产品设计", url: "https://example.com/design")
        let file = AskAppContinueHistory.Record(applicationID: app.id, path: "/Users/demo/Documents/产品方案.pdf",
                                                openedAt: Date())
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let size = NSSize(width: 620, height: 360)
            let window = AskTestVoiceWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                            backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            let view = AskAppContinueView(app: app, items: [.tab(tab), .file(file)], selected: 1,
                                          loading: false, permissionIssue: false, query: "", viewportHeight: 360,
                                          onBack: {}, onOpenApp: {}, onOpenItem: { _ in }, onSelect: { _ in })
            let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
                .background(StudioTheme.surface))
            hosting.frame = NSRect(origin: .zero, size: size)
            window.contentView = hosting
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(400))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: root.appendingPathComponent("app-continue-\(name).png"))
            #expect(png.count > 4000)
            window.close()
        }
    }
}
