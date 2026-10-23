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
                                      name: name, settle: .milliseconds(path.hasSuffix(".html") ? 900 : 400))
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
}
