import AppKit
import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
@MainActor
struct SettingsWindowLifecycleTests {
    @Test func `closing settings releases its hosting tree while the menu bar app stays resident`() async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            let policy = NSApp.activationPolicy()
            let lifetime = TypefluxTestApplicationLifetime(application: NSApp)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let controller = SettingsWindowController()
            defer {
                controller.window?.close()
                NSApp.setActivationPolicy(policy)
                lifetime.restore()
                try? FileManager.default.removeItem(at: root)
            }
            controller.modelLibrary = AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
            controller.show(settingsStore: settings, historyStore: FileHistoryStore(baseDir: root),
                            initialSection: .history)
            let window = try #require(controller.window)
            #expect(!AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApp))
            #expect(window.contentView != nil)
            window.close()
            #expect(controller.window == nil && controller.viewModel == nil)
            #expect(window.contentView == nil && !window.isVisible)
        }
    }
}
