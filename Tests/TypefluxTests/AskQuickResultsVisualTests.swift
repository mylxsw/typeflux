import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Opt-in renders of the launcher's quick results with the production views
/// (set TYPEFLUX_ASK_SNAPSHOTS). They never touch real accounts, screens or tools.
@Suite("Ask quick results snapshots", .serialized, .exclusiveUIState)
@MainActor
struct AskQuickResultsVisualTests {
    private func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, file: URL) async throws {
        let window = AskTestVoiceWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                        backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
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
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let cases: [(name: String, text: String, height: CGFloat)] = [
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
        // Wait for the asynchronous Finder load instead of capturing its temporary placeholder.
        _ = try #require(await AskResultImageCache.shared.image(.init(url: safari.url, thumbnail: false)))
        let apps = AskTestAppIndex([system("Calculator", "计算器", "Calculator"), system("Calendar", "日历", "Calendar"),
                                    system("Notes", "备忘录", "Notes"), system("Reminders", "提醒事项", "Reminders"), safari])
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for item in cases {
                let fixture = try AskTestFixture()
                defer { fixture.model.resetSession() }
                fixture.model.appIndex = apps
                fixture.model.launcherDraft = AskDraft(text: item.text, includeScreenshot: false)
                try await render(AskLauncherView(model: fixture.model, onDismiss: {})
                                    .environment(\.askGlassMaterialOverride, .opaque),
                                 size: NSSize(width: AskMetrics.launcherWidth, height: item.height), appearance: appearance,
                                 file: root.appendingPathComponent("quick-\(item.name)-\(name).png"))
            }
        }
    }
}
