import Foundation
import Testing
@testable import Typeflux

private final class HomePermissionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    private var reads = 0
    func set(_ value: Bool) {
        lock.withLock { self.value = value }
    }

    func read() -> Bool {
        lock.withLock { reads += 1; return value }
    }

    var count: Int {
        lock.withLock { reads }
    }
}

@Suite("Launcher home permission snapshots", .exclusiveUIState)
@MainActor
struct AskLauncherHomePermissionTests {
    @Test func `one snapshot coalesces modes but the next snapshot and capture recheck access`() async throws {
        let fixture = try AskTestFixture(authenticated: false)
        defer { fixture.model.resetSession() }
        let screenshot = HomePermissionProbe(), ocr = HomePermissionProbe()
        ocr.set(false)
        let capture = AskScreenshotPlugin(isPermissionGranted: { screenshot.read() })
        fixture.model.plugins.replacePlugins([
            capture, AskScreenshotTextPlugin(isPermissionGranted: { ocr.read() })
        ])
        let first = fixture.model.launcherHomeContext()
        let screenshotRows = first.keywords.filter { $0.keyword.pluginID == AskScreenshotPlugin.id }
        let ocrRows = first.keywords.filter { $0.keyword.pluginID == AskScreenshotTextPlugin.id }
        #expect(screenshotRows.count > 1 && !ocrRows.isEmpty)
        #expect(screenshot.count == 1 && ocr.count == 1)
        #expect(screenshotRows.allSatisfy { !$0.title.contains(L("screenshot.permission.needed")) })
        #expect(ocrRows.allSatisfy { $0.title.contains(L("screenshot.permission.needed")) })
        #expect(screenshotRows.contains { $0.title.contains(L("screenshot.mode.fullScreen.short")) })

        screenshot.set(false); ocr.set(true)
        let second = fixture.model.launcherHomeContext()
        #expect(screenshot.count == 2 && ocr.count == 2)
        #expect(second.keywords.filter { $0.keyword.pluginID == AskScreenshotPlugin.id }
            .allSatisfy { $0.title.contains(L("screenshot.permission.needed")) })
        #expect(second.keywords.filter { $0.keyword.pluginID == AskScreenshotTextPlugin.id }
            .allSatisfy { !$0.title.contains(L("screenshot.permission.needed")) })
        // The display copy is never installed into the execution registry.
        let keyword = try #require(screenshotRows.first?.keyword)
        let original = try #require(fixture.model.plugins.plugin(for: keyword))
        let plan = await original.plan(.init(text: "", origin: .argument, keyword: keyword,
                                             options: keyword.options, interfaceLanguage: .english))
        #expect(screenshot.count == 3)
        #expect(plan.meta.contains { $0.text == L("screenshot.permission.needed") })
    }
}
