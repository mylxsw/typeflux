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
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let before = ProcessInfo.processInfo.environment["TYPEFLUX_RELIABILITY_BEFORE"] == "1"
        let files = AskTestFileIndex(before ? [] : [("/Users/test/Projects/README.md", .file, 0)])
        var settings = AskLauncherSearchSettings()
        settings.excludedPaths = []
        let scope = AskFileScope(settings: settings, fullDiskAccess: false, home: "/Users/test")
        files.status = AskFileIndexStatus(phase: before ? .building(found: 0, estimate: nil) : .ready,
                                         count: before ? 0 : 1, blocked: scope.blockedInScope)
        fixture.model.fileIndex = files
        fixture.model.appIndex = AskTestAppIndex([])
        fixture.model.launcherDraft = AskDraft(text: "readme", includeScreenshot: false)
        fixture.model.plugins.enter(AskFileSearchPlugin.keywords[0])
        fixture.model.plugins.update(text: "readme", selection: nil, language: .english)
        let size = NSSize(width: 860, height: 460)
        let window = AskTestVoiceWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                        backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let hosting = NSHostingView(rootView: AskLauncherView(model: fixture.model, onDismiss: {})
            .environment(\.askGlassMaterialOverride, .opaque))
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .seconds(2))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: output.appendingPathComponent("guarded-search.png"))
        #expect(png.count > 4000)
    }
}
