import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Launcher search settings page", .serialized)
@MainActor
struct LauncherSearchSettingsViewTests {
    private func store() throws -> (SettingsStore, UserDefaults, String) {
        let suite = "launcher-search-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (SettingsStore(defaults: defaults), defaults, suite)
    }

    /// Lays the page out in a window, so every row is built.
    private func render(_ view: some View) async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 1200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: view.frame(width: 760, alignment: .top))
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0)
    }

    @Test func everyTabRendersInEveryState() async throws {
        let (settings, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        var search = AskLauncherSearchSettings()
        search.fileRoots = []
        search.excludedExtensions = ["log"]
        settings.askLauncherSearchSettings = search
        let index = AskTestFileIndex()
        for status in [AskFileIndexStatus(phase: .building(found: 10, estimate: 20)),
                       AskFileIndexStatus(phase: .ready, count: 5, bytes: 1000, updatedAt: Date(), truncated: true)] {
            index.status = status
            for tab in LauncherSearchSettingsView.Tab.allCases {
                for access in [true, false] {
                    try await render(LauncherSearchSettingsView(settings: settings, index: index,
                                                                fullDiskAccess: { access }, tab: tab))
                }
                #expect(!tab.title.hasPrefix("launcher.search"))
            }
        }
    }

    @Test func changesAreSavedAndAnnounced() throws {
        let (settings, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        // The view is not on screen, so its state stays at the defaults: each change starts from them.
        let view = LauncherSearchSettingsView(settings: settings, index: AskTestFileIndex())
        var posted = 0
        let observer = NotificationCenter.default.addObserver(forName: .askLauncherSearchSettingsDidChange,
                                                              object: settings, queue: nil) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        view.reload()
        view.update { $0.mode = .filesFirst }
        #expect(settings.askLauncherSearchSettings.mode == .filesFirst)
        #expect(posted == 1)
        view.update { _ in }
        #expect(posted == 1, "no change, no save")
        view.update { $0.fileRoots = LauncherSearchSettingsView.adding(
            [NSHomeDirectory() + "/Work", "/Volumes/X"],
            to: $0.fileRoots
        ) }
        #expect(settings.askLauncherSearchSettings.fileRoots == ["~", "~/Work", "/Volumes/X"])
    }

    @Test func `moved switches save existing preferences and follow the index lifecycle`() throws {
        let (settings, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        let index = AskTestFileIndex()
        let view = LauncherSearchSettingsView(settings: settings, index: index)
        for enabled in [false, true] {
            view.setAppsEnabled(enabled)
            #expect(settings.askQuickAppSearchEnabled == enabled)
            #expect(SettingsStore(defaults: defaults).askQuickAppSearchEnabled == enabled)
            view.setFilesEnabled(enabled)
            #expect(settings.askQuickFileSearchEnabled == enabled)
            #expect(SettingsStore(defaults: defaults).askQuickFileSearchEnabled == enabled)
        }
        #expect(index.starts == 2, "both off and on notify the injected index")
        #expect(settings.askQuickCalculatorEnabled, "search switches do not change the calculator")
    }

    @Test func `moved file switch clears and rebuilds A real index`() throws {
        let (settings, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("fixture".utf8).write(to: root.appendingPathComponent("Report.txt"))
        var search = AskLauncherSearchSettings()
        search.fileRoots = [root.path]
        settings.askLauncherSearchSettings = search
        let snapshot = root.appendingPathComponent("index.bin")
        let index = AskFileIndex(
            configuration: { (settings.askQuickFileSearchEnabled, settings.askLauncherSearchSettings) },
            fullDiskAccess: { true },
            snapshotURL: snapshot,
            defaults: defaults,
            home: root.path,
            makeWatcher: { AskTestFileWatcher() }
        )
        let view = LauncherSearchSettingsView(settings: settings, index: index)
        view.setFilesEnabled(true)
        index.waitUntilIdle()
        #expect(index.status.phase == .ready && index.status.count > 0)
        #expect(FileManager.default.fileExists(atPath: snapshot.path))
        view.setFilesEnabled(false)
        index.waitUntilIdle()
        #expect(index.status.phase == .off && index.status.count == 0)
        #expect(!FileManager.default.fileExists(atPath: snapshot.path))
        view.setFilesEnabled(true)
        index.waitUntilIdle()
        #expect(index.search(AskSearchQuery("Report"), options: AskFileSearchOptions()).first?.name == "Report.txt")
        view.setFilesEnabled(false)
        index.waitUntilIdle()
    }

    @Test func pathsAreAddedOnceWithTheHomeShortened() {
        #expect(LauncherSearchSettingsView.adding([NSHomeDirectory() + "/A", "/B"], to: ["~/A"]) == ["~/A", "/B"])
        #expect(LauncherSearchSettingsView.adding([], to: ["~"]) == ["~"])
    }

    @Test func statusReadsInWords() {
        #expect(LauncherSearchSettingsView.phaseText(AskFileIndexStatus(phase: .ready), enabled: false)
            == L("launcher.search.index.off"))
        #expect(LauncherSearchSettingsView.phaseText(AskFileIndexStatus(phase: .off), enabled: true)
            == L("launcher.search.index.off"))
        #expect(LauncherSearchSettingsView.phaseText(AskFileIndexStatus(phase: .loading), enabled: true)
            == L("launcher.search.index.loading"))
        #expect(LauncherSearchSettingsView.phaseText(AskFileIndexStatus(phase: .building(found: 1200, estimate: nil)),
                                                     enabled: true).contains("1"))
        #expect(LauncherSearchSettingsView.phaseText(AskFileIndexStatus(phase: .ready), enabled: true)
            == L("launcher.search.index.live"))
        #expect(LauncherSearchSettingsView.phaseText(AskFileIndexStatus(phase: .ready, truncated: true), enabled: true)
            == L("launcher.search.index.truncated"))
    }
}

@Suite("Ask quick file and app actions", .serialized)
@MainActor
struct AskQuickFileActionTests {
    private final class Host {
        var urls: [URL] = []
        var revealed: [URL] = []
        var openedWith: [(URL, URL)] = []
        var trashed: [URL] = []
        var trashWorks = true
        var openedApps: [URL] = []
    }

    private func fixture(_ host: Host, index: AskTestFileIndex) throws -> AskTestFixture {
        let fixture = try AskTestFixture()
        fixture.model.fileIndex = index
        fixture.model.appIndex = AskTestAppIndex([])
        fixture.model.fileExists = { _ in true }
        fixture.model.openURL = { host.urls.append($0) }
        fixture.model.revealFile = { host.revealed.append($0) }
        fixture.model.openFileWith = { host.openedWith.append(($0, $1)) }
        fixture.model.trashFile = { url in host.trashed.append(url); return host.trashWorks }
        fixture.model.openApplication = { host.openedApps.append($0) }
        return fixture
    }

    private let file = AskFileHit(path: "/tmp/Report Q3.pdf", name: "Report Q3.pdf", kind: .file, modified: Date(), score: 1)
    private let folder = AskFileHit(path: "/tmp/My Folder", name: "My Folder", kind: .folder, modified: Date(), score: 1)

    @Test func fileActionsDoWhatTheySay() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ask.quick.actions.\(UUID().uuidString)"))
        let previous = AskQuickResults.pasteboard
        AskQuickResults.pasteboard = pasteboard
        defer { AskQuickResults.pasteboard = previous; pasteboard.releaseGlobally() }
        let host = Host(), index = AskTestFileIndex()
        let fixture = try fixture(host, index: index)
        defer { fixture.model.resetSession() }
        let model = fixture.model

        #expect(model.performQuickFileAction(.copyName, file) == .close)
        #expect(pasteboard.string(forType: .string) == "Report Q3.pdf")
        #expect(model.performQuickFileAction(.copyPath, file) == .close)
        #expect(pasteboard.string(forType: .string) == "/tmp/Report Q3.pdf")
        #expect(model.performQuickFileAction(.copyFile, file) == .close)
        #expect((pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first?.path == "/tmp/Report Q3.pdf")

        let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
        #expect(model.performQuickFileAction(.openIn(preview), file) == .close)
        #expect(host.openedWith.last?.1 == preview)
        #expect(index.opened == ["/tmp/Report Q3.pdf"])
        #expect(model.performQuickFileAction(.openInTerminal, folder) == .close)
        #expect(host.openedWith.last?.1.lastPathComponent == "Terminal.app")
        #expect(model.performQuickFileAction(.reveal, file) == .close)
        #expect(host.revealed.count == 1)
        #expect(model.performQuickFileAction(.quit, file) == .stay)

        guard case let .text(text) = model.performQuickFileAction(.searchInFolder, folder) else {
            Issue.record("searching in a folder fills the editor"); return
        }
        #expect(text == "f in:MyFolder ")

        // Open With lists applications, or just opens when there are none.
        switch model.performQuickFileAction(.openWith, file) {
        case let .panel(panel): #expect(panel.actions.allSatisfy { if case .openIn = $0 { true } else { false } })
        case .close: #expect(host.urls.count == 1)
        default: Issue.record("Open With either lists applications or opens")
        }

        host.trashWorks = false
        #expect(model.performQuickFileAction(.trash, file) == .stay, "a failed move keeps the launcher open")
        host.trashWorks = true
        #expect(model.performQuickFileAction(.trash, file) == .close)
        #expect(index.forgotten == ["/tmp/Report Q3.pdf"])
    }

    @Test func appActionsDoWhatTheySay() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ask.quick.actions.\(UUID().uuidString)"))
        let previous = AskQuickResults.pasteboard
        AskQuickResults.pasteboard = pasteboard
        defer { AskQuickResults.pasteboard = previous; pasteboard.releaseGlobally() }
        let host = Host()
        let fixture = try fixture(host, index: AskTestFileIndex())
        defer { fixture.model.resetSession() }
        let app = AskTestAppIndex.app("Notes", id: "test.notes.never.running")
        #expect(fixture.model.performQuickAppAction(.reveal, app) == .close)
        #expect(host.revealed == [app.url])
        #expect(fixture.model.performQuickAppAction(.copyPath, app) == .close)
        #expect(pasteboard.string(forType: .string) == app.url.path)
        #expect(fixture.model.performQuickAppAction(.quit, app) == .close, "nothing to quit, still done")
        #expect(fixture.model.performQuickAppAction(.open, app) == .close)
        #expect(host.openedApps == [app.url])
        let pane = AskAppEntry(name: "网络", url: URL(fileURLWithPath: "/x.appex"), bundleID: "com.apple.Network-Settings.extension",
                               names: [], kind: .settingsPane)
        fixture.model.openQuickApp(pane)
        #expect(host.urls.last?.absoluteString == "x-apple.systempreferences:com.apple.Network-Settings.extension")
    }
}

@Suite("Ask FSEvents watcher", .serialized)
struct AskFSEventsWatcherTests {
    @Test func reportsChangesInAWatchedFolder() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ask-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // FSEvents reports real paths: /private/var/…, not /var/….
        let folder = URL(fileURLWithPath: AskFileScope.canonical(base.path))
        defer { try? FileManager.default.removeItem(at: folder) }
        let watcher = AskFSEventsWatcher()
        watcher.latency = 0.05
        let seen = Seen()
        watcher.start(paths: [folder.path], since: nil) { changes, id in seen.add(changes.map(\.path), id) }
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))
        let file = folder.appendingPathComponent("new.txt")
        try Data("x".utf8).write(to: file)
        for _ in 0 ..< 100 where !seen.paths.contains(file.path) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(seen.paths.contains(file.path))
        #expect(seen.lastID > 0)
        #expect(AskFSEventsWatcher.currentEventID > 0)
        watcher.start(paths: [], since: nil) { _, _ in }
        watcher.stop()
    }

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var storedPaths: [String] = []
        private var storedID: UInt64 = 0
        var paths: [String] { lock.withLock { storedPaths } }
        var lastID: UInt64 { lock.withLock { storedID } }
        func add(_ paths: [String], _ id: UInt64) { lock.withLock { storedPaths += paths; storedID = max(storedID, id) } }
    }
}
