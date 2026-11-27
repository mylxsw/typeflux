import AppKit
import Testing
@testable import Typeflux

private final class FittingHistoryStore: HistoryStore {
    func save(record _: HistoryRecord) {}
    func list() -> [HistoryRecord] {
        []
    }

    func list(limit _: Int, offset _: Int, searchQuery _: String?) -> [HistoryRecord] {
        []
    }

    func record(id _: UUID) -> HistoryRecord? {
        nil
    }

    func delete(id _: UUID) {}
    func purge(olderThanDays _: Int) {}
    func clear() {}
    func exportMarkdown() throws -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
    }
}

@Suite("Window screen fitting", .serialized, .exclusiveUIState)
@MainActor
struct WindowScreenFittingTests {
    private let screen = NSRect(x: 0, y: 25, width: 1024, height: 640)

    @Test func frameThatAlreadyFitsIsUnchanged() {
        let frame = NSRect(x: 40, y: 60, width: 800, height: 500)
        #expect(WindowScreenFitting.frame(frame, within: screen) == frame)
    }

    @Test func oversizedFrameShrinksToTheVisibleFrame() {
        let frame = NSRect(x: -38, y: -80, width: 1100, height: 800)
        #expect(WindowScreenFitting.frame(frame, within: screen) == screen)
    }

    @Test(arguments: [
        NSPoint(x: -300, y: -300), NSPoint(x: 900, y: 600), NSPoint(x: -300, y: 600), NSPoint(x: 900, y: -300),
    ])
    func offscreenOriginMovesInsideWithoutResizing(origin: NSPoint) {
        // A second display can sit at negative coordinates.
        for visible in [screen, screen.offsetBy(dx: -1920, dy: 200)] {
            let frame = NSRect(origin: NSPoint(x: origin.x + visible.minX, y: origin.y + visible.minY),
                               size: NSSize(width: 400, height: 300))
            let fitted = WindowScreenFitting.frame(frame, within: visible)
            #expect(fitted.size == frame.size)
            #expect(visible.contains(fitted))
        }
    }

    @Test func sizeIsLimitedPerDimension() {
        #expect(WindowScreenFitting.size(NSSize(width: 1100, height: 500), within: screen)
            == NSSize(width: 1024, height: 500))
        #expect(WindowScreenFitting.size(NSSize(width: 720, height: 900), within: screen)
            == NSSize(width: 720, height: 640))
    }

    @Test func settingsWindowOpensInsideASmallScreen() async throws {
        let available = try #require(NSScreen.main).visibleFrame
        // Stands in for a 1024pt wide display, placed on the real screen so AppKit keeps the frame.
        let small = NSRect(x: available.minX, y: available.minY,
                           width: min(1024, available.width), height: min(640, available.height))
        let window = try await showSettings(in: small)
        defer { window.close() }

        #expect(small.contains(window.frame), "\(window.frame) exceeds \(small)")
        #expect(window.frame.width == small.width)
        assertMinimumSize(in: small, window: window)
    }

    @Test func settingsWindowKeepsItsDefaultSizeOnALargeScreen() async throws {
        let available = try #require(NSScreen.main).visibleFrame
        let width = StudioTheme.Layout.settingsWindowWidth
        let height = StudioTheme.Layout.settingsWindowHeight
        guard available.width >= width, available.height >= height else { return }
        let window = try await showSettings(in: available)
        defer { window.close() }

        #expect(window.frame.size == NSSize(width: width, height: height))
        assertMinimumSize(in: available, window: window)
    }

    private func assertMinimumSize(in visibleFrame: NSRect, window: NSWindow) {
        let expected = NSSize(
            width: min(StudioTheme.Layout.settingsWindowMinWidth, visibleFrame.width),
            height: min(StudioTheme.Layout.settingsWindowMinHeight, visibleFrame.height)
        )
        #expect(window.contentMinSize == expected)
        window.setContentSize(NSSize(width: expected.width / 2, height: expected.height / 2))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(window.frame.width >= expected.width)
        #expect(window.frame.height >= expected.height)
    }

    @Test func chatWindowWithoutASavedFrameOpensInsideASmallScreen() async throws {
        _ = NSApplication.shared
        let suite = "ask-window-fitting-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let conversation = try AskTestFixture()
        let controller = AskConversationWindowController(
            settings: SettingsStore(defaults: defaults), model: conversation.model,
            dockVisibility: DockVisibilityController(app: FittingActivationPolicy()),
            conversationFrameAutosaveName: suite
        )
        let available = try #require(NSScreen.main).visibleFrame
        let small = NSRect(x: available.minX, y: available.minY,
                           width: min(1024, available.width), height: min(640, available.height))
        controller.visibleScreenFrame = { small }
        controller.showConversation()
        let window = try #require(NSApp.windows.first { $0.frameAutosaveName == suite })
        defer {
            window.delegate = nil
            window.setFrameAutosaveName("")
            window.close()
            NSWindow.removeFrame(usingName: suite)
            defaults.removePersistentDomain(forName: suite)
        }
        try await Task.sleep(for: .milliseconds(200))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(small.contains(window.frame), "\(window.frame) exceeds \(small)")
        #expect(window.frame.size == small.size)
    }

    private func showSettings(in visibleFrame: NSRect) async throws -> NSWindow {
        _ = NSApplication.shared
        let defaults = try #require(UserDefaults(suiteName: "window-fitting-" + UUID().uuidString))
        let controller = SettingsWindowController()
        controller.visibleScreenFrame = { visibleFrame }
        controller.show(settingsStore: SettingsStore(defaults: defaults), historyStore: FittingHistoryStore())
        let window = try #require(controller.window)
        // SwiftUI layout runs after presentation and must not grow the window again.
        try await Task.sleep(for: .milliseconds(400))
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private final class FittingActivationPolicy: ActivationPolicyControlling {
        var currentActivationPolicy: NSApplication.ActivationPolicy = .accessory
        func applyActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
            currentActivationPolicy = policy
        }
    }
}
