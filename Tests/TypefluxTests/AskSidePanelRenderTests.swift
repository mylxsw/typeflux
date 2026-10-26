import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Renders the side panel's Files tab and each kind of file tab.
/// Set `TYPEFLUX_BROWSER_SNAPSHOTS=<dir>` to keep the PNGs.
@Suite("Ask side panel rendering", .serialized, .exclusiveUIState)
@MainActor
struct AskSidePanelRenderTests {
    /// Renders `root`, keeps a PNG when asked, and returns the accessibility text it shows.
    @discardableResult
    private func render(_ root: some View, name: String, size: NSSize = NSSize(width: 520, height: 640),
                        dark: Bool = false, settle: Duration = .milliseconds(300)) async throws -> [String] {
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous ?? false, forAttribute: attribute) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: AnyView(root.environment(\.askGlassMaterialOverride, .opaque)))
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: settle)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(data.count > 6000, "\(name) rendered blank")
        if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_BROWSER_SNAPSHOTS"] {
            let url = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try data.write(to: url.appendingPathComponent("\(name).png"))
        }
        return texts(in: window)
    }

    private func texts(in window: NSWindow) -> [String] {
        var result: [String] = []
        var seen = Set<ObjectIdentifier>()
        func walk(_ element: Any) {
            guard let object = element as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            for key in ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"]
                where object.responds(to: NSSelectorFromString(key)) {
                if let text = object.value(forKey: key) as? String, !text.isEmpty { result.append(text) }
            }
            guard object.responds(to: NSSelectorFromString("accessibilityChildren")) else { return }
            for child in object.value(forKey: "accessibilityChildren") as? [Any] ?? [] { walk(child) }
        }
        walk(window)
        return result
    }

    @Test func previewDiagnosticsAreDeduplicated() {
        #expect(AskFilePreviewNotice.details("  resource failed\nresource failed\n\nOther error ") ==
                ["resource failed", "Other error"])
        #expect(AskFilePreviewNotice.details(" \n") == [])
    }

    @Test(arguments: [false, true])
    func previewNoticeRendersCollapsedAndExpanded(dark: Bool) async throws {
        for expanded in [false, true] {
            let labels = try await render(
                VStack {
                    AskFilePreviewNotice(message: "Resource failed\nResource failed\nScript error",
                                         isExpanded: expanded)
                    Spacer()
                }.padding(8), name: "preview-notice-\(dark)-\(expanded)",
                size: NSSize(width: 360, height: 180), dark: dark)
            #expect(labels.contains { $0.contains(L("ask.sidePanel.file.previewIssue")) })
            #expect(labels.contains { $0.contains("Script error") } == expanded)
        }
    }

    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("side-panel-render-" + UUID().uuidString)
        let manager = FileManager.default
        for folder in ["inputs", "outputs", "work"] {
            try manager.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let files: [String: String] = [
            "inputs/0123456789abcdef-fedcba9876543210-sales.csv": "region,q1,q2\nNorth,\"1,200\",900\nSouth,800,950\n",
            "outputs/report.html": "<h1 style='font:20px sans-serif'>Quarterly report</h1><p>Revenue grew.</p>",
            "outputs/summary.md": "# Summary\n\n- North leads\n- South grows\n\n```swift\nprint(1)\n```",
            "work/clean.py": "import csv\nrows = list(csv.reader(open('sales.csv')))\nprint(len(rows))\n",
            "work/blob.bin": "\u{0}\u{1}\u{2}"
        ]
        for (path, text) in files { try Data(text.utf8).write(to: root.appendingPathComponent(path)) }
        let pdf = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let consumer = try #require(CGDataConsumer(data: pdf as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 20, y: 20, width: 160, height: 160))
        context.endPDFPage(); context.closePDF()
        try (pdf as Data).write(to: root.appendingPathComponent("outputs/chart.pdf"))
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
        try png.write(to: root.appendingPathComponent("outputs/1b4e28ba-2fa1-11d2-883f-0016d3cca427-dot.png"))
        return root
    }

    private func listing(_ root: URL) -> [AskWorkspaceFile] {
        let now = Date()
        return [
            ("inputs/0123456789abcdef-fedcba9876543210-sales.csv", AskWorkspaceFile.Origin.upload, "m1", 300.0),
            ("outputs/report.html", .generated, nil, 120), ("outputs/summary.md", .generated, nil, 100),
            ("outputs/chart.pdf", .generated, nil, 90),
            ("outputs/1b4e28ba-2fa1-11d2-883f-0016d3cca427-dot.png", .generated, nil, 80),
            ("work/clean.py", .process, nil, 60), ("work/blob.bin", .process, nil, 30)
        ].map { path, origin, message, age in
            AskWorkspaceFile(relativePath: path, size: 1200, modifiedAt: now.addingTimeInterval(-age),
                             origin: origin, messageId: message)
        }
    }

    private func context(_ root: URL, opened: @escaping ([URL]) -> Void = { _ in }) -> AskSidePanelContext {
        AskSidePanelContext(conversationId: "c1", messageOrder: ["m1"],
                            messageTitle: { $0 == "m1" ? "Analyse the sales sheet" : nil },
                            roots: { [root.path] }, addFiles: opened)
    }

    @Test func filesTabListsGroupsAndFilters() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let panel = AskSidePanel(browser: nil)
        await panel.refreshFiles(conversationId: "c1") { (root, listing(root)) }
        panel.prepareForPresentation()
        let labels = try await render(AskSidePanelView(panel: panel, context: context(root), close: {}),
                                      name: "side-panel-files")
        #expect(labels.contains { $0.contains("sales.csv") })
        #expect(labels.contains { $0.contains("Analyse the sales sheet") })
        #expect(!labels.contains { $0.contains("0123456789abcdef") }, "Stored prefixes stay hidden")

        let suite = "AskSidePanelRenderTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "ask.sidePanel.filesGrid")
        panel.fileQuery.origin = .generated
        try await render(AskSidePanelView(panel: panel, context: context(root), close: {}).defaultAppStorage(defaults),
                         name: "side-panel-files-grid", dark: true)
        panel.fileQuery.search = "nothing matches"
        try await render(AskSidePanelView(panel: panel, context: context(root), close: {}),
                             name: "side-panel-files-no-match")
    }

    @Test func filesTabEmptyStates() async throws {
        let panel = AskSidePanel(browser: nil)
        try await render(AskSidePanelView(panel: panel, context: AskSidePanelContext(), close: {}),
                         name: "side-panel-no-conversation")
        await panel.refreshFiles(conversationId: "c1") { nil }
        try await render(AskSidePanelView(panel: panel, context: AskSidePanelContext(conversationId: "c1"),
                                          close: {}), name: "side-panel-empty")
        struct Failure: LocalizedError { var errorDescription: String? { "The workspace is unavailable." } }
        await panel.refreshFiles(conversationId: "c1") { throw Failure() }
        panel.notice = L("ask.sidePanel.file.denied")
        let labels = try await render(AskSidePanelView(panel: panel, context: AskSidePanelContext(conversationId: "c1"),
                                                       close: {}), name: "side-panel-error")
        #expect(labels.contains { $0.contains("The workspace is unavailable.") })
    }

    @Test(arguments: [
        ("outputs/report.html", false), ("outputs/report.html", true), ("outputs/summary.md", false),
        ("outputs/summary.md", true), ("inputs/0123456789abcdef-fedcba9876543210-sales.csv", false),
        ("inputs/0123456789abcdef-fedcba9876543210-sales.csv", true), ("work/clean.py", false),
        ("outputs/chart.pdf", false), ("outputs/1b4e28ba-2fa1-11d2-883f-0016d3cca427-dot.png", false),
        ("work/blob.bin", false)
    ])
    func fileTabsPreviewEachFormat(path: String, source: Bool) async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let panel = AskSidePanel(browser: nil)
        await panel.refreshFiles(conversationId: "c1") { (root, listing(root)) }
        let target = try AskSidePanelFileAccess.resolve(path, workspaceRoot: root)
        let tab = try panel.open(target, conversationId: "c1",
                                 kind: path.hasSuffix(".bin") ? .unsupported : nil)
        tab.showsSource = source
        let name = "side-panel-file-" + (path as NSString).pathExtension + (source ? "-source" : "")
        let labels = try await render(AskSidePanelView(panel: panel, context: context(root), close: {}),
                                      name: name, size: NSSize(width: 380, height: 640),
                                      settle: .milliseconds(path.hasSuffix(".html") ? 900 : 400))
        #expect(labels.contains { $0.contains(tab.name) })
    }

    @Test func fileTabShowsWhyAFileCannotOpen() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let panel = AskSidePanel(browser: nil)
        let target = try AskSidePanelFileAccess.resolve("work/clean.py", workspaceRoot: root)
        try panel.open(target, conversationId: "c1")
        // The folder grant behind the tab was revoked.
        let context = AskSidePanelContext(conversationId: "c1", roots: { ["/elsewhere"] })
        let labels = try await render(AskSidePanelView(panel: panel, context: context, close: {}),
                                      name: "side-panel-file-denied")
        #expect(labels.contains { $0.contains(L("ask.sidePanel.file.denied")) })
    }

    // MARK: Files changed this round

    @Test func summariesNameHowAModifiedFileChanged() {
        #expect(AskWorkspaceFileChange(path: "a", kind: .added, writes: 1).summary == nil, "New files need no note")
        #expect(AskWorkspaceFileChange(path: "a", kind: .modified).summary == nil)
        #expect(AskWorkspaceFileChange(path: "a", kind: .modified, writes: 1, edits: 2).summary
            == L("ask.fileChanges.rewritten"))
        #expect(AskWorkspaceFileChange(path: "a", kind: .modified, edits: 2).summary == L("ask.fileChanges.edited", 2))
        #expect(AskFileChangesView.countText(added: 2, modified: 1)
            == L("ask.fileChanges.added", 2) + " · " + L("ask.fileChanges.modified", 1))
        #expect(AskFileChangesView.countText(added: 0, modified: 3) == L("ask.fileChanges.modified", 3))
        #expect(AskFileChangesView.countText(added: 0, modified: 0).isEmpty)
        let ref = AskArtifactRef(id: "abcdef1234", ownerId: "o", conversationId: "c", runId: "r", version: "v",
                                 mediaType: "text/html", sizeBytes: 1, sha256: "s", cleanup: "none")
        #expect(AskArtifactTab.defaultName(ref) == L("ask.sidePanel.artifact") + " abcdef12.html")
        var zip = ref
        zip.mediaType = "application/vnd.api+json"
        #expect(AskArtifactTab.defaultName(zip) == L("ask.sidePanel.artifact") + " abcdef12")
    }

    @Test func theChangesBlockListsFilesAndFoldsWorkFiles() async throws {
        let ref = AskArtifactRef(id: "artifact-1", ownerId: "o", conversationId: "c1", runId: "r", version: "v",
                                 mediaType: "text/html", sizeBytes: 2048, sha256: "s", cleanup: "device_30_days")
        let list = AskFileChangeList(changes: [
            .init(path: "outputs/1b4e28ba-2fa1-11d2-883f-0016d3cca427-report.html", kind: .added),
            .init(path: "outputs/summary.md", kind: .modified, edits: 2),
            .init(path: "work/clean.py", kind: .added), .init(path: "work/notes.txt", kind: .modified)
        ], artifacts: [.init(ref: ref, name: "dashboard.html")])
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let actions = AskSidePanelActions(fileURL: { root.appendingPathComponent($0) })
        for dark in [false, true] {
            let labels = try await render(AskFileChangesView(list: list, actions: actions).padding().frame(width: 560),
                                          name: "file-changes" + (dark ? "-dark" : ""),
                                          size: NSSize(width: 600, height: 320), dark: dark)
            #expect(labels.contains { $0.contains(L("ask.fileChanges.title")) })
            #expect(labels.contains { $0.contains(AskFileChangesView.countText(added: 3, modified: 2)) })
            #expect(labels.contains { $0.contains("report.html") })
            #expect(labels.contains { $0.contains(L("ask.fileChanges.edited", 2)) })
            #expect(labels.contains { $0.contains("dashboard.html") })
            #expect(labels.contains { $0.contains(L("ask.fileChanges.process", 2)) })
            #expect(!labels.contains { $0.contains("clean.py") }, "Work files stay folded")
        }
    }

    @Test func filesAndFileTabsOfferLocatingTheirMessage() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let panel = AskSidePanel(browser: nil)
        await panel.refreshFiles(conversationId: "c1") { (root, listing(root)) }
        panel.prepareForPresentation()
        var located: [String] = []
        var context = context(root)
        context.locateMessage = { located.append($0) }
        let labels = try await render(AskSidePanelView(panel: panel, context: context, close: {}),
                                      name: "side-panel-files-locate")
        #expect(labels.filter { $0.contains(L("ask.sidePanel.locateMessage")) }.count == 1,
                "Only the group of a message in this conversation offers it")
        let upload = try AskSidePanelFileAccess.resolve("inputs/0123456789abcdef-fedcba9876543210-sales.csv",
                                                        workspaceRoot: root)
        try panel.open(upload, conversationId: "c1")
        let tabLabels = try await render(AskSidePanelView(panel: panel, context: context, close: {}),
                                         name: "side-panel-file-locate")
        #expect(tabLabels.contains { $0.contains(L("ask.sidePanel.locateMessage")) })
        let output = try AskSidePanelFileAccess.resolve("outputs/summary.md", workspaceRoot: root)
        try panel.open(output, conversationId: "c1")
        let other = try await render(AskSidePanelView(panel: panel, context: context, close: {}),
                                     name: "side-panel-file-no-locate")
        #expect(!other.contains { $0.contains(L("ask.sidePanel.locateMessage")) }, "No message, nothing to locate")
        #expect(located.isEmpty)
    }

    @Test func artifactTabsPreviewTheKeptCopy() async throws {
        let data = Data("complete build log".utf8)
        let digest = AskToolPolicy.digest(data)
        let ref = AskArtifactRef(id: "artifact-log", ownerId: "o", conversationId: "c1", runId: "r", version: "v",
                                 mediaType: "text/plain", sizeBytes: Int64(data.count), sha256: digest,
                                 cleanup: "device_30_days")
        let bundle = AskArtifactBundle(manifest: .init(ref: ref, workspace: nil, createdAt: Date(), entry: "build.log",
                                                       resources: [.init(path: "build.log", mediaType: "text/plain",
                                                                         sizeBytes: data.count, sha256: digest)]),
                                       files: ["build.log": data])
        let panel = AskSidePanel(browser: nil)
        try panel.open(artifact: ref, name: "build.log", conversationId: "c1")
        let labels = try await render(AskSidePanelView(panel: panel, context: AskSidePanelContext(conversationId: "c1"),
                                                       close: {})
                .environment(\.askArtifactAccess, AskArtifactAccess(load: { _ in bundle }, validate: { _ in })),
                                      name: "side-panel-artifact")
        #expect(labels.contains { $0.contains("build.log") })
        #expect(labels.contains { $0.contains("complete build log") })
        // Without access the tab says why instead of showing stale content.
        let denied = try await render(AskSidePanelView(panel: panel, context: AskSidePanelContext(conversationId: "c1"),
                                                       close: {}),
                                      name: "side-panel-artifact-unavailable")
        #expect(denied.contains { $0.contains(AskArtifactError.unavailable.localizedDescription) })
    }
}

extension AskSidePanelRenderTests {
    @Test func officeFilesShowAQuickLookPreviewAndCanBeReferenced() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("PK\u{3}\u{4}not really a document".utf8).write(to: root.appendingPathComponent("outputs/brief.docx"))
        let panel = AskSidePanel(browser: nil)
        let target = try AskSidePanelFileAccess.resolve("outputs/brief.docx", workspaceRoot: root)
        let tab = try panel.open(target, conversationId: "c1")
        #expect(tab.kind == .unsupported)
        var referenced: [URL] = []
        var panelContext = self.context(root)
        panelContext.referenceFile = { referenced.append($0) }
        panelContext.toggleFocus = {}
        panelContext.isFocused = true
        let labels = try await render(AskSidePanelView(panel: panel, context: panelContext, close: {}),
                                      name: "side-panel-file-quicklook", settle: .milliseconds(900))
        #expect(labels.contains(L("ask.sidePanel.file.quickLook")))
        #expect(labels.contains(L("ask.sidePanel.reference")))
        #expect(labels.contains(L("ask.sidePanel.focus.exit")))
        #expect(referenced.isEmpty)

        // Files the panel cannot preview and Quick Look does not cover keep the open buttons.
        let blob = try AskSidePanelFileAccess.resolve("work/blob.bin", workspaceRoot: root)
        try panel.open(blob, conversationId: "c1", kind: .unsupported)
        let fallback = try await render(AskSidePanelView(panel: panel, context: panelContext, close: {}),
                                        name: "side-panel-file-unsupported")
        #expect(fallback.contains(L("ask.sidePanel.file.unsupported")))
        #expect(!fallback.contains(L("ask.sidePanel.file.quickLook")))
    }

    @Test func filesAndChangesOfferReferencingWhenTheConversationCanTakeIt() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let panel = AskSidePanel(browser: nil)
        await panel.refreshFiles(conversationId: "c1") { (root, listing(root)) }
        panel.prepareForPresentation()
        var panelContext = self.context(root)
        panelContext.referenceFile = { _ in }
        let labels = try await render(AskSidePanelView(panel: panel, context: panelContext, close: {}),
                                      name: "side-panel-files-reference")
        #expect(labels.contains { $0.contains("sales.csv") })
        // Without a conversation to take it there is none.
        let plain = try await render(AskSidePanelView(panel: panel, context: self.context(root), close: {}),
                                     name: "side-panel-files-plain")
        #expect(!plain.contains(L("ask.sidePanel.reference")))
        #expect(plain.contains(L("ask.sidePanel.focus")) == false, "No focus toggle without a handler")

        let list = AskFileChangeList(changes: [.init(path: "outputs/summary.md", kind: .modified)], artifacts: [])
        let actions = AskSidePanelActions(fileURL: { root.appendingPathComponent($0) }, referenceFile: { _ in })
        try await render(AskFileChangesView(list: list, actions: actions).padding().frame(width: 560),
                         name: "file-changes-reference", size: NSSize(width: 600, height: 200))

        let drop = try await render(ZStack { AskTheme.surface; AskSidePanelDropHighlight() }, name: "side-panel-drop")
        #expect(drop.contains { $0.contains(L("ask.sidePanel.files.drop")) })
    }

    @Test func newTabsOfferTheConversationsFilesAndRecentItems() async throws {
        let name = "AskSidePanelRenderTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let browser = AskBrowserWorkspace(policy: AskBrowserSitePolicy(defaults: defaults), dataStore: .nonPersistent())
        defer { browser.tabs.forEach { browser.close($0) } }
        let url = try #require(URL(string: "https://example.com/pricing"))
        var opened: [AskSidePanelRecent] = []
        var showedFiles = 0
        let shortcuts = AskBrowserStartShortcuts(
            showFiles: { showedFiles += 1 },
            recents: [.file(.init(root: "/workspace", relativePath: "outputs/report.html"), conversationId: "c1"),
                      .web(url)],
            openRecent: { opened.append($0) }
        )
        let labels = try await render(AskBrowserStartPage(workspace: browser, tab: nil, shortcuts: shortcuts),
                                      name: "side-panel-new-tab")
        #expect(labels.contains { $0.contains(L("ask.sidePanel.start.files")) })
        #expect(labels.contains { $0.contains(L("ask.sidePanel.start.recent")) })
        #expect(labels.contains { $0.contains("report.html") })
        #expect(labels.contains { $0.contains("example.com") })

        // A private tab never lists what other tabs opened.
        let tab = try browser.newTab(isPrivate: true)
        let privateLabels = try await render(AskBrowserStartPage(workspace: browser, tab: tab, shortcuts: shortcuts),
                                             name: "side-panel-new-private-tab")
        #expect(!privateLabels.contains { $0.contains("report.html") })
        #expect(opened.isEmpty && showedFiles == 0)

        // In the panel, a new web tab's start page carries the panel's shortcuts.
        let panel = AskSidePanel(browser: browser)
        let file = try panel.open(.init(root: "/workspace", relativePath: "outputs/report.html"), conversationId: "c1")
        panel.close(.file(file.id))
        try panel.newWebTab()
        let view = AskSidePanelView(panel: panel, context: AskSidePanelContext(conversationId: "c1"), close: {})
        let inPanel = try await render(view, name: "side-panel-start-page")
        #expect(inPanel.contains { $0.contains(L("ask.sidePanel.start.files")) })
        #expect(inPanel.contains { $0.contains("report.html") })
    }
}
