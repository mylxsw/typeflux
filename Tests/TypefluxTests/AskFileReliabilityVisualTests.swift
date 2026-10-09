import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("File reliability snapshots", .serialized)
@MainActor
struct AskFileReliabilityVisualTests {
    @Test func renderGuardedSearch() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_RELIABILITY_SNAPSHOTS"] else { return }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let previous = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previous) }
        for dark in [false, true] {
            for skipped in [false, true] {
                try await render(output: output, dark: dark, skipped: skipped)
            }
        }
    }

    private func render(output: URL, dark: Bool, skipped: Bool) async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let files = AskTestFileIndex([("/Users/test/Projects/README.md", .file, 0)])
        var settings = AskLauncherSearchSettings()
        settings.excludedPaths = []
        let scope = AskFileScope(settings: settings, fullDiskAccess: false, home: "/Users/test")
        files.status = AskFileIndexStatus(phase: .ready, count: 1, blocked: scope.blockedInScope,
                                         timedOut: skipped ? 2 : 0, nonLocalMounts: skipped ? 1 : 0)
        fixture.model.fileIndex = files
        fixture.model.appIndex = AskTestAppIndex([])
        fixture.model.launcherDraft = AskDraft(text: "readme", includeScreenshot: false)
        fixture.model.plugins.enter(AskFileSearchPlugin.keywords[0])
        fixture.model.plugins.update(text: "readme", selection: nil, language: .simplifiedChinese)
        let size = NSSize(width: 860, height: 360)
        let window = AskTestVoiceWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                        backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: AskLauncherView(model: fixture.model, onDismiss: {})
            .environment(\.askGlassMaterialOverride, .opaque)
            .environment(\.colorScheme, dark ? .dark : .light))
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .seconds(2))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let name = "zh-" + (dark ? "dark-" : "light-") + (skipped ? "skipped.png" : "permission.png")
        try png.write(to: output.appendingPathComponent(name))
        #expect(png.count > 4000)
    }
}
