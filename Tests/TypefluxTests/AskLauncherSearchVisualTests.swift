import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Opt-in renders of launcher search with the production views (set
/// TYPEFLUX_ASK_SNAPSHOTS): files and folders in the launcher, the actions panel,
/// file mode and the settings page. Files live in a temporary folder.
@Suite("Ask launcher search snapshots", .serialized, .exclusiveUIState)
@MainActor
struct AskLauncherSearchVisualTests {
    private func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, file: URL,
                                 wait: Duration = .milliseconds(700)) async throws {
        let window = AskTestVoiceWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                        backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: wait)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: file)
        #expect(png.count > 4000)
    }

    /// A small home folder with real files, so rows show real icons and thumbnails.
    private func makeFiles() throws -> (root: URL, index: AskTestFileIndex) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ask-search-shots-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let files: [(String, AskFileRecord.Kind, Double)] = [
            ("Documents/notes.md", .file, 0),
            ("Documents/合同/2026 年度采购合同.pdf", .file, 2), ("Documents/合同/合同台账.xlsx", .file, 3),
            ("Documents/合同/框架合同-飞书.docx", .file, 40), ("Documents/合同", .folder, 1),
            ("Documents/发票/invoice-2026-09.pdf", .file, 20), ("Downloads/invoice-2026-08.pdf", .file, 48),
            ("Desktop/截图 2026-10-06.png", .file, 1), ("Projects/typeflux/README.md", .file, 3),
            ("Projects/typeflux/docs/usage.md", .file, 8), ("Documents/Typeflux/设计/内容搜索方案.md", .file, 0)
        ]
        for (path, kind, _) in files {
            let url = root.appendingPathComponent(path)
            if kind == .folder {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                continue
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if url.pathExtension == "png" {
                let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
                    NSGradient(starting: .systemTeal, ending: .systemPurple)?.draw(in: rect, angle: 45)
                    return true
                }
                let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
                try bitmap.representation(using: .png, properties: [:])!.write(to: url)
            } else {
                try Data("x".utf8).write(to: url)
            }
        }
        let index = AskTestFileIndex(files.map { (root.appendingPathComponent($0.0).path, $0.1, $0.2) }, home: root.path)
        return (root, index)
    }

    @Test func renderLauncherSearch() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let (root, files) = try makeFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        func system(_ file: String, _ name: String, _ english: String) -> AskAppEntry {
            AskAppEntry(name: name, url: URL(fileURLWithPath: "/System/Applications/\(file).app"),
                        bundleID: "com.apple." + file.lowercased(), names: [english])
        }
        let apps = AskTestAppIndex([system("Calculator", "计算器", "Calculator"), system("Notes", "备忘录", "Notes"),
                                    system("Preview", "预览", "Preview")])
        let cases: [(name: String, text: String, height: CGFloat)] = [
            ("apps-before-files", "note", 420),
            ("best-folder", "hetong", 470), ("files-below-ai", "invoice", 330), ("words-and-path", "typeflux md", 330),
            ("pinyin-middle", "ht", 470), ("file-mode", "f 合同", 420)
        ]
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for item in cases {
                let fixture = try AskTestFixture()
                defer { fixture.model.resetSession() }
                fixture.model.appIndex = apps
                fixture.model.fileIndex = files
                fixture.model.launcherDraft = AskDraft(text: item.text, includeScreenshot: false)
                try await render(AskLauncherView(model: fixture.model, onDismiss: {})
                                    .environment(\.askGlassMaterialOverride, .opaque),
                                 size: NSSize(width: AskMetrics.launcherWidth, height: item.height), appearance: appearance,
                                 file: output.appendingPathComponent("search-\(item.name)-\(theme).png"))
            }
            // The actions of a highlighted file.
            var settings = AskLauncherSearchSettings()
            settings.mode = .mixed
            var results = try #require(AskQuickResults.resolve(text: "invoice", previous: nil, chinese: true, calculator: false,
                                                               sources: .init(apps: apps, files: files, settings: settings)))
            results.highlight(1)
            let first = try #require(results.file(at: .file(0)))
            var panel = try #require(AskQuickActionPanel.make(for: .file(first)))
            panel.highlighted = 7
            try await render(AskQuickResultsView(results: results, question: "invoice", minimumHeight: 330, actions: panel,
                                                 onRun: { _, _ in }, onHighlight: { _ in })
                                .background(AskTheme.popoverSurface),
                             size: NSSize(width: AskMetrics.launcherWidth, height: 330), appearance: appearance,
                             file: output.appendingPathComponent("search-actions-\(theme).png"))
        }
    }

    @Test func renderSearchSettings() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let suite = "ask-search-shots-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        var search = AskLauncherSearchSettings()
        search.fileRoots = ["~", "~/Library/Mobile Documents"]
        search.excludedExtensions = ["log", "tmp"]
        settings.askLauncherSearchSettings = search
        let index = AskTestFileIndex()
        index.status = AskFileIndexStatus(phase: .ready, count: 248_312, bytes: 15_400_000, updatedAt: Date())
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for tab in LauncherSearchSettingsView.Tab.allCases {
                let view = LauncherSearchSettingsView(settings: settings, index: index, fullDiskAccess: { false }, tab: tab)
                    .padding(24).frame(width: 760, alignment: .top)
                    .background(StudioTheme.surface)
                try await render(view, size: NSSize(width: 760, height: 900), appearance: appearance,
                                 file: output.appendingPathComponent("settings-\(tab.rawValue)-\(theme).png"),
                                 wait: .milliseconds(300))
            }
        }
    }
}
