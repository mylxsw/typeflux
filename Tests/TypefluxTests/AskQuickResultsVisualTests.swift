import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Opt-in renders of the launcher's quick results with the production views
/// (set TYPEFLUX_ASK_SNAPSHOTS). They never touch real accounts, screens or tools.
@Suite("Ask quick results snapshots", .serialized, .exclusiveUIState)
@MainActor
struct AskQuickResultsVisualTests {
    @Test func allResultIconsShareTheSameFootprint() async throws {
        _ = NSApplication.shared
        let file = URL(fileURLWithPath: "/tmp/typeflux-icon-layout-fixture.png")
        let icons: [AskPluginItem.Icon?] = [
            .feature("chat"), .application("com.apple.finder"), .fileIcon(file), .fileType("public.folder"),
            .image(file), .websiteIcon(URL(string: "about:blank")!, fallback: nil), .symbol("equal"), nil
        ]
        let labels = ["Built-in feature", "Application", "File", "Folder", "Workflow image", "Website", "Symbol", "Fallback"]
        for icon in icons {
            let host = NSHostingView(rootView: AskPluginItemIcon(icon: icon, symbol: "star", filled: false))
            #expect(host.fittingSize == NSSize(width: 36, height: 36))
        }
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"]
            ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = VStack(spacing: 4) {
                ForEach(icons.indices, id: \.self) { index in
                    AskPluginItemRow(item: .init(id: String(index), title: labels[index],
                        subtitle: "Consistent icon and text alignment", icon: icons[index]),
                        symbol: "star", selected: index == 0, emphasized: true, height: 48, onPick: {})
                }
            }.padding(16).background(ModelVisualStyle.canvas)
            try await render(view, size: .init(width: 600, height: 450), appearance: appearance,
                             file: root.appendingPathComponent("uniform-icons-" + name + ".png"))
        }
    }

    @Test func renderBuiltInNumberConversionSetting() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let suite = "launcher-built-in-snapshot-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await render(LauncherSettingsView(settings: settings).padding(24).background(ModelVisualStyle.canvas),
                             size: .init(width: 620, height: 270), appearance: appearance,
                             file: root.appendingPathComponent("built-in-number-conversions-\(name).png"))
        }
    }

    private func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, file: URL,
                                ready: (() -> Bool)? = nil) async throws {
        let window = AskTestVoiceWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                        backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        if let ready {
            for _ in 0..<200 {
                if ready() { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(ready(), "The real application icon must load before capturing the list")
        }
        try await Task.sleep(for: .milliseconds(500))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: file)
        #expect(png.count > 4000)
    }

    @Test func renderLauncherQuickResults() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = NSApplication.shared
        // Snapshot rendering must not wait for access to the user's real keychain.
        let previousStore = KeychainTokenStore.useInMemoryStoreForTesting
        KeychainTokenStore.useInMemoryStoreForTesting = true
        _ = AuthState.shared
        KeychainTokenStore.useInMemoryStoreForTesting = previousStore
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let cases: [(name: String, text: String, height: CGFloat)] = [
            ("number-conversions", "255", 630), ("number-fraction", "1001.005", 530), ("number-search", "2024", 630),
            ("calculator", "1234567.89*2", 360), ("error", "100/0", 270), ("radix", "0xff+1", 360),
            ("app", "jsq", 250), ("app-question", "ji?", 330), ("safari", "safa", 250)
        ]
        // Real system applications, so the rows show their icons.
        func system(_ file: String, _ name: String, _ english: String) -> AskAppEntry {
            AskAppEntry(name: name, url: URL(fileURLWithPath: "/System/Applications/\(file).app"),
                        bundleID: "com.apple." + file.lowercased(), names: [english])
        }
        let safari = try #require(await Task.detached {
            AskAppIndex.scan([URL(fileURLWithPath: "/Applications/Safari.app")]).first
        }.value, "Safari must be installed for the opt-in application icon snapshot")
        // Native icons load through the visible launcher's scoped views, not the retired compatibility cache.
        let apps = AskTestAppIndex([system("Calculator", "计算器", "Calculator"), system("Calendar", "日历", "Calendar"),
                                    system("Notes", "备忘录", "Notes"), system("Reminders", "提醒事项", "Reminders"), safari])
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for item in cases {
                let fixture = try AskTestFixture()
                defer { fixture.model.resetSession() }
                fixture.model.appIndex = apps
                if item.name == "number-search" {
                    fixture.model.fileIndex = AskTestFileIndex([
                        ("/Users/test/Documents/2024 年度报告.pdf", .file, 0),
                        ("/Users/test/Documents/2024 收支明细.xlsx", .file, 1)
                    ])
                }
                fixture.model.launcherDraft = AskDraft(text: item.text, includeScreenshot: false)
                fixture.model.owner = fixture.model.session()?.owner ?? ""
                fixture.model.setLauncherImagesVisible(true, prepareIcons: false)
                #expect(fixture.model.contextImageAccess(launcher: true).allows())
                defer { fixture.model.setLauncherImagesVisible(false) }
                try await render(AskLauncherView(model: fixture.model, onDismiss: {})
                                    .environment(\.askGlassMaterialOverride, .opaque),
                                 size: NSSize(width: AskMetrics.launcherWidth, height: item.height), appearance: appearance,
                                 file: root.appendingPathComponent("quick-\(item.name)-\(name).png"),
                                 ready: item.name == "safari" ? {
                                     fixture.model.launcherIconCache.cached(.init(kind: .file, value: safari.url.path)) != nil
                                 } : nil)
            }
        }
    }
}
