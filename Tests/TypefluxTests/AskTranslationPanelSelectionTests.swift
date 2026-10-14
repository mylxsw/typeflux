import AppKit
import QuartzCore
import Testing
@testable import Typeflux

@Suite("Translation panel repeated selection", .exclusiveUIState)
@MainActor
struct AskTranslationPanelSelectionTests {
    private func coordinator(_ fixture: TranslationPanelFixture, injector: TranslationPanelInjector,
                             recognizer: TranslationPanelRecognizer = .init()) -> AskTranslationPanelCoordinator {
        _ = NSApplication.shared
        let controller = AskTranslationPanelController(model: fixture.model)
        let entry = AskTranslationPanelCoordinator(model: fixture.model, controller: controller,
                                                   injector: injector, recognizer: recognizer)
        entry.frontmost = { 42 }
        return entry
    }

    @Test func `pinned panel recaptures a new selection translates once and keeps its position`() async throws {
        let savedLanguage = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(savedLanguage) }
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        for (appearance, mode) in [("dark", AppearanceMode.dark), ("light", .light)] {
            let fixture = TranslationPanelFixture()
            defer { fixture.clean() }
            fixture.settings.appearanceMode = mode
            let injector = TranslationPanelInjector()
            injector.snapshot.selectedText = "The best way to predict the future is to invent it."
            fixture.device.response = "预测未来的最好方式就是创造它。"
            fixture.ai.response = "预见未来最好的办法，就是亲手创造未来。"
            let entry = coordinator(fixture, injector: injector)
            entry.openSelection()
            await entry.waitForEntry()
            await fixture.model.waitForTranslation()
            fixture.model.pinned = true
            let window = try #require(entry.controller.presentedWindow)
            try await Task.sleep(for: .milliseconds(200))
            let previousPosition = CGPoint(x: window.frame.minX, y: window.frame.maxY)
            try await snapshot(window, name: "pinned-selection-before-" + appearance)
            injector.snapshot.selectedText = "Stay curious and keep learning."
            let screen = try #require(window.screen)
            injector.snapshot.selectionBounds = CGRect(x: screen.visibleFrame.maxX - 40,
                                                       y: screen.visibleFrame.maxY - 40, width: 20, height: 20)
            fixture.device.response = "保持好奇心，不断学习。"
            fixture.ai.response = "保持好奇，持续学习。"
            let previousCalls = fixture.ai.requests.count
            entry.openSelection()
            await entry.waitForEntry()
            await fixture.model.waitForTranslation()
            try await Task.sleep(for: .milliseconds(200))
            #expect(injector.captures == [.explicitSelectionAction, .explicitSelectionAction])
            #expect(fixture.model.pinned && fixture.model.source == .selection)
            #expect(fixture.model.text == injector.snapshot.selectedText)
            #expect(fixture.ai.requests.count == previousCalls + 1 && fixture.device.requests.count == 2)
            #expect(entry.controller.presentedWindow === window && window.isKeyWindow)
            #expect(abs(window.frame.minX - previousPosition.x) < 1)
            #expect(abs(window.frame.maxY - previousPosition.y) < 1)
            try await snapshot(window, name: "pinned-selection-after-" + appearance)
        }
    }

    @Test func `pinned panel with no new selection only focuses and keeps its content`() async throws {
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let injector = TranslationPanelInjector()
        let entry = coordinator(fixture, injector: injector)
        entry.openSelection()
        await entry.waitForEntry()
        await fixture.model.waitForTranslation()
        fixture.model.pinned = true
        let window = try #require(entry.controller.presentedWindow)
        try await Task.sleep(for: .milliseconds(200))
        let original = fixture.model.text
        let result = fixture.model.output?.body
        let frame = window.frame
        injector.snapshot.selectedText = nil
        entry.frontmost = { 99 }
        entry.openSelection()
        await entry.waitForEntry()
        #expect(injector.captures.count == 2 && fixture.ai.requests.count == 1)
        #expect(fixture.model.text == original && fixture.model.output?.body == result)
        #expect(fixture.model.source == .selection && fixture.model.pinned)
        #expect(entry.controller.presentedWindow === window && window.isKeyWindow && window.frame == frame)
    }

    @Test func `unselected shortcut keeps pending screenshot recognition alive`() async {
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let injector = TranslationPanelInjector()
        injector.snapshot.selectedText = nil
        let entry = coordinator(fixture, injector: injector, recognizer: .init(delay: .milliseconds(40)))
        entry.openScreenshot(translationPanelImage())
        fixture.model.pinned = true
        entry.openSelection()
        await entry.waitForEntry()
        await fixture.model.waitForTranslation()
        #expect(fixture.model.source == .screenshot && fixture.model.pinned)
        #expect(fixture.model.text == "Recognized screenshot sentence." && fixture.model.notice == nil)
        #expect(fixture.ai.requests.count == 1)
    }

    @Test func `unpinned panel recaptures and moves beside the new selection`() async throws {
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let injector = TranslationPanelInjector()
        let entry = coordinator(fixture, injector: injector)
        entry.openSelection()
        await entry.waitForEntry()
        await fixture.model.waitForTranslation()
        let window = try #require(entry.controller.presentedWindow)
        try await Task.sleep(for: .milliseconds(200))
        let before = window.frame.origin
        let screen = try #require(window.screen).visibleFrame
        let bounds = CGRect(x: screen.midX, y: screen.midY, width: 100, height: 20)
        injector.snapshot.selectionBounds = bounds
        injector.snapshot.selectedText = "Another selected sentence."
        entry.openSelection()
        await entry.waitForEntry()
        await fixture.model.waitForTranslation()
        try await Task.sleep(for: .milliseconds(200))
        let expected = AskTranslationPanelPlacement.frame(size: window.frame.size, screen: screen,
                                                          position: .center, mouse: .zero, selection: bounds)
        #expect(window.frame.origin != before && !fixture.model.pinned)
        #expect(abs(window.frame.minX - expected.minX) < 1 && abs(window.frame.minY - expected.minY) < 1)
        #expect(fixture.ai.requests.count == 2 && injector.captures.count == 2)
    }

    private func snapshot(_ window: NSWindow, name: String) async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_TRANSLATION_PANEL_SNAPSHOTS"],
              ProcessInfo.processInfo.environment["TYPEFLUX_TRANSLATION_NATIVE"] == "1" else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        window.display()
        window.contentView?.displayIfNeeded()
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(120))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber),
                             URL(fileURLWithPath: directory).appendingPathComponent("native-" + name + ".png").path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
